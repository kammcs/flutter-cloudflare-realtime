package dev.kammcs.cloudflare_realtime

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telecom.DisconnectCause
import android.util.Log
import android.view.WindowManager
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallException
import androidx.core.telecom.CallsManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * System calls on Android (docs/design.md §4.8): the app's calls in
 * Telecom, through Jetpack Core-Telecom, so the system treats them like
 * phone calls (a phone call holds them instead of cutting them off; cars,
 * watches and headsets answer, end and mute them).
 *
 * The native half of the contract in `lib/src/calls/system_call_backend.dart`.
 * It decides nothing: `SystemCalls` (Dart) does. It keeps a process-wide
 * registry of the calls (one per [SystemCallEntry]), each added with
 * `CallsManager.addCall` in its own coroutine, which collects the call's
 * endpoints and Telecom's mute; it posts the call's `CallStyle` notification
 * through [CallService] (type `phoneCall`), rings for an incoming call, and
 * relays every change to Dart as an event, once per real change, whether
 * the app or the system started it.
 *
 * Everything runs on the main thread.
 */
internal object SystemCallRegistry {
    private const val TAG = "cloudflare_realtime"

    /** Incoming calls ring on their own channel (high importance, a ringtone). */
    private const val INCOMING_CHANNEL_ID = "cloudflare_realtime_incoming_call"

    internal const val ACTION_ANSWER = "dev.kammcs.cloudflare_realtime.action.ANSWER_CALL"
    internal const val ACTION_SHOW = "dev.kammcs.cloudflare_realtime.action.SHOW_CALL"
    internal const val ACTION_DECLINE = "dev.kammcs.cloudflare_realtime.action.DECLINE_CALL"
    internal const val ACTION_HANG_UP = "dev.kammcs.cloudflare_realtime.action.HANG_UP_CALL"
    internal const val EXTRA_CALL_ID = "dev.kammcs.cloudflare_realtime.extra.CALL_ID"

    private lateinit var app: Context
    private lateinit var audio: AudioManager
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var manager: CallsManager? = null
    private var supportsVideo = true
    private var supportsHolding = true

    /** The calls, oldest first. Ended calls are removed. */
    private val calls = LinkedHashMap<String, SystemCallEntry>()

    private val sinks = mutableListOf<EventChannel.EventSink>()
    private val buffered = mutableListOf<Map<String, Any?>>()

    private val main = Handler(Looper.getMainLooper())
    private val endpointsPending = mutableSetOf<String>()
    private var lockScreenActivity: WeakReference<Activity>? = null

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    /** Whether a call is in Telecom now: [CallService] runs with `phoneCall`. */
    val hasCalls: Boolean
        get() = calls.values.any { it.added }

    // --- Events ------------------------------------------------------------

    fun addSink(sink: EventChannel.EventSink) {
        sinks += sink
        if (buffered.isNotEmpty()) {
            val pending = buffered.toList()
            buffered.clear()
            for (event in pending) sink.success(event)
        }
    }

    fun removeSink(sink: EventChannel.EventSink) {
        sinks.remove(sink)
    }

    private fun emit(event: Map<String, Any?>) {
        Log.i(TAG, "System call event $event")
        if (sinks.isEmpty()) {
            buffered += event
            return
        }
        for (sink in sinks.toList()) sink.success(event)
    }

