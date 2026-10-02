package dev.kammcs.cloudflare_realtime_example

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Bluetooth headsets are only listed as audio routes on Android 12+
    // once the app holds BLUETOOTH_CONNECT (docs/design.md §4.6). The
    // package leaves asking for it to the app; this is the example's way.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }
}
