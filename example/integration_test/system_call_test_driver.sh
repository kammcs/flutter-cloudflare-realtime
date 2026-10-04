#!/usr/bin/env bash
# Runs system_call_test.dart on an Android phone, plays the person's part
# with adb ("BACKGROUND NOW": Home; "FOREGROUND NOW": back to the app, as in
# background_test_driver.sh), and prints, at each "CHECK TELECOM" in the
# test's log, what Telecom and the foreground service look like
# (docs/design.md §4.8, docs/checkpoint.md):
#
# - Telecom's calls for the app (`dumpsys telecom`: the call's state, its
#   self-managed flag, the audio route);
# - the app's foreground services (`dumpsys activity services`: CallService
#   and its types, 0x4 phoneCall, 0x80 microphone);
# - the global microphone mute (`dumpsys audio`).
#
# At "INJECT NOW <call id>" it plays another app (docs/design.md §4.8, The
# ring activity and the lock screen): from adb's shell it sends the
# package's Answer action with the call's ID to the app's exported launch
# activity, and tries to start the package's ring activity, which isn't
# exported (refused). The test then checks that the call still rings.
#
# It also allows the app op MANAGE_ONGOING_CALLS (before the test, and again
# at "COMPANION NOW"), so Telecom binds the example's companion
# InCallService (debug builds), which ends a ringing call from Telecom's
# side; the op is reset when the test ends.
#
# Usage, from example/, with the phone's adb ID in ANDROID_SERIAL (adb uses
# it too) and the broker settings as for any integration test:
#
#   ANDROID_SERIAL=<android-id> integration_test/system_call_test_driver.sh \
#     --dart-define=CF_REALTIME_BROKER_URL=http://<dev server>:8787 \
#     --dart-define=CF_REALTIME_BROKER_TOKEN=<dev token> \
#     --dart-define=CF_REALTIME_BROKER_USER=it-android
#
# ADB overrides the adb binary. The extra arguments go to `flutter test`
# unchanged and are never printed.
set -uo pipefail

: "${ANDROID_SERIAL:?Set ANDROID_SERIAL to the adb ID of the phone.}"
export ANDROID_SERIAL
ADB=${ADB:-adb}
PACKAGE=dev.kammcs.cloudflare_realtime_example
LOG=$(mktemp -t system_call_test.XXXXXX)

# The call's service runs with phoneCall from the background too, and the
# example reports incoming calls: let it post notifications.
"$ADB" shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS 2>/dev/null
"$ADB" shell pm grant "$PACKAGE" android.permission.RECORD_AUDIO 2>/dev/null
# Telecom decides which InCallServices to bind when a call starts and keeps
# that while calls follow each other, so the companion's app op is allowed
# before the first call (and again at "COMPANION NOW", after a fresh
# install).
"$ADB" shell appops set "$PACKAGE" MANAGE_ONGOING_CALLS allow 2>/dev/null

flutter test integration_test/system_call_test.dart -d "$ANDROID_SERIAL" \
  --no-uninstall --dart-define=CF_REALTIME_SYSTEM_CALL_DRIVER=1 "$@" \
  >"$LOG" 2>&1 &
TEST=$!
tail -n +1 -f "$LOG" &
TAIL=$!

count() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
checks=0
background=0
foreground=0
companion=0
injected=0
while kill -0 "$TEST" 2>/dev/null; do
  if [ "$(count 'BACKGROUND NOW')" -gt "$background" ]; then
    background=$((background + 1))
    echo "--- driver: Home"
    "$ADB" shell input keyevent KEYCODE_HOME
  fi
  if [ "$(count 'FOREGROUND NOW')" -gt "$foreground" ]; then
    foreground=$((foreground + 1))
    echo "--- driver: back to the app"
    "$ADB" shell am start -n "$PACKAGE/.MainActivity" >/dev/null
  fi
  if [ "$companion" -eq 0 ] && [ "$(count 'COMPANION NOW')" -gt 0 ]; then
    companion=1
    echo "--- driver: let the test's companion InCallService see the calls"
    "$ADB" shell appops set "$PACKAGE" MANAGE_ONGOING_CALLS allow
  fi
  if [ "$injected" -eq 0 ] && [ "$(count 'INJECT NOW')" -gt 0 ]; then
    injected=1
    id=$(grep -o 'INJECT NOW [0-9a-f-]*' "$LOG" | head -n 1 | awk '{print $3}')
    echo "--- driver: a forged Answer to the app's launch activity (adb shell)"
    "$ADB" shell am start -n "$PACKAGE/.MainActivity" \
      -a dev.kammcs.cloudflare_realtime.action.ANSWER_CALL \
      --es dev.kammcs.cloudflare_realtime.extra.CALL_ID "$id" 2>&1
    echo "--- driver: the package's ring activity from adb's shell (must be refused)"
    "$ADB" shell am start \
      -n "$PACKAGE/dev.kammcs.cloudflare_realtime.IncomingCallActivity" \
      -a dev.kammcs.cloudflare_realtime.action.ANSWER_CALL \
      --es dev.kammcs.cloudflare_realtime.extra.CALL_ID "$id" 2>&1
  fi
  if [ "$(count 'CHECK TELECOM')" -gt "$checks" ]; then
    checks=$((checks + 1))
    echo "--- driver: Telecom's calls"
    "$ADB" shell dumpsys telecom |
      sed -n '/^  mCalls:/,/^    CallAudioModeStateMachine:/p' |
      grep -vE '^\s*$' | head -n 30
    echo "--- driver: foreground services"
    "$ADB" shell dumpsys activity services "$PACKAGE" |
      grep -E 'ServiceRecord|isForeground|foregroundServiceType' ||
      echo "(no services)"
    echo "--- driver: microphone mute"
    "$ADB" shell dumpsys audio | grep -E 'mic mute' | head -n 1
  fi
  sleep 1
done
wait "$TEST"
STATUS=$?
"$ADB" shell appops set "$PACKAGE" MANAGE_ONGOING_CALLS default 2>/dev/null
sleep 1
kill "$TAIL" 2>/dev/null
rm -f "$LOG"
exit "$STATUS"