    // --- Methods -----------------------------------------------------------

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configure" -> configure(call, result)
                "reportIncomingCall" -> add(call, outgoing = false, result)
                "startOutgoingCall" -> add(call, outgoing = true, result)
                "reportConnecting" -> { require(call); result.success(null) }
                "reportConnected" -> reportConnected(require(call), result)
                "answer" -> {
                    val entry = find(call) ?: return result.success(false)
                    answer(entry) { result.success(it) }
                }
                "end" -> {
                    val entry = find(call) ?: return result.success(false)
                    end(entry, call.argument<String>("reason") ?: "local") { result.success(it) }
                }
                "setHeld" -> setHeld(call, result)
                "setMuted" -> setMuted(call, result)
                "update" -> { require(call); result.success(null) }
                "activeCalls" -> result.success(calls.values.map { it.toMap() })
                "endpoints" -> result.success(find(call)?.endpointsMap())
                "selectEndpoint" -> selectEndpoint(call, result)
                else -> result.notImplemented()
            }
        } catch (e: SystemCallError) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            Log.w(TAG, "System calls: ${call.method} failed: $e")
            result.error("failed", e.message, null)
        }
    }

    private class SystemCallError(val code: String, message: String) : Exception(message)

    private fun find(call: MethodCall): SystemCallEntry? =
        call.argument<String>("id")?.lowercase()?.let { calls[it] }

    private fun require(call: MethodCall): SystemCallEntry =
        find(call) ?: throw SystemCallError("notFound", "No such call.")

    private fun configure(call: MethodCall, result: MethodChannel.Result) {
        // Core-Telecom needs Android 8.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return result.success(false)
        supportsVideo = call.argument<Boolean>("supportsVideo") != false
        supportsHolding = call.argument<Boolean>("supportsHolding") != false
        try {
            val calls = manager ?: CallsManager(app)
            var capabilities = CallsManager.CAPABILITY_BASELINE
            if (supportsVideo) capabilities = capabilities or CallsManager.CAPABILITY_SUPPORTS_VIDEO_CALLING
            calls.registerAppWithTelecom(capabilities)
            manager = calls
            result.success(true)
        } catch (e: Exception) {
            Log.w(TAG, "System calls unavailable: $e")
            result.success(false)
        }
    }

    private fun add(call: MethodCall, outgoing: Boolean, result: MethodChannel.Result) {
        val telecom = manager ?: throw SystemCallError("unavailable", "Call configure first.")
        val id = call.argument<String>("id")?.lowercase()
            ?: throw SystemCallError("failed", "The call has no id.")
        if (calls.containsKey(id)) throw SystemCallError("alreadyExists", "The call $id exists.")
        val entry = SystemCallEntry(
            id = id,
            handle = call.argument<String>("handle") ?: "",
            handleType = call.argument<String>("handleType") ?: "generic",
            displayName = call.argument<String>("displayName"),
            video = call.argument<Boolean>("video") == true,
            outgoing = outgoing,
        )
        calls[id] = entry
        val attributes = CallAttributesCompat(
            displayName = entry.displayName?.takeIf { it.isNotEmpty() } ?: entry.handle,
            address = addressOf(entry),
            direction = if (outgoing) {
                CallAttributesCompat.DIRECTION_OUTGOING
            } else {
                CallAttributesCompat.DIRECTION_INCOMING
            },
            callType = callTypeOf(entry),
            callCapabilities = if (supportsHolding) CallAttributesCompat.SUPPORTS_SET_INACTIVE else 0,
        )
        var replied = false
        entry.job = scope.launch {
            try {
                telecom.addCall(
                    attributes,
                    onAnswer = { onSystemAnswer(entry) },
                    onDisconnect = { cause -> onSystemDisconnect(entry, cause) },
                    onSetActive = { onSystemSetActive(entry) },
                    onSetInactive = { onSystemSetInactive(entry) },
                ) {
                    entry.control = this
                    entry.added = true
                    // The flows are channels that stay open: they are
                    // cancelled when the call ends, so that addCall returns.
                    entry.collectors = launch {
                        launch { isMuted.collect { onSystemMuted(entry, it) } }
                        launch {
                            availableEndpoints.collect {
                                val changed = it.map(::routeOf) != entry.endpoints.map(::routeOf)
                                entry.endpoints = it
                                if (changed) endpointsChanged(entry)
                            }
                        }
                        launch {
                            currentCallEndpoint.collect {
                                val changed = entry.current?.identifier != it.identifier
                                entry.current = it
                                if (changed) endpointsChanged(entry)
                            }
                        }
                    }
                    callsChanged()
                    replied = true
                    result.success(null)
                }
                // The session is over (a disconnect, or a callback failed).
                finish(entry, entry.endingReason ?: "failed")
            } catch (e: CancellationException) {
                // Ended before Telecom had it.
                finish(entry, entry.endingReason ?: "failed")
                if (!replied) {
                    replied = true
                    result.error("failed", "The call ended before it was added.", null)
                }
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "System call $id failed: $e")
                if (replied) {
                    finish(entry, entry.endingReason ?: "failed")
                } else {
                    entry.ended = true
                    calls.remove(id)
                    callsChanged()
                    result.error(errorCodeOf(e), e.message, null)
                }
            }
        }
    }

    private fun reportConnected(entry: SystemCallEntry, result: MethodChannel.Result) {
        val control = entry.control ?: throw SystemCallError("unavailable", "The call isn't in Telecom yet.")
        if (entry.state == "active" || entry.state == "held") return result.success(null)
        scope.launch {
            when (val outcome = control.setActive()) {
                is CallControlResult.Success -> {
                    becameActive(entry)
                    result.success(null)
                }
                is CallControlResult.Error -> result.error(errorCodeOf(outcome.errorCode), "setActive: $outcome", null)
            }
        }
    }

    private fun answer(entry: SystemCallEntry, done: (Boolean) -> Unit) {
        val control = entry.control
        if (control == null || entry.outgoing || entry.state != "ringing") return done(false)
        scope.launch {
            val outcome = control.answer(callTypeOf(entry))
            if (outcome is CallControlResult.Success) answered(entry)
            done(outcome is CallControlResult.Success)
        }
    }

    private fun end(entry: SystemCallEntry, reason: String, done: (Boolean) -> Unit) {
        val control = entry.control
        if (entry.ended) return done(false)
        entry.endingReason = reason
        if (control == null) {
            // Not in Telecom yet: stop adding it.
            entry.job?.cancel()
            finish(entry, reason)
            return done(true)
        }
        val cause = when (reason) {
            "local" -> DisconnectCause.LOCAL
            "declined" -> DisconnectCause.REJECTED
            "unanswered" -> DisconnectCause.MISSED
            else -> DisconnectCause.REMOTE
        }
        scope.launch {
            val outcome = try {
                control.disconnect(DisconnectCause(cause))
            } catch (e: Exception) {
                Log.w(TAG, "System call ${entry.id}: disconnect failed: $e")
                null
            }
            // Telecom no longer has it either way.
            finish(entry, reason)
            done(outcome is CallControlResult.Success)
        }
    }

    private fun setHeld(call: MethodCall, result: MethodChannel.Result) {
        val entry = find(call) ?: return result.success(false)
        val onHold = call.argument<Boolean>("onHold") == true
        val control = entry.control ?: return result.success(false)
        if (onHold && entry.state == "held" || !onHold && entry.state == "active") return result.success(true)
        if (entry.state != "active" && entry.state != "held") return result.success(false)
        scope.launch {
            val outcome = if (onHold) control.setInactive() else control.setActive()
            if (outcome is CallControlResult.Success) held(entry, onHold)
            else Log.w(TAG, "System call ${entry.id}: hold $onHold refused: $outcome")
            result.success(outcome is CallControlResult.Success)
        }
    }

    /**
     * Core-Telecom 1.0 has no per-call mute: the system's mute is the global
     * microphone mute, which its `isMuted` flow reports (docs/design.md §4.8).
     */
    private fun setMuted(call: MethodCall, result: MethodChannel.Result) {
        if (find(call) == null) return result.success(false)
        val muted = call.argument<Boolean>("muted") == true
        audio.isMicrophoneMute = muted
        val now = audio.isMicrophoneMute
        for (entry in calls.values.toList()) mutedChanged(entry, now)
        result.success(now == muted)
    }

    private fun selectEndpoint(call: MethodCall, result: MethodChannel.Result) {
        val entry = find(call) ?: return result.success(false)
        val routeId = call.argument<String>("routeId") ?: return result.success(false)
        val control = entry.control ?: return result.success(false)
        val endpoint = entry.endpoints.firstOrNull { it.identifier.uuid.toString() == routeId }
            ?: return result.success(false)
        scope.launch {
            val outcome = control.requestEndpointChange(endpoint)
            if (outcome !is CallControlResult.Success) {
                Log.w(TAG, "System call ${entry.id}: endpoint change refused: $outcome")
            }
            result.success(outcome is CallControlResult.Success)
        }
    }

    // --- What happened (from the app's requests and from Telecom) ----------

    private fun onSystemAnswer(entry: SystemCallEntry) {
        if (entry.state == "ringing") answered(entry)
    }

    /**
     * Telecom ended the call. The package's own Decline and Hang up, and
     * Dart's `end`, never get here with a reason to find: they set
     * [SystemCallEntry.endingReason] first. So this is Telecom, for someone
     * else (docs/design.md §4.8, Who ended a ringing call):
     *
     * - `REJECTED`: Telecom's reject, which a person asks for (a Bluetooth
     *   headset, a car or a watch declining it): `declined`.
     * - Telecom's disconnect of a ringing call (it makes room for an
     *   emergency call or a phone call the user places, or a companion
     *   app ends it) carries Telecom's own cause on Android 14+, `UNKNOWN`
     *   unless it set one, and is `LOCAL` through Core-Telecom's
     *   `ConnectionService` below 14. Nobody declined it: `failed`, as for
     *   any other cause. Once answered, `LOCAL` is `local`.
     */
    private fun onSystemDisconnect(entry: SystemCallEntry, cause: DisconnectCause) {
        val ringing = !entry.outgoing && entry.state == "ringing"
        val reason = when (cause.code) {
            DisconnectCause.LOCAL -> if (ringing) "failed" else "local"
            DisconnectCause.REJECTED -> "declined"
            DisconnectCause.MISSED -> "unanswered"
            DisconnectCause.CANCELED -> if (entry.outgoing) "local" else "unanswered"
            DisconnectCause.REMOTE, DisconnectCause.BUSY -> "remoteEnded"
            DisconnectCause.ANSWERED_ELSEWHERE -> "answeredElsewhere"
            else -> "failed"
        }
        Log.i(TAG, "System call ${entry.id}: Telecom disconnected it ($cause), ringing $ringing")
        entry.endingReason = entry.endingReason ?: reason
        finish(entry, entry.endingReason!!)
    }

    private fun onSystemSetActive(entry: SystemCallEntry) {
        when (entry.state) {
            "held" -> held(entry, false)
            "dialing", "connecting" -> becameActive(entry)
        }
    }

    private fun onSystemSetInactive(entry: SystemCallEntry) {
        if (entry.state == "active") held(entry, true)
    }

    private fun onSystemMuted(entry: SystemCallEntry, muted: Boolean) {
        // Telecom applies its mute to the global microphone mute before it
        // reports it; a value that disagrees with it is an older one,
        // crossing a newer request.
        if (muted != audio.isMicrophoneMute) return
        mutedChanged(entry, muted)
    }

    private fun answered(entry: SystemCallEntry) {
        if (entry.ended || entry.state != "ringing") return
        entry.state = "active"
        entry.activeSince = System.currentTimeMillis()
        emit(mapOf("event" to "answered", "id" to entry.id))
        emit(mapOf("event" to "audioActivated"))
        callsChanged()
    }

    private fun becameActive(entry: SystemCallEntry) {
        if (entry.ended || entry.state == "active") return
        entry.state = "active"
        if (entry.activeSince == 0L) entry.activeSince = System.currentTimeMillis()
        emit(mapOf("event" to "audioActivated"))
        callsChanged()
    }

    private fun held(entry: SystemCallEntry, onHold: Boolean) {
        if (entry.ended || (entry.state == "held") == onHold) return
        entry.state = if (onHold) "held" else "active"
        emit(mapOf("event" to "held", "id" to entry.id, "onHold" to onHold))
        emit(mapOf("event" to if (onHold) "audioDeactivated" else "audioActivated"))
        callsChanged()
    }

    private fun mutedChanged(entry: SystemCallEntry, muted: Boolean) {
        if (entry.ended || entry.muted == muted) return
        entry.muted = muted
        emit(mapOf("event" to "muted", "id" to entry.id, "muted" to muted))
    }

    // The list and the current endpoint often change together: one event.
    private fun endpointsChanged(entry: SystemCallEntry) {
        if (entry.ended || !endpointsPending.add(entry.id)) return
        main.post {
            endpointsPending.remove(entry.id)
            if (!entry.ended) emit(mapOf("event" to "endpointsChanged", "id" to entry.id))
        }
    }

    /** The call is over: an `ended` event once, and the service follows. */
    private fun finish(entry: SystemCallEntry, reason: String) {
        if (entry.ended) return
        entry.ended = true
        entry.collectors?.cancel()
        calls.remove(entry.id)
        emit(mapOf("event" to "ended", "id" to entry.id, "reason" to reason))
        if (calls.isEmpty()) {
            // The system's mute belongs to the call: don't leave the
            // microphone muted for whatever comes next.
            if (audio.isMicrophoneMute) audio.isMicrophoneMute = false
            clearLockScreen()
        }
        callsChanged()
    }

    /** The calls changed: the service's type, its notification. */
    private fun callsChanged() {
        CallService.sync(app) { error ->
            if (error != null && hasCalls) {
                // Android refused the service (a start from the background):
                // Telecom still needs the call's notification.
                Log.w(TAG, "Call service not started for the system call: $error")
                buildNotification(app)?.let {
                    (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                        .notify(CallService.NOTIFICATION_ID, it)
                }
            }
        }
    }

    // --- The notification and its actions ----------------------------------

    /**
     * The call's notification while a call is in Telecom, else `null`: an
     * incoming one (full screen, Answer and Decline, ringing) while a call
     * rings, else the newest call's ongoing one (Hang up).
     */
    fun buildNotification(context: Context): Notification? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val added = calls.values.filter { it.added }
        val call = added.firstOrNull { !it.outgoing && it.state == "ringing" } ?: added.lastOrNull() ?: return null
        val incoming = !call.outgoing && call.state == "ringing"
        val channel = if (incoming) incomingChannel(context) else CallService.channel(context)
        val name = call.displayName?.takeIf { it.isNotEmpty() } ?: call.handle
        val builder = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.cloudflare_realtime_call)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentTitle(name)
            .setContentText(
                context.getString(
                    when {
                        incoming && call.video -> R.string.cloudflare_realtime_call_incoming_video
                        incoming -> R.string.cloudflare_realtime_call_incoming
                        call.outgoing && call.state != "active" && call.state != "held" ->
                            R.string.cloudflare_realtime_call_outgoing
                        else -> R.string.cloudflare_realtime_call_ongoing
                    },
                ),
            )
        activityIntent(context, ACTION_SHOW, call.id)?.let { builder.setContentIntent(it) }
        val person = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Person.Builder().setName(name).setImportant(true).build()
        } else {
            null
        }
        if (incoming) {
            activityIntent(context, ACTION_SHOW, call.id)?.let { builder.setFullScreenIntent(it, true) }
            val answer = activityIntent(context, ACTION_ANSWER, call.id)
            val decline = broadcastIntent(context, ACTION_DECLINE, call.id)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && answer != null && person != null) {
                builder.setStyle(Notification.CallStyle.forIncomingCall(person, decline, answer).setIsVideo(call.video))
            } else {
                answer?.let { builder.addAction(action(context, R.string.cloudflare_realtime_call_answer, it)) }
                builder.addAction(action(context, R.string.cloudflare_realtime_call_decline, decline))
            }
        } else {
            val hangUp = broadcastIntent(context, ACTION_HANG_UP, call.id)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && person != null) {
                builder.setStyle(Notification.CallStyle.forOngoingCall(person, hangUp).setIsVideo(call.video))
            } else {
                builder.addAction(action(context, R.string.cloudflare_realtime_call_hang_up, hangUp))
            }
            builder.setOnlyAlertOnce(true)
            if (call.activeSince != 0L) builder.setWhen(call.activeSince).setUsesChronometer(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
        }
        val notification = builder.build()
        // Rings (the channel's sound, the ringtone) until answered or ended:
        // replacing or removing the notification stops it.
        if (incoming) notification.flags = notification.flags or Notification.FLAG_INSISTENT
        return notification
    }

    private fun action(context: Context, label: Int, intent: PendingIntent) =
        Notification.Action.Builder(null, context.getString(label), intent).build()

    private fun incomingChannel(context: Context): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(INCOMING_CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        INCOMING_CHANNEL_ID,
                        context.getString(R.string.cloudflare_realtime_call_incoming_channel),
                        NotificationManager.IMPORTANCE_HIGH,
                    ).apply {
                        setSound(
                            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build(),
                        )
                        enableVibration(true)
                        vibrationPattern = longArrayOf(0, 1000, 1000)
                        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    },
                )
            }
        }
        return INCOMING_CHANNEL_ID
    }

    /**
     * The app's launch activity with [action]: Answer must open an activity
     * (Android 12+ forbids notification trampolines), which also brings the
     * app to the foreground for its microphone.
     */
    private fun activityIntent(context: Context, action: String, id: String): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        val intent = Intent(launch)
            .setAction(action)
            .putExtra(EXTRA_CALL_ID, id)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            requestCode(action, id),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun broadcastIntent(context: Context, action: String, id: String): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            requestCode(action, id),
            Intent(context, SystemCallActionReceiver::class.java).setAction(action).putExtra(EXTRA_CALL_ID, id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun requestCode(action: String, id: String) = (action + id).hashCode()

    /** Decline or Hang up in the notification. */
    fun onNotificationAction(context: Context, intent: Intent) {
        init(context)
        val entry = intent.getStringExtra(EXTRA_CALL_ID)?.let { calls[it] } ?: return
        when (intent.action) {
            ACTION_DECLINE -> end(entry, "declined") {}
            ACTION_HANG_UP -> end(entry, "local") {}
        }
    }

    /**
     * The activity was started (or brought back) by the notification:
     * Answer answers the call; Answer and the full-screen intent show the
     * activity over the lock screen until the last call ends.
     */
    fun onActivityIntent(activity: Activity, intent: Intent?): Boolean {
        val action = intent?.action
        if (action != ACTION_ANSWER && action != ACTION_SHOW) return false
        val entry = intent.getStringExtra(EXTRA_CALL_ID)?.let { calls[it] }
        // Handled once: not again when the activity is recreated.
        intent.action = Intent.ACTION_MAIN
        intent.removeExtra(EXTRA_CALL_ID)
        if (entry == null) return true
        showOverLockScreen(activity)
        if (action == ACTION_ANSWER) answer(entry) {}
        return true
    }

    private fun showOverLockScreen(activity: Activity) {
        lockScreenActivity = WeakReference(activity)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            activity.setShowWhenLocked(true)
            activity.setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            activity.window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
    }

    private fun clearLockScreen() {
        val activity = lockScreenActivity?.get() ?: return
        lockScreenActivity = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            activity.setShowWhenLocked(false)
            activity.setTurnScreenOn(false)
        } else {
            @Suppress("DEPRECATION")
            activity.window.clearFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
    }

    // --- Conversions -------------------------------------------------------

    private fun callTypeOf(entry: SystemCallEntry) =
        if (entry.video && supportsVideo) {
            CallAttributesCompat.CALL_TYPE_VIDEO_CALL
        } else {
            CallAttributesCompat.CALL_TYPE_AUDIO_CALL
        }

    private fun addressOf(entry: SystemCallEntry): Uri = when (entry.handleType) {
        "phoneNumber" -> Uri.fromParts("tel", entry.handle, null)
        "emailAddress" -> Uri.fromParts("mailto", entry.handle, null)
        else -> Uri.fromParts("cloudflare-realtime", entry.handle, null)
    }

    internal fun routeOf(endpoint: CallEndpointCompat): Map<String, Any?> {
        val kind = when (endpoint.type) {
            CallEndpointCompat.TYPE_EARPIECE -> "earpiece"
            CallEndpointCompat.TYPE_SPEAKER -> "speaker"
            CallEndpointCompat.TYPE_WIRED_HEADSET -> "wiredHeadset"
            CallEndpointCompat.TYPE_BLUETOOTH -> "bluetooth"
            else -> "other"
        }
        // Built-in endpoints carry generic names; Dart names them by kind
        // (as call_audio's routes).
        val builtIn = kind == "speaker" || kind == "earpiece"
        return mapOf(
            "id" to endpoint.identifier.uuid.toString(),
            "kind" to kind,
            "name" to if (builtIn) "" else endpoint.name.toString(),
        )
    }

    private fun errorCodeOf(e: Exception): String = when (e) {
        is CallException -> errorCodeOf(e.code)
        is UnsupportedOperationException -> "unavailable"
        else -> "failed"
    }

    private fun errorCodeOf(code: Int): String = when (code) {
        CallException.ERROR_CALL_NOT_PERMITTED_AT_PRESENT_TIME,
        CallException.ERROR_CANNOT_HOLD_CURRENT_ACTIVE_CALL,
        CallException.ERROR_CALL_DOES_NOT_SUPPORT_HOLD,
        -> "unavailable"
        CallException.ERROR_CALL_IS_NOT_BEING_TRACKED -> "notFound"
        else -> "failed"
    }
}

