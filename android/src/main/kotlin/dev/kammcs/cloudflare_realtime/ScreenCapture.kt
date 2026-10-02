package dev.kammcs.cloudflare_realtime

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Screen share on Android (docs/design.md §10): the parts `flutter_webrtc`
 * leaves to the app.
 *
 * `flutter_webrtc` shows the MediaProjection consent dialog
 * (`requestCapturePermission`, called from Dart) and keeps its result for
 * the next `getDisplayMedia`, which creates the projection and captures.
 * It has no foreground service, which Android 14+ requires before the
 * projection is created, and it ignores the projection's `onStop` (the
 * user stopping the share from the system). This class adds both:
 *
 * - `prepare`: asks for the notification permission (Android 13+), once
 *   per process, so the service's notification shows. A denial is fine.
 * - `startService`: starts [ScreenCaptureService] and answers once it is in
 *   the foreground. Call it after consent and before `getDisplayMedia`.
 * - `watch`: registers a `MediaProjection.Callback` on the projection
 *   behind a `getDisplayMedia` track, reached by reflection into
 *   `flutter_webrtc` (whose classes its own ProGuard rules keep). Answers
 *   whether it could.
 * - `stopService`: stops the service and the watch.
 *
 * Events (`{event: "stopped", trackId, reason}`) report a share the user
 * ended outside the app: `projection` (the system's stop, or the screen
 * locking on some versions) or `notification` (our "Stop sharing"; no
 * trackId).
 */
internal class ScreenCapture(private val context: Context) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private companion object {
        const val TAG = "cloudflare_realtime"
        const val NOTIFICATION_PERMISSION_REQUEST = 0x5C4E
        const val START_TIMEOUT_MS = 10_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    /** The current activity, for the permission request. */
    var activity: Activity? = null

    private var askedNotifications = false
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingStart: MethodChannel.Result? = null
    private var startTimeout: Runnable? = null
    private var watched: Pair<MediaProjection, MediaProjection.Callback>? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "prepare" -> prepare(result)
                "startService" -> startService(result)
                "watch" -> result.success(watch(call.argument<String>("trackId") ?: ""))
                "stopService" -> { stopService(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("screen_capture", e.message, null)
        }
    }

    fun dispose() {
        stopService()
        pendingPermission?.success(false)
        pendingPermission = null
        sink = null
    }

    // --- Notification permission ------------------------------------------

    private fun notificationsAllowed(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun prepare(result: MethodChannel.Result) {
        val activity = activity
        if (notificationsAllowed() || askedNotifications || activity == null ||
            pendingPermission != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
        ) {
            result.success(notificationsAllowed())
            return
        }
        askedNotifications = true
        pendingPermission = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return false
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
        return true
    }

    // --- Foreground service ---------------------------------------------

    private fun startService(result: MethodChannel.Result) {
        if (pendingStart != null) {
            result.error("screen_capture", "The screen share service is already starting.", null)
            return
        }
        pendingStart = result
        ScreenCaptureService.onStopRequested = { emitStopped(null, "notification") }
        ScreenCaptureService.onStarted = { error -> main.post { finishStart(error) } }
        val timeout = Runnable {
            ScreenCaptureService.onStarted = null
            finishStart(IllegalStateException("The screen share service did not start."))
        }
        startTimeout = timeout
        main.postDelayed(timeout, START_TIMEOUT_MS)
        val intent = Intent(context, ScreenCaptureService::class.java)
            .setAction(ScreenCaptureService.ACTION_START)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            ScreenCaptureService.onStarted = null
            finishStart(e)
        }
    }

    private fun finishStart(error: Exception?) {
        startTimeout?.let { main.removeCallbacks(it) }
        startTimeout = null
        val result = pendingStart ?: return
        pendingStart = null
        if (error == null) {
            result.success(null)
        } else {
            Log.w(TAG, "Screen share service failed to start: $error")
            result.error("screen_capture", "Could not start the screen share service: ${error.message}", null)
        }
    }

    private fun stopService() {
        unwatch()
        ScreenCaptureService.onStopRequested = null
        ScreenCaptureService.onStarted = null
        finishStart(IllegalStateException("Stopped."))
        try {
            context.stopService(Intent(context, ScreenCaptureService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Could not stop the screen share service: $e")
        }
    }

    // --- Watching the projection ----------------------------------------

    private fun watch(trackId: String): Boolean {
        unwatch()
        val projection = try {
            projectionOf(trackId)
        } catch (e: Exception) {
            Log.w(TAG, "Cannot watch the screen share's MediaProjection: $e")
            null
        } ?: return false
        val callback = object : MediaProjection.Callback() {
            override fun onStop() {
                if (watched?.second !== this) return
                watched = null
                emitStopped(trackId, "projection")
                // Dart stops it too; this covers an engine that has gone.
                stopService()
            }
        }
        projection.registerCallback(callback, main)
        watched = projection to callback
        return true
    }

    private fun unwatch() {
        val (projection, callback) = watched ?: return
        watched = null
        try {
            projection.unregisterCallback(callback)
        } catch (_: Exception) {
            // Already stopped.
        }
    }

    /**
     * The MediaProjection behind `flutter_webrtc`'s screen track [trackId]:
     * FlutterWebRTCPlugin.sharedSingleton → methodCallHandler →
     * getUserMediaImpl → mVideoCapturers[trackId].capturer (an
     * OrientationAwareScreenCapturer) → mediaProjection. Checked against
     * flutter_webrtc 1.6.2+hotfix.3.
     */
    private fun projectionOf(trackId: String): MediaProjection? {
        val plugin = Class.forName("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin")
            .getField("sharedSingleton").get(null) ?: return null
        val handler = field(plugin, "methodCallHandler") ?: return null
        val userMedia = field(handler, "getUserMediaImpl") ?: return null
        val capturers = field(userMedia, "mVideoCapturers") as? Map<*, *> ?: return null
        val info = capturers[trackId] ?: return null
        val capturer = field(info, "capturer") ?: return null
        return field(capturer, "mediaProjection") as? MediaProjection
    }

    private fun field(target: Any, name: String): Any? {
        var type: Class<*>? = target.javaClass
        while (type != null) {
            try {
                val f = type.getDeclaredField(name)
                f.isAccessible = true
                return f.get(target)
            } catch (_: NoSuchFieldException) {
                type = type.superclass
            }
        }
        throw NoSuchFieldException("${target.javaClass.name}.$name")
    }

    // --- Events -----------------------------------------------------------

    private fun emitStopped(trackId: String?, reason: String) {
        Log.i(TAG, "Screen share stopped outside the app ($reason)")
        main.post {
            sink?.success(mapOf("event" to "stopped", "trackId" to trackId, "reason" to reason))
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}
