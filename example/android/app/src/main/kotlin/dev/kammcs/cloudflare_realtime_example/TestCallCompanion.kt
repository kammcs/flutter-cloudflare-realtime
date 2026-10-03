package dev.kammcs.cloudflare_realtime_example

import android.os.Build
import android.telecom.Call
import android.telecom.InCallService

/**
 * For example/integration_test/system_call_test.dart only: a non-UI
 * `InCallService`, as a watch's or a car's companion app has, that Telecom
 * shows the app's own self-managed calls to. The test uses it to end a
 * ringing call from Telecom's side rather than the package's: a reject (a
 * watch's Decline) and a disconnect (the path Telecom takes when it makes
 * room for an emergency call or a phone call), docs/design.md §4.8.
 *
 * Declared in the debug manifest only. Telecom binds it only while the app
 * op `MANAGE_ONGOING_CALLS` is allowed, which system_call_test_driver.sh
 * sets with adb and resets afterwards; otherwise nothing binds it.
 */
class TestCallCompanion : InCallService() {
    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun ringing(): Call? = calls.firstOrNull {
        val state = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            it.details.state
        } else {
            @Suppress("DEPRECATION")
            it.state
        }
        state == Call.STATE_RINGING
    }

    companion object {
        @Volatile
        private var instance: TestCallCompanion? = null

        /** Whether Telecom bound the companion and showed it a ringing call. */
        fun seesRingingCall(): Boolean = instance?.ringing() != null

        /** `reject` or `disconnect` the ringing call, as Telecom's API does. */
        fun endRingingCall(how: String): Boolean {
            val call = instance?.ringing() ?: return false
            when (how) {
                "reject" -> call.reject(false, null)
                "disconnect" -> call.disconnect()
                else -> return false
            }
            return true
        }
    }
}
