package dev.kammcs.cloudflare_realtime

import android.content.Context
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
 * A system call (§4.8) keeps the service running with the type `phoneCall`
 * whatever is published; [CallService.sync] combines the two.
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
        CallService.microphone = microphone
        CallService.camera = camera
        pendingStart = result
        val timeout = Runnable { finishStart(IllegalStateException("The call service did not start.")) }
        startTimeout = timeout
        main.postDelayed(timeout, START_TIMEOUT_MS)
        // Starts it, or changes its types when it runs (also for a system
        // call, §4.8): starting it again from the background would be
        // refused on Android 12+.
        CallService.sync(context) { error -> main.post { finishStart(error) } }
    }

    private fun finishStart(error: Exception?) {
        startTimeout?.let { main.removeCallbacks(it) }
        startTimeout = null
        val result = pendingStart ?: return
        pendingStart = null
        if (error == null) {
            result.success(true)
        } else {
            Log.w(TAG, "Call service failed to start: ${error.logName()}")
            result.error("call_background", "Could not start the call service: ${error.message}", null)
        }
    }

    /** Nothing is published: the service stops, unless a system call keeps it. */
    private fun stop() {
        finishStart(IllegalStateException("Stopped."))
        CallService.microphone = false
        CallService.camera = false
        CallService.sync(context)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {}

    override fun onCancel(arguments: Any?) {}
}
