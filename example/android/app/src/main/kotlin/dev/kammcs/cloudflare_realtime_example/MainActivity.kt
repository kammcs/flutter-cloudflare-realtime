package dev.kammcs.cloudflare_realtime_example

import android.Manifest
import android.app.ActivityManager
import android.app.ActivityOptions
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var testFocus: AudioFocusRequest? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Bluetooth headsets are only listed as audio routes on Android 12+
        // once the app holds BLUETOOTH_CONNECT (docs/design.md §4.6). The
        // package leaves asking for it to the app; this is the example's way.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "example/permissions")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestBluetoothConnect" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 1)
                        }
                        result.success(null)
                    }
                    // System calls (docs/design.md §4.8): the call's
                    // notification needs POST_NOTIFICATIONS (13+), and an
                    // incoming call rings full screen only with the
                    // full-screen intent permission (14+, a settings page).
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
                        }
                        result.success(null)
                    }
                    "canUseFullScreenIntent" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                                .canUseFullScreenIntent(),
                    )
                    "openFullScreenIntentSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                                    .setData(Uri.fromParts("package", packageName, null)),
                            )
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // For example/integration_test/background_test.dart and
        // system_call_test.dart only.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "example/test_support")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeAudioFocus" -> result.success(takeAudioFocus(call.argument<Boolean>("transient") == true))
                    "releaseAudioFocus" -> { releaseAudioFocus(); result.success(null) }
                    "foregroundServices" -> result.success(foregroundServices())
                    // The system's mute as Telecom, a car or a watch sets it:
                    // the global microphone mute (docs/design.md §4.8).
                    "setMicrophoneMute" -> {
                        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        audio.isMicrophoneMute = call.argument<Boolean>("muted") == true
                        result.success(audio.isMicrophoneMute)
                    }
                    "callNotifications" -> result.success(callNotifications())
                    "sendCallNotificationAction" -> result.success(
                        sendCallNotificationAction(call.argument<String>("action") ?: ""),
                    )
                    else -> result.notImplemented()
                }
            }
    }

    // The app's call notifications (category call), as the system shows
    // them.
    private fun callNotifications(): List<Map<String, Any?>> {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return manager.activeNotifications
            .filter { it.notification.category == Notification.CATEGORY_CALL }
            .map {
                mapOf(
                    "channel" to it.notification.channelId,
                    "title" to it.notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
                    "fullScreen" to (it.notification.fullScreenIntent != null),
                    "actions" to (it.notification.actions?.size ?: 0),
                    "answer" to (callIntent(it.notification, "answer") != null),
                    "decline" to (callIntent(it.notification, "decline") != null),
                    "hangUp" to (callIntent(it.notification, "hangUp") != null),
                )
            }
    }

    // Presses Answer, Decline or Hang up in the call notification, as the
    // user would (the same PendingIntents).
    private fun sendCallNotificationAction(action: String): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = manager.activeNotifications
            .firstOrNull { it.notification.category == Notification.CATEGORY_CALL }
            ?.notification ?: return false
        val intent = callIntent(notification, action) ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            intent.send(
                ActivityOptions.makeBasic()
                    .setPendingIntentBackgroundActivityStartMode(
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
                    )
                    .toBundle(),
            )
        } else {
            intent.send()
        }
        return true
    }

    // CallStyle (Android 12+) keeps its intents in the extras; earlier, the
    // actions are in the order the package adds them.
    @Suppress("DEPRECATION")
    private fun callIntent(notification: Notification, action: String): PendingIntent? {
        val key = when (action) {
            "answer" -> "android.answerIntent"
            "decline" -> "android.declineIntent"
            "hangUp" -> "android.hangUpIntent"
            else -> return null
        }
        (notification.extras.getParcelable(key) as? PendingIntent)?.let { return it }
        val actions = notification.actions ?: return null
        return when {
            action == "answer" && actions.size == 2 -> actions[0].actionIntent
            action == "decline" && actions.size == 2 -> actions[1].actionIntent
            action == "hangUp" && actions.size == 1 -> actions[0].actionIntent
            else -> null
        }
    }

    // Takes the audio focus as a separate client (its own request), like a
    // media player or an assistant would: the call loses the focus.
    private fun takeAudioFocus(transient: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        releaseAudioFocus()
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val request = AudioFocusRequest.Builder(
            if (transient) AudioManager.AUDIOFOCUS_GAIN_TRANSIENT else AudioManager.AUDIOFOCUS_GAIN,
        )
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setOnAudioFocusChangeListener { }
            .build()
        testFocus = request
        return audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun releaseAudioFocus() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        testFocus?.let { audio.abandonAudioFocusRequest(it) }
        testFocus = null
    }

    // The app's own services in the foreground (getRunningServices still
    // lists the caller's own).
    @Suppress("DEPRECATION")
    private fun foregroundServices(): List<String> {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return manager.getRunningServices(Int.MAX_VALUE)
            .filter { it.service.packageName == packageName && it.foreground }
            .map { it.service.className }
    }
}
