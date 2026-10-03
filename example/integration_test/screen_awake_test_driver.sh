#!/usr/bin/env bash
# Runs screen_awake_test.dart on an Android device or emulator and checks
# the screen with adb (docs/design.md §4.7, Keeping the screen on):
#
# - while the app builds and starts: wakes and unlocks the screen and keeps
#   it on (`stay_on_while_plugged_in`), so the camera can start;
# - at the first "CHECK SCREEN" (the test is running): lets the screen
#   sleep again, with a 15 s timeout;
# - at each "CHECK SCREEN": prints whether the app's window has
#   FLAG_KEEP_SCREEN_ON (`dumpsys window`) and the device's wakefulness
#   (`dumpsys power`: Awake, Dozing or Asleep);
# - at the end: restores both settings.
#
# Usage, from example/, with the device's adb ID in ANDROID_SERIAL and the
# broker settings as for any integration test (an emulator reaches a dev
# server on the host at http://10.0.2.2:8787, or use `adb reverse`):
#
#   ANDROID_SERIAL=emulator-5554 integration_test/screen_awake_test_driver.sh \
#     --dart-define=CF_REALTIME_BROKER_URL=http://10.0.2.2:8787 \
#     --dart-define=CF_REALTIME_BROKER_TOKEN=<dev token> \
#     --dart-define=CF_REALTIME_BROKER_USER=it-android
#
# ADB overrides the adb binary. The extra arguments go to `flutter test`
# unchanged and are never printed.
set -uo pipefail

: "${ANDROID_SERIAL:?Set ANDROID_SERIAL to the adb ID of the device.}"
export ANDROID_SERIAL
ADB=${ADB:-adb}
PACKAGE=dev.kammcs.cloudflare_realtime_example
LOG=$(mktemp -t screen_awake_test.XXXXXX)

setting() { "$ADB" shell settings get "$1" "$2" | tr -d '\r'; }
TIMEOUT=$(setting system screen_off_timeout)
STAY_ON=$(setting global stay_on_while_plugged_in)
restore() {
  "$ADB" shell settings put system screen_off_timeout "$TIMEOUT"
  "$ADB" shell settings put global stay_on_while_plugged_in "$STAY_ON"
}
trap restore EXIT
# Wake the screen and unlock it (no secure lock screen on a test device),
# and keep it on while the app builds.
"$ADB" shell settings put global stay_on_while_plugged_in 7
"$ADB" shell input keyevent KEYCODE_WAKEUP
"$ADB" shell wm dismiss-keyguard >/dev/null 2>&1 || true

flutter test integration_test/screen_awake_test.dart -d "$ANDROID_SERIAL" \
  --no-uninstall "$@" >"$LOG" 2>&1 &
TEST=$!
tail -n +1 -f "$LOG" &
TAIL=$!

count() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
checks=0
while kill -0 "$TEST" 2>/dev/null; do
  if [ "$(count 'CHECK SCREEN')" -gt "$checks" ]; then
    checks=$((checks + 1))
    if [ "$checks" -eq 1 ]; then
      echo "--- driver: the screen may sleep again, after 15 s"
      # User activity first (the screen is still kept on), so the 15 s
      # count from here, and a wake-up in case it went off meanwhile.
      "$ADB" shell input keyevent KEYCODE_SHIFT_LEFT
      "$ADB" shell settings put system screen_off_timeout 15000
      "$ADB" shell settings put global stay_on_while_plugged_in 0
      "$ADB" shell input keyevent KEYCODE_WAKEUP
      "$ADB" shell wm dismiss-keyguard >/dev/null 2>&1 || true
    fi
    echo "--- driver: the app's window flags and the wakefulness"
    "$ADB" shell dumpsys window windows |
      grep -A40 "Window{.*$PACKAGE" | grep -m1 -o 'fl=[A-Z_ ]*' ||
      echo "(no window)"
    "$ADB" shell dumpsys power | grep -m1 -E 'mWakefulness=' | tr -d '\r'
  fi
  sleep 1
done
wait "$TEST"
STATUS=$?
sleep 1
kill "$TAIL" 2>/dev/null
rm -f "$LOG"
exit "$STATUS"
