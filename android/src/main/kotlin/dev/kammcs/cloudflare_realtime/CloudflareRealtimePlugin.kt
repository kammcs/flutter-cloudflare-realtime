package dev.kammcs.cloudflare_realtime

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Call audio routing on Android (docs/design.md §4.6), interruptions, the
 * proximity sensor and keeping the screen on (§4.7), the call's foreground service
 * ([CallBackground], §4.7), system calls through Core-Telecom
 * ([SystemCallRegistry], §4.8), and the screen share's foreground service
 * ([ScreenCapture], §10).
 *
 * Thin by design: it lists the routes, reports the current one and its
 * changes, selects one, and puts the device in call mode while a call has
 * audio. Which route to pick (the default, a user's choice sticking) is
 * decided in Dart.
 *
 * Interruptions are audio focus: losing it (for good or for a while) is
 * reported as `{event: interruption, type: began, reason}`, getting it back
 * as `type: ended`; a loss that only asks to duck is ignored (the call
 * goes on). The reason is `phoneCall` while the audio mode says a phone
 * call rings or runs, else `otherAudio`. Dart decides when to take the
 * audio back (`resume`).
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
    private var hasFocus = false
    private var interrupted = false
    private var modeListener: Any? = null
    private lateinit var power: PowerManager
    private var proximityLock: PowerManager.WakeLock? = null
    // FLAG_KEEP_SCREEN_ON wanted on the activity's window (Dart decides),
    // and whether this plugin set it (an app's own wakelock may have).
    private var keepScreenOn = false
    private var setScreenFlag = false
    private lateinit var backgroundMethods: MethodChannel
    private lateinit var backgroundEvents: EventChannel
    private lateinit var background: CallBackground
    private lateinit var screenMethods: MethodChannel
    private lateinit var screenEvents: EventChannel
    private lateinit var screen: ScreenCapture
    private var activityBinding: ActivityPluginBinding? = null
    private lateinit var systemMethods: MethodChannel
    private lateinit var systemEvents: EventChannel
    private val systemCalls = SystemCallsChannel()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        audio = binding.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        methods = MethodChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/call_audio")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/call_audio_events")
        events.setStreamHandler(this)
        disableFlutterWebrtcAudioManagement()
        power = binding.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        background = CallBackground(binding.applicationContext)
        backgroundMethods = MethodChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/call_background")
        backgroundMethods.setMethodCallHandler(background)
        // Android reports no camera pauses (the service keeps the camera
        // running); the channel exists so Dart's shape is the same.
        backgroundEvents = EventChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/call_background_events")
        backgroundEvents.setStreamHandler(background)
        screen = ScreenCapture(binding.applicationContext)
        screenMethods = MethodChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/screen_capture")
        screenMethods.setMethodCallHandler(screen)
        screenEvents = EventChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/screen_capture_events")
        screenEvents.setStreamHandler(screen)
        SystemCallRegistry.init(binding.applicationContext)
        systemMethods = MethodChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/system_calls")
        systemMethods.setMethodCallHandler(systemCalls)
        systemEvents = EventChannel(binding.binaryMessenger, "dev.kammcs.cloudflare_realtime/system_calls_events")
        systemEvents.setStreamHandler(systemCalls)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        if (active) deactivate()
        setProximity(false)
        setKeepScreenOn(false)
        backgroundMethods.setMethodCallHandler(null)
        backgroundEvents.setStreamHandler(null)
        background.dispose()
        screenMethods.setMethodCallHandler(null)
        screenEvents.setStreamHandler(null)
        screen.dispose()
        // The calls outlive this engine (the registry is process-wide).
        systemMethods.setMethodCallHandler(null)
        systemEvents.setStreamHandler(null)
        systemCalls.dispose()
    }

    // --- Activity (the screen share's permission request, keeping the
    // screen on) ---------------------------------------------------------
    //
    // A system call's ring, Answer and full-screen intent go to the
    // package's own IncomingCallActivity, never to this (the app's)
    // activity: the plugin doesn't act on call intents here, and never
    // shows the app's activity over the lock screen (docs/design.md §4.8).

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        // A recreated activity (a rotation) has a new window.
        applyKeepScreenOn(binding.activity)
        binding.addRequestPermissionsResultListener(screen)
        screen.activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        // Off this window; [onAttachedToActivity] sets it on the next one.
        if (setScreenFlag) {
            activityBinding?.activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        setScreenFlag = false
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
                "resume" -> result.success(resume())
                "proximity" -> result.success(setProximity(call.argument<Boolean>("enabled") == true))
                "keepScreenOn" -> result.success(setKeepScreenOn(call.argument<Boolean>("enabled") == true))
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
        interrupted = false
        savedMode = audio.mode
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        requestFocus()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // A phone call can set its mode after taking the focus: refine
            // the reason then.
            val listener = AudioManager.OnModeChangedListener {
                if (interrupted && inPhoneCall()) emitInterruption("began", "phoneCall")
            }
            audio.addOnModeChangedListener({ main.post(it) }, listener)
            modeListener = listener
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let {
                audio.removeOnModeChangedListener(it)
            }
        }
        modeListener = null
        abandonFocus()
        interrupted = false
        audio.mode = savedMode
    }

    // --- Interruptions (audio focus) ---------------------------------------

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (!active) return@OnAudioFocusChangeListener
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                hasFocus = false
                interrupted = true
                emitInterruption("began", if (inPhoneCall()) "phoneCall" else "otherAudio")
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                hasFocus = true
                if (interrupted) emitInterruption("ended", null)
            }
            // AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK (a navigation prompt, a
            // notification): the call goes on.
        }
    }

    private fun requestFocus(): Boolean {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, main)
                .build()
                .also { focusRequest = it }
            audio.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN)
        }
        hasFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return hasFocus
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
        hasFocus = false
    }

    /** Takes the call's audio back: the focus (unless held) and the call mode. */
    private fun resume(): Boolean {
        if (!active) return false
        if (!hasFocus && !requestFocus()) return false
        // Before Android 12 a phone call leaves the mode at NORMAL.
        if (audio.mode != AudioManager.MODE_IN_COMMUNICATION) {
            audio.mode = AudioManager.MODE_IN_COMMUNICATION
        }
        interrupted = false
        return true
    }

    private fun inPhoneCall(): Boolean {
        val mode = audio.mode
        return mode == AudioManager.MODE_RINGTONE || mode == AudioManager.MODE_IN_CALL ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && mode == AudioManager.MODE_CALL_SCREENING) ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && mode == AudioManager.MODE_CALL_REDIRECT)
    }

    private fun emitInterruption(type: String, reason: String?) {
        Log.i("cloudflare_realtime", "Call audio interruption $type ${reason ?: ""}")
        main.post {
            sink?.success(mapOf("event" to "interruption", "type" to type, "reason" to reason))
        }
    }

    // --- Proximity sensor ----------------------------------------------------

    /** Turns the screen off near the ear while [enabled]. Returns whether it is on. */
    @SuppressLint("WakelockTimeout")
    private fun setProximity(enabled: Boolean): Boolean {
        if (!enabled) {
            proximityLock?.let {
                if (it.isHeld) it.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
            }
            return false
        }
        if (!power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return false
        val lock = proximityLock
            ?: power.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "cloudflare_realtime:proximity")
                .also {
                    it.setReferenceCounted(false)
                    proximityLock = it
                }
        // Held for the call; released when the route or the call changes.
        if (!lock.isHeld) lock.acquire()
        return lock.isHeld
    }

    // --- Keeping the screen on ------------------------------------------------

    /**
     * Keeps the screen on (no dimming, no lock) while [enabled], with
     * `FLAG_KEEP_SCREEN_ON` on the activity's window: no permission, and
     * it ends with the window. Dart decides when (a call with live video,
     * docs/design.md §4.7); the proximity sensor's wake lock still turns
     * the screen off near the ear. Returns whether the flag is set now:
     * `false` without an activity (it is set when one attaches).
     */
    private fun setKeepScreenOn(enabled: Boolean): Boolean {
        keepScreenOn = enabled
        val activity = activityBinding?.activity ?: return false
        return applyKeepScreenOn(activity)
    }

    private fun applyKeepScreenOn(activity: Activity): Boolean {
        val window = activity.window ?: return false
        val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        val isSet = window.attributes.flags and flag != 0
        if (keepScreenOn && !isSet) {
            window.addFlags(flag)
            setScreenFlag = true
        } else if (!keepScreenOn && setScreenFlag) {
            // Only a flag this plugin set: an app's own wakelock (the same
            // flag) stays.
            window.clearFlags(flag)
            setScreenFlag = false
        }
        return keepScreenOn
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
            Log.w("cloudflare_realtime", "Could not turn off flutter_webrtc's audio management: ${e.logName()}")
        }
    }
}