/** One call in Telecom, as the registry keeps it. */
internal class SystemCallEntry(
    val id: String,
    val handle: String,
    val handleType: String,
    val displayName: String?,
    val video: Boolean,
    val outgoing: Boolean,
) {
    /** `ringing`, `dialing`, `connecting`, `active` or `held`. */
    var state = if (outgoing) "dialing" else "ringing"
    var muted = false
    var added = false
    var ended = false
    var endingReason: String? = null
    var activeSince = 0L
    var control: CallControlScope? = null
    var job: Job? = null
    var collectors: Job? = null
    var endpoints: List<CallEndpointCompat> = emptyList()
    var current: CallEndpointCompat? = null

    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "handle" to handle,
        "handleType" to handleType,
        "displayName" to displayName,
        "video" to video,
        "outgoing" to outgoing,
        "state" to state,
        "muted" to muted,
    )

    fun endpointsMap(): Map<String, Any?> = mapOf(
        "routes" to endpoints.map(SystemCallRegistry::routeOf),
        "current" to current?.let(SystemCallRegistry::routeOf),
    )
}

/** Decline and Hang up in the call's notification. */
class SystemCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        SystemCallRegistry.onNotificationAction(context, intent)
    }
}

/** One engine's end of the system calls channels; the registry is shared. */
internal class SystemCallsChannel :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) =
        SystemCallRegistry.onMethodCall(call, result)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink?.let(SystemCallRegistry::removeSink)
        sink = events
        SystemCallRegistry.addSink(events)
    }

    override fun onCancel(arguments: Any?) {
        sink?.let(SystemCallRegistry::removeSink)
        sink = null
    }

    fun dispose() = onCancel(null)
}
