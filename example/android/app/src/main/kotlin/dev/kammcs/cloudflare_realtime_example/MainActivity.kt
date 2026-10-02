package dev.kammcs.cloudflare_realtime_example

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
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
                if (call.method != "requestBluetoothConnect") return@setMethodCallHandler result.notImplemented()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 1)
                }
                result.success(null)
            }
        // For example/integration_test/background_test.dart only.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "example/test_support")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeAudioFocus" -> result.success(takeAudioFocus(call.argument<Boolean>("transient") == true))
                    "releaseAudioFocus" -> { releaseAudioFocus(); result.success(null) }
                    "foregroundServices" -> result.success(foregroundServices())
                    else -> result.notImplemented()
                }
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
