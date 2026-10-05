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
import android.util.Log

/**
 * The foreground service a call runs under while it publishes a microphone
 * or a camera (docs/design.md §4.7), or while a system call exists (§4.8).
 *
 * Android 11+ silences the microphone and stops the camera of an app in
 * the background unless a foreground service of type `microphone` /
 * `camera` runs, and Android 14+ lets such a service start only while the
 * app is in the foreground and holds the matching runtime permission. So
 * [CallBackground] starts it on the first publish (the app is in the
 * foreground then), changes its types when the camera comes or goes, and
 * stops it when nothing is published.
 *
 * While a call is in Telecom ([SystemCallRegistry]) it also has the type
 * `phoneCall`, and its notification is the call's `CallStyle` one; it runs
 * until both the publications and the system calls are gone. The two parts
 * are kept here ([microphone], [camera], and the registry's calls), and
 * [sync] starts, updates or stops the service to match.
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
        private const val CHANNEL_ID = "cloudflare_realtime_call"
        internal const val NOTIFICATION_ID = 0xCA11

        /** What the rooms publish (from [CallBackground]). */
        internal var microphone = false
        internal var camera = false

        /** The running service, to change its types without starting it again. */
        @Volatile
        internal var running: CallService? = null

        private var starting = false
        private val onStarted = mutableListOf<(Exception?) -> Unit>()

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

        private fun publishing(context: Context) =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                typesFor(context, microphone, camera) != 0
            } else {
                microphone || camera
            }

        /**
         * Makes the service match [microphone], [camera] and the system calls:
         * starts it, changes the running one in place (Android 12+ refuses a
         * start from the background, not an update), or stops it. [done] gets
         * `null` once it runs as wanted (or is stopped), or what Android
         * refused. Main thread.
         */
        internal fun sync(context: Context, done: ((Exception?) -> Unit)? = null) {
            if (!publishing(context) && !SystemCallRegistry.hasCalls) {
                stop(context)
                done?.invoke(null)
                return
            }
            running?.let { service ->
                try {
                    val partial = service.update()
                    done?.invoke(partial)
                } catch (e: Exception) {
                    done?.invoke(e)
                }
                return
            }
            done?.let { onStarted += it }
            if (starting) return
            starting = true
            try {
                val intent = Intent(context, CallService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // ForegroundServiceStartNotAllowedException: the app is in the
                // background (Android 12+).
                started(e)
            }
        }

        private fun started(error: Exception?) {
            starting = false
            val callbacks = onStarted.toList()
            onStarted.clear()
            for (callback in callbacks) callback(error)
        }

        private fun stop(context: Context) {
            running?.stopNow()
            if (starting) started(IllegalStateException("Stopped."))
            try {
                context.stopService(Intent(context, CallService::class.java))
            } catch (e: Exception) {
                Log.w("cloudflare_realtime", "Could not stop the call service: ${e.logName()}")
            }
        }

        /** The ongoing calls' channel ("Calls", low importance). */
        internal fun channel(context: Context): String {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                    manager.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            context.getString(R.string.cloudflare_realtime_call_channel),
                            NotificationManager.IMPORTANCE_LOW,
                        ),
                    )
                }
            }
            return CHANNEL_ID
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val partial = update()
            running = this
            started(partial)
        } catch (e: Exception) {
            stopNow()
            started(e)
        }
        return START_NOT_STICKY
    }

    /**
     * Puts the service in the foreground with the types for what is
     * published and `phoneCall` while a system call exists. Throws what
     * `startForeground` throws, for example a `SecurityException` when
     * Android 14+ refuses a type from the background; when only the
     * publishing types are refused during a system call, the service keeps
     * `phoneCall` and the refusal is returned instead.
     */
    internal fun update(): Exception? {
        val call = SystemCallRegistry.buildNotification(this)
        val notification = call ?: buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val phoneCall = if (call != null) ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL else 0
            val publishing = typesFor(this, microphone, camera)
            if (phoneCall == 0 && publishing == 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                throw IllegalStateException("Neither the microphone nor the camera permission is granted.")
            }
            if (phoneCall == 0 && publishing == 0) {
                startForeground(NOTIFICATION_ID, notification)
                return null
            }
            try {
                startForeground(NOTIFICATION_ID, notification, phoneCall or publishing)
            } catch (e: Exception) {
                if (phoneCall == 0 || publishing == 0) throw e
                startForeground(NOTIFICATION_ID, notification, phoneCall)
                return e
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return null
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
            Notification.Builder(this, channel(this))
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
