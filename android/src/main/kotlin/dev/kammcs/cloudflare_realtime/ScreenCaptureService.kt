package dev.kammcs.cloudflare_realtime

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * The foreground service a screen share runs under (docs/design.md §10).
 *
 * Android 10+ needs a foreground service of type `mediaProjection` while
 * an app captures the screen, and Android 14+ checks it when the
 * projection is created: the service must already be in the foreground,
 * and it may only go there after the user has consented. So
 * [ScreenCapture] starts it between the consent dialog and
 * `getDisplayMedia`, and waits for [onStarted].
 *
 * Its notification has a "Stop sharing" action, reported through
 * [onStopRequested]. Without the notification permission (Android 13+) the
 * service still runs; the notification just isn't shown in the drawer.
 *
 * The notification's icon and texts are resources an app can override:
 * `cloudflare_realtime_screen_share` (drawable) and the
 * `cloudflare_realtime_screen_share_*` strings.
 */
class ScreenCaptureService : Service() {
    companion object {
        internal const val ACTION_START = "dev.kammcs.cloudflare_realtime.action.START_SCREEN_SHARE"
        internal const val ACTION_STOP = "dev.kammcs.cloudflare_realtime.action.STOP_SCREEN_SHARE"
        private const val CHANNEL_ID = "cloudflare_realtime_screen_share"
        private const val NOTIFICATION_ID = 0x5C4E

        /** Called on the main thread once the service is in the foreground, or failed to get there. */
        @Volatile
        internal var onStarted: ((Exception?) -> Unit)? = null

        /** Called on the main thread when the user taps the notification's "Stop sharing". */
        @Volatile
        internal var onStopRequested: (() -> Unit)? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            onStopRequested?.invoke()
            stopNow()
            return START_NOT_STICKY
        }
        val callback = onStarted
        onStarted = null
        try {
            goForeground()
            callback?.invoke(null)
        } catch (e: Exception) {
            stopNow()
            callback?.invoke(e)
        }
        return START_NOT_STICKY
    }

    private fun goForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopNow() {
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
                        getString(R.string.cloudflare_realtime_screen_share_channel),
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val stop = PendingIntent.getService(
            this,
            0,
            Intent(this, ScreenCaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        builder
            .setSmallIcon(R.drawable.cloudflare_realtime_screen_share)
            .setContentTitle(getString(R.string.cloudflare_realtime_screen_share_title))
            .setContentText(getString(R.string.cloudflare_realtime_screen_share_text))
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.cloudflare_realtime_screen_share_stop),
                    stop,
                ).build(),
            )
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
