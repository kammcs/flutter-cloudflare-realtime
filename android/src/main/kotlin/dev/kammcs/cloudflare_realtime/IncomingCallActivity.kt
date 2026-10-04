package dev.kammcs.cloudflare_realtime

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Outline
import android.os.Build
import android.os.Bundle
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The package's incoming-call screen (docs/design.md §4.8, The ring
 * activity and the lock screen): the only thing that shows over the lock
 * screen while a system call rings.
 *
 * The call notification's full-screen intent, its content intent while
 * ringing, and its Answer open it, never the app's launch activity. It is
 * declared `exported="false"` (only the package's own immutable
 * `PendingIntent`s start it), in its own task (`singleInstance`, its own
 * affinity, out of Recents), and needs no Flutter engine: plain views, and
 * the call answered and ended through [SystemCallRegistry], which is
 * process-wide (an FCM handler's engine reported the call; Dart learns of
 * the answer from the registry's events, buffered until it listens).
 *
 * - **Ringing:** the caller (their picture, else a monogram: [CallerAvatar])
 *   and Answer / Decline. Shown over the keyguard, and turning the screen
 *   on, only while the call exists (set here, in code, and cleared when it
 *   ends).
 * - **Answer** answers the call (the call's foreground service keeps its
 *   audio running while locked, as a phone call does), then asks for the
 *   keyguard to be dismissed. Only once it is gone (or the device isn't
 *   locked) does it open the app, with its plain launch intent. If the
 *   person cancels the unlock, the call stays answered here: the caller,
 *   Hang up and Open, still over the lock screen and still without the
 *   app.
 * - **Decline** ends the call `declined`. It never unlocks or opens the app.
 * - The call ending, however it ends, closes it.
 */
class IncomingCallActivity : Activity() {
    private companion object {
        const val TAG = "cloudflare_realtime"
        const val RED = 0xFFD93025.toInt()
        const val GREEN = 0xFF1E8E3E.toInt()
        const val BLUE = 0xFF1A73E8.toInt()
    }

    private var callId: String? = null
    private var answering = false
    private var unlocking = false
    private var closing = false
    private var wasRinging = false

    private lateinit var status: TextView
    private lateinit var avatar: ImageView
    private lateinit var name: TextView

    /** What [avatar] shows: the image, or the name its monogram is of. */
    private var avatarOf: Any? = null
    private lateinit var secondary: Button
    private lateinit var primary: Button

    private val observer: () -> Unit = { onCallsChanged() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SystemCallRegistry.init(applicationContext)
        buildViews()
        SystemCallRegistry.observe(observer)
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    override fun onDestroy() {
        SystemCallRegistry.unobserve(observer)
        setOverLockScreen(false, turnScreenOn = false)
        super.onDestroy()
    }

    // --- The call -----------------------------------------------------------

    private fun handle(intent: Intent?) {
        val action = intent?.action
        val entry = intent?.getStringExtra(SystemCallRegistry.EXTRA_CALL_ID)?.let(SystemCallRegistry::entry)
        // Answer is handled once: not again when the activity is recreated.
        if (action == SystemCallRegistry.ACTION_ANSWER) intent.action = SystemCallRegistry.ACTION_SHOW
        if (entry == null || entry.ended) {
            // The call ended before this opened (or the process is new and
            // has no calls): nothing to show, and nothing over the lock screen.
            close()
            return
        }
        callId = entry.id
        wasRinging = entry.ringing
        setOverLockScreen(true, turnScreenOn = entry.ringing)
        render()
        if (action == SystemCallRegistry.ACTION_ANSWER && entry.ringing) answer()
    }

    private fun current(): SystemCallEntry? = callId?.let(SystemCallRegistry::entry)?.takeUnless { it.ended }

    private fun onCallsChanged() {
        if (closing) return
        val entry = current() ?: return close()
        if (wasRinging && !entry.ringing && !answering) {
            // Answered elsewhere (a headset, a watch, the app in code): no
            // unlock prompt the person didn't ask for. The app opens now only
            // when the device isn't locked.
            wasRinging = false
            setOverLockScreen(true, turnScreenOn = false)
            if (!keyguard().isKeyguardLocked) return openApp()
        }
        render()
    }

    private fun answer() {
        val entry = current() ?: return close()
        if (answering) return
        answering = true
        render()
        SystemCallRegistry.answer(entry) { answered ->
            answering = false
            val now = current() ?: return@answer close()
            if (!answered && now.ringing) {
                Log.w(TAG, "Incoming call ${now.id}: Telecom refused the answer")
                render()
                return@answer
            }
            wasRinging = false
            // Don't turn the screen on again if it goes off during the call.
            setOverLockScreen(true, turnScreenOn = false)
            render()
            unlockThenOpenApp()
        }
    }

    private fun decline() {
        val entry = current() ?: return close()
        SystemCallRegistry.end(entry, if (entry.ringing) "declined" else "local") { close() }
    }

    // --- The keyguard and the app ---------------------------------------------

    private fun keyguard() = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    /**
     * Opens the app once the keyguard is gone, and never over it: the app's
     * activity has no lock-screen flags, and nothing here starts it while
     * the device is locked.
     */
    private fun unlockThenOpenApp() {
        if (closing) return
        val keyguard = keyguard()
        if (!keyguard.isKeyguardLocked) return openApp()
        if (unlocking || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        unlocking = true
        render()
        keyguard.requestDismissKeyguard(
            this,
            object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() {
                    unlocking = false
                    openApp()
                }

                override fun onDismissCancelled() {
                    // The call stays answered here, over the lock screen.
                    unlocking = false
                    render()
                }

                override fun onDismissError() {
                    unlocking = false
                    render()
                }
            },
        )
    }

    private fun openApp() {
        if (closing) return
        SystemCallRegistry.launchIntent(this)?.let {
            try {
                startActivity(it)
            } catch (e: Exception) {
                Log.w(TAG, "Could not open the app after answering: $e")
            }
        }
        close()
    }

    private fun close() {
        if (closing) return
        closing = true
        setOverLockScreen(false, turnScreenOn = false)
        // finish(), not finishAndRemoveTask(): removing a task of the app
        // stops CallService (stopWithTask), and with it the call's
        // foreground service. The empty task is out of Recents anyway.
        finish()
    }

    private var overLockScreen = false

    private fun setOverLockScreen(over: Boolean, turnScreenOn: Boolean) {
        if (over != overLockScreen) {
            overLockScreen = over
            Log.i(TAG, "Ring activity: over the lock screen $over (call $callId)")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(over)
            setTurnScreenOn(over && turnScreenOn)
        } else {
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
            @Suppress("DEPRECATION")
            if (over) window.addFlags(flags) else window.clearFlags(flags)
            @Suppress("DEPRECATION")
            val screen = WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (over && turnScreenOn) window.addFlags(screen) else window.clearFlags(screen)
        }
    }

    // --- The views --------------------------------------------------------------

    private fun render() {
        val entry = current() ?: return
        val caller = entry.callerName
        name.text = caller
        renderAvatar(entry.callerImage, caller)
        if (entry.ringing) {
            status.setText(
                if (entry.video) R.string.cloudflare_realtime_call_incoming_video else R.string.cloudflare_realtime_call_incoming,
            )
            secondary.setText(R.string.cloudflare_realtime_call_decline)
            primary.setText(R.string.cloudflare_realtime_call_answer)
            primary.backgroundTintList = ColorStateList.valueOf(GREEN)
            primary.isEnabled = !answering
            secondary.isEnabled = !answering
        } else {
            status.setText(R.string.cloudflare_realtime_call_ongoing)
            secondary.setText(R.string.cloudflare_realtime_call_hang_up)
            primary.setText(R.string.cloudflare_realtime_call_open)
            primary.backgroundTintList = ColorStateList.valueOf(BLUE)
            primary.isEnabled = !unlocking
            secondary.isEnabled = true
        }
        primary.contentDescription = "${primary.text}, $caller"
        secondary.contentDescription = "${secondary.text}, $caller"
        // Announced by screen readers when the window shows.
        title = "${status.text}: $caller"
    }

    /** The caller's image when the app gave one that decoded, else their monogram. */
    private fun renderAvatar(image: Bitmap?, caller: String) {
        val shows: Any = image ?: caller
        if (avatarOf == shows) return
        avatarOf = shows
        if (image != null) {
            avatar.setImageBitmap(image)
            avatar.contentDescription = getString(R.string.cloudflare_realtime_call_caller_photo, caller)
        } else {
            avatar.setImageDrawable(CallerAvatar.monogram(this, caller))
            avatar.contentDescription = getString(R.string.cloudflare_realtime_call_caller_initials, caller)
        }
    }

    private fun buildViews() {
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        // The theme's text colors (light or dark).
        fun themeColor(attr: Int): ColorStateList? {
            val value = TypedValue()
            if (!theme.resolveAttribute(attr, value, true)) return null
            return if (value.resourceId != 0) getColorStateList(value.resourceId) else ColorStateList.valueOf(value.data)
        }
        status = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 18f
            themeColor(android.R.attr.textColorSecondary)?.let(::setTextColor)
        }
        // A circle: the image cropped to it (the monogram draws its own).
        avatar = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setOval(0, 0, view.width, view.height)
                }
            }
            clipToOutline = true
        }
        name = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 32f
            themeColor(android.R.attr.textColorPrimary)?.let(::setTextColor)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(12), 0, 0)
        }
        fun button(color: Int?, onClick: () -> Unit) = Button(this).apply {
            minHeight = dp(64)
            textSize = 18f
            if (color != null) {
                backgroundTintList = ColorStateList.valueOf(color)
                setTextColor(Color.WHITE)
            }
            setOnClickListener { onClick() }
        }
        secondary = button(RED) { decline() }
        primary = button(GREEN) {
            val entry = current()
            when {
                entry == null -> close()
                entry.ringing -> answer()
                else -> unlockThenOpenApp()
            }
        }

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            val params = { LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(dp(8), 0, dp(8), 0) } }
            addView(secondary, params())
            addView(primary, params())
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(64), dp(24), dp(48))
            addView(status, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(
                avatar,
                LinearLayout.LayoutParams(dp(CallerAvatar.SIZE_DP), dp(CallerAvatar.SIZE_DP)).apply { topMargin = dp(32) },
            )
            addView(name, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(View(this@IncomingCallActivity), LinearLayout.LayoutParams(0, 0, 1f))
            addView(buttons, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        // The system bars' insets on the outer view, so the column keeps its
        // own padding (Android 15+ draws edge to edge).
        val root = FrameLayout(this).apply {
            fitsSystemWindows = true
            addView(column, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        setContentView(root)
    }
}
