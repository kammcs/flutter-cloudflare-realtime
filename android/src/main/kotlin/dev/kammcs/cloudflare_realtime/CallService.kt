package dev.kammcs.cloudflare_realtime

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * The foreground service a call runs under while it publishes a microphone
 * or a camera (docs/design.md §4.7).
 *
 * Android 11+ silences the microphone and stops the camera of an app in
 * the background unless a foreground service of type `microphone` /
 * `camera` runs, and Android 14+ lets such a service start only while the
 * app is in the foreground and holds the matching runtime permission. So
 * [CallBackground] starts it on the first publish (the app is in the
 * foreground then), changes its types with [update] when the camera comes
 * or goes, and stops it when nothing is published.
 *
 * It is separate from the screen share's [ScreenCaptureService]: that one
 * must start between the consent dialog and the capture, and has its own
 * "Stop sharing" action. During a share in a call both run.
 *
 * The notification's icon and texts are resources an app can override:
 * `cloudflare_realtime_call` (drawable) and the `cloudflare_realtime_call_*`
 * strings. Without the notification permission (Android 13+) the service
 * still runs; the notification just isn't shown in the drawer.
 */
class CallService : Service() {
    companion object {
        internal const val ACTION_START = "dev.kammcs.cloudflare_realtime.action.START_CALL"
        internal const val EXTRA_MICROPHONE = "microphone"
        internal const val EXTRA_CAMERA = "camera"
        private const val CHANNEL_ID = "cloudflare_realtime_call"
        private const val NOTIFICATION_ID = 0xCA11

        /** Called on the main thread once the service is in the foreground, or failed to get there. */
        @Volatile
        internal var onStarted: ((Exception?) -> Unit)? = null

        /** The running service, to change its types without starting it again. */
        @Volatile
        internal var running: CallService? = null

        /**
         * The service types for [microphone] and [camera] that the app holds
         * the permissions for (Android 11+), or 0.
         */
        internal fun typesFor(context: Context, microphone: Boolean, camera: Boolean): Int {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return 0
            fun granted(permission: String) =
                context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            var types = 0
            if (microphone && granted(Manifest.permission.RECORD_AUDIO)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (camera && granted(Manifest.permission.CAMERA)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            return types
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callback = onStarted
        onStarted = null
        try {
            update(
                intent?.getBooleanExtra(EXTRA_MICROPHONE, false) == true,
                intent?.getBooleanExtra(EXTRA_CAMERA, false) == true,
            )
            running = this
            callback?.invoke(null)
        } catch (e: Exception) {
            stopNow()
            callback?.invoke(e)
        }
        return START_NOT_STICKY
    }

    /**
     * Puts the service in the foreground with the types for [microphone] and
     * [camera]. Throws what `startForeground` throws, for example a
     * `SecurityException` when Android 14+ refuses a type from the
     * background.
     */
    internal fun update(microphone: Boolean, camera: Boolean) {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val types = typesFor(this, microphone, camera)
            if (types == 0) throw IllegalStateException("Neither the microphone nor the camera permission is granted.")
            startForeground(NOTIFICATION_ID, notification, types)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }

    internal fun stopNow() {
        if (running === this) running = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        getString(R.string.cloudflare_realtime_call_channel),
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.cloudflare_realtime_call)
            .setContentTitle(getString(R.string.cloudflare_realtime_call_title))
            .setContentText(getString(R.string.cloudflare_realtime_call_text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    launch,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }
}
