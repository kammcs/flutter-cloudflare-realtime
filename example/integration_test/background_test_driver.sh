#!/usr/bin/env bash
# Runs background_test.dart on an Android phone and plays the person's part
# with adb (docs/checkpoint.md §7):
#
# - "BACKGROUND NOW" in the test's log: presses Home
#   (input keyevent KEYCODE_HOME);
# - "FOREGROUND NOW": brings the app back (am start);
# - "CHECK SERVICES": prints the app's foreground services from
#   `dumpsys activity services` (CallService, its foreground state and
#   types: 0x40 camera, 0x80 microphone);
# - "CHECK PROXIMITY": prints the proximity wake lock from `dumpsys power`.
#
# Usage, from example/, with the phone's adb ID in ANDROID_SERIAL (adb uses
# it too) and the broker settings as for any integration test:
#
#   ANDROID_SERIAL=<android-id> integration_test/background_test_driver.sh \
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
LOG=$(mktemp -t background_test.XXXXXX)

flutter test integration_test/background_test.dart -d "$ANDROID_SERIAL" \
  --no-uninstall "$@" >"$LOG" 2>&1 &
TEST=$!
tail -n +1 -f "$LOG" &
TAIL=$!

count() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
background=0
foreground=0
services=0
proximity=0
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
  if [ "$(count 'CHECK SERVICES')" -gt "$services" ]; then
    services=$((services + 1))
    echo "--- driver: foreground services"
    "$ADB" shell dumpsys activity services "$PACKAGE" |
      grep -E 'ServiceRecord|isForeground|foregroundServiceType' ||
      echo "(no services)"
  fi
  if [ "$(count 'CHECK PROXIMITY')" -gt "$proximity" ]; then
    proximity=$((proximity + 1))
    echo "--- driver: proximity wake lock"
    "$ADB" shell dumpsys power | grep -i 'PROXIMITY_SCREEN_OFF' ||
      echo "(none held)"
  fi
  sleep 1
done
wait "$TEST"
STATUS=$?
sleep 1
kill "$TAIL" 2>/dev/null
rm -f "$LOG"
exit "$STATUS"
