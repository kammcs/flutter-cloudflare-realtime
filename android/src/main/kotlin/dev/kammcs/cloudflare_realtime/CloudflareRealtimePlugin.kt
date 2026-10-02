package dev.kammcs.cloudflare_realtime

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Call audio routing on Android (docs/design.md §4.6), and the screen
 * share's foreground service ([ScreenCapture], §10).
 *
 * Thin by design: it lists the routes, reports the current one and its
 * changes, selects one, and puts the device in call mode while a call has
 * audio. Which route to pick (the default, a user's choice sticking) is
 * decided in Dart.
 *
 * flutter_webrtc's own audio management (Twilio's AudioSwitch) is turned
 * off when the plugin loads: it re-selects a route by its own priority on
 * every device change, which would undo ours.
 */
class CloudflareRealtimePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var audio: AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var active = false
    private var savedMode = AudioManager.MODE_NORMAL
    private var focusRequest: AudioFocusRequest? = null
    private lateinit var screenMethods: MethodChannel
    private lateinit var screenEvents: EventChannel
    private lateinit var screen: ScreenCapture
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        audio = binding.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        methods = MethodChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/call_audio")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/call_audio_events")
        events.setStreamHandler(this)
        disableFlutterWebrtcAudioManagement()
        screen = ScreenCapture(binding.applicationContext)
        screenMethods = MethodChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/screen_capture")
        screenMethods.setMethodCallHandler(screen)
        screenEvents = EventChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/screen_capture_events")
        screenEvents.setStreamHandler(screen)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        if (active) deactivate()
        screenMethods.setMethodCallHandler(null)
        screenEvents.setStreamHandler(null)
        screen.dispose()
    }

    // --- Activity (the screen share's permission request) ----------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(screen)
        screen.activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(screen)
        activityBinding = null
        screen.activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "activate" -> { activate(); result.success(null) }
                "deactivate" -> { deactivate(); result.success(null) }
                "routes" -> result.success(routes().map { it.toMap() })
                "current" -> result.success(current()?.toMap())
                "select" -> result.success(select(call.argument<String>("id") ?: ""))
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("call_audio", e.message, null)
        }
    }

    // --- Call mode -------------------------------------------------------

    private fun activate() {
        if (active) return
        active = true
        savedMode = audio.mode
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .build()
            audio.requestAudioFocus(request)
            focusRequest = request
        }
    }

    private fun deactivate() {
        if (!active) return
        active = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = false
            @Suppress("DEPRECATION")
            audio.stopBluetoothSco()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
            focusRequest = null
        }
        audio.mode = savedMode
    }

    // --- Routes ----------------------------------------------------------

    private data class Route(val id: String, val kind: String, val name: String) {
        fun toMap() = mapOf("id" to id, "kind" to kind, "name" to name)
    }

    private fun kindOf(type: Int): String? = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wiredHeadset"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
        else -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            (type == AudioDeviceInfo.TYPE_BLE_HEADSET || type == AudioDeviceInfo.TYPE_HEARING_AID)
        ) "bluetooth" else null
    }

    private fun routeOf(device: AudioDeviceInfo): Route? {
        val kind = kindOf(device.type) ?: return null
        // Built-in devices report the phone's model as their name; Dart
        // names them by kind instead.
        val builtIn = kind == "speaker" || kind == "earpiece"
        return Route(device.id.toString(), kind, if (builtIn) "" else device.productName.toString())
    }

    private fun routes(): List<Route> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.availableCommunicationDevices.mapNotNull { routeOf(it) }.distinctBy { it.id }
        } else {
            legacyRoutes()
        }

    private fun current(): Route? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.communicationDevice?.let { routeOf(it) }
        } else {
            legacyCurrent()
        }

    private fun select(id: String): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val device = audio.availableCommunicationDevices.firstOrNull { it.id.toString() == id }
                ?: return false
            return audio.setCommunicationDevice(device)
        }
        return legacySelect(id)
    }

    // Android 7–11: no communication device API. Speaker on/off, Bluetooth
    // through SCO, and a wired headset or the earpiece when neither.
    private fun outputs(): List<AudioDeviceInfo> = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()

    private fun legacyRoutes(): List<Route> {
        val all = outputs().mapNotNull { routeOf(it) }
        val wired = all.firstOrNull { it.kind == "wiredHeadset" || it.kind == "usb" }
        return buildList {
            all.firstOrNull { it.kind == "speaker" }?.let { add(it.copy(id = "speaker")) }
            if (wired != null) add(wired.copy(id = "wired")) else
                all.firstOrNull { it.kind == "earpiece" }?.let { add(it.copy(id = "earpiece")) }
            all.firstOrNull { it.kind == "bluetooth" }?.let { add(it.copy(id = "bluetooth")) }
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyCurrent(): Route? {
        val routes = legacyRoutes()
        return when {
            audio.isSpeakerphoneOn -> routes.firstOrNull { it.id == "speaker" }
            audio.isBluetoothScoOn -> routes.firstOrNull { it.id == "bluetooth" }
            else -> routes.firstOrNull { it.id == "wired" } ?: routes.firstOrNull { it.id == "earpiece" }
        }
    }

    @Suppress("DEPRECATION")
    private fun legacySelect(id: String): Boolean {
        when (id) {
            "speaker" -> { audio.stopBluetoothSco(); audio.isBluetoothScoOn = false; audio.isSpeakerphoneOn = true }
            "bluetooth" -> { audio.isSpeakerphoneOn = false; audio.startBluetoothSco(); audio.isBluetoothScoOn = true }
            "wired", "earpiece" -> { audio.stopBluetoothSco(); audio.isBluetoothScoOn = false; audio.isSpeakerphoneOn = false }
            else -> return false
        }
        changed()
        return true
    }

    // --- Changes ---------------------------------------------------------

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = changed()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = changed()
    }
    private var communicationListener: Any? = null

    private fun changed() {
        main.post { sink?.success("changed") }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        audio.registerAudioDeviceCallback(deviceCallback, main)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val listener = AudioManager.OnCommunicationDeviceChangedListener { changed() }
            audio.addOnCommunicationDeviceChangedListener({ main.post(it) }, listener)
            communicationListener = listener
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        audio.unregisterAudioDeviceCallback(deviceCallback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (communicationListener as? AudioManager.OnCommunicationDeviceChangedListener)?.let {
                audio.removeOnCommunicationDeviceChangedListener(it)
            }
        }
        communicationListener = null
    }

    // --- flutter_webrtc --------------------------------------------------

    // By reflection, so this package doesn't need flutter_webrtc's Android
    // code at build time.
    private fun disableFlutterWebrtcAudioManagement() {
        try {
            Class.forName("com.cloudwebrtc.webrtc.audio.AudioSwitchManager")
                .getMethod("setAudioSessionManagementEnabled", Boolean::class.javaPrimitiveType)
                .invoke(null, false)
        } catch (e: Exception) {
            Log.w("cloudflare_realtime", "Could not turn off flutter_webrtc's audio management: $e")
        }
    }
}
