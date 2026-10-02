package dev.kammcs.cloudflare_realtime

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps a call alive in the background on Android (docs/design.md §4.7):
 * starts, changes and stops [CallService]. When to run it, and with which
 * types, is decided in Dart (`CallBackground`).
 *
 * - `startService {microphone, camera}`: starts the service, or changes its
 *   types when it runs, and answers once it is in the foreground: `true`,
 *   or `false` when the app holds neither permission (the service is
 *   stopped then). An error when Android refuses (a start from the
 *   background, Android 12+; a type from the background, Android 14+).
 * - `stopService`.
 *
 * The event channel reports nothing on Android: the service keeps the
 * camera running, so it is never paused by the system.
 */
internal class CallBackground(private val context: Context) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private companion object {
        const val TAG = "cloudflare_realtime"
        const val START_TIMEOUT_MS = 10_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private var pendingStart: MethodChannel.Result? = null
    private var startTimeout: Runnable? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "startService" -> start(
                    call.argument<Boolean>("microphone") == true,
                    call.argument<Boolean>("camera") == true,
                    result,
                )
                "stopService" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("call_background", e.message, null)
        }
    }

    fun dispose() = stop()

    private fun start(microphone: Boolean, camera: Boolean, result: MethodChannel.Result) {
        if (pendingStart != null) {
            result.error("call_background", "The call service is already starting.", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            CallService.typesFor(context, microphone, camera) == 0
        ) {
            stop()
            result.success(false)
            return
        }
        // Running: change its types in place. Starting it again from the
        // background would be refused on Android 12+.
        CallService.running?.let { service ->
            try {
                service.update(microphone, camera)
                result.success(true)
            } catch (e: Exception) {
                Log.w(TAG, "Call service types not changed: $e")
                result.error("call_background", "Could not change the call service: ${e.message}", null)
            }
            return
        }
        pendingStart = result
        CallService.onStarted = { error -> main.post { finishStart(error) } }
        val timeout = Runnable {
            CallService.onStarted = null
            finishStart(IllegalStateException("The call service did not start."))
        }
        startTimeout = timeout
        main.postDelayed(timeout, START_TIMEOUT_MS)
        val intent = Intent(context, CallService::class.java)
            .setAction(CallService.ACTION_START)
            .putExtra(CallService.EXTRA_MICROPHONE, microphone)
            .putExtra(CallService.EXTRA_CAMERA, camera)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException: the app is in the
            // background (Android 12+). Dart tries again in the foreground.
            CallService.onStarted = null
            finishStart(e)
        }
    }

    private fun finishStart(error: Exception?) {
        startTimeout?.let { main.removeCallbacks(it) }
        startTimeout = null
        val result = pendingStart ?: return
        pendingStart = null
        if (error == null) {
            result.success(true)
        } else {
            Log.w(TAG, "Call service failed to start: $error")
            result.error("call_background", "Could not start the call service: ${error.message}", null)
        }
    }

    private fun stop() {
        CallService.onStarted = null
        finishStart(IllegalStateException("Stopped."))
        CallService.running?.stopNow()
        try {
            context.stopService(Intent(context, CallService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Could not stop the call service: $e")
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {}

    override fun onCancel(arguments: Any?) {}
}
