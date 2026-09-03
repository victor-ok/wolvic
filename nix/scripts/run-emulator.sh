#!/usr/bin/env bash
set -euo pipefail

OPEN_URL="${1:-https://wolvic.com}"
EMU_SDK="@emuSdk@"
ADB="$EMU_SDK/platform-tools/adb"
AVDMGR="$EMU_SDK/cmdline-tools/bin/avdmanager"
EMU="$EMU_SDK/emulator/emulator"
DEVICE="wolvic-test"

export ANDROID_HOME="$EMU_SDK"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
mkdir -p "$ANDROID_AVD_HOME"

# Locate APK: env var → ./result/ → build first
if [ -n "${WOLVIC_APK:-}" ]; then
  APK_PATH="$WOLVIC_APK"
elif ls result/*.apk &>/dev/null 2>&1; then
  APK_PATH="$(ls result/*.apk | head -1)"
else
  echo "→ No APK in result/. Run 'nix build .#wolvic-apk' first."
  exit 1
fi
echo "→ Using APK: $APK_PATH"

# Create AVD if needed
if ! "$AVDMGR" list avd 2>/dev/null | grep -q "Name: $DEVICE"; then
  echo "→ Creating AVD '$DEVICE'..."
  echo "" | "$AVDMGR" create avd --force \
    -n "$DEVICE" \
    -k "system-images;android-35;default;x86_64" \
    -p "$ANDROID_AVD_HOME/$DEVICE.avd"
  CFG="$ANDROID_AVD_HOME/$DEVICE.avd/config.ini"
  printf 'hw.keyboard=yes\nhw.lcd.width=1920\nhw.lcd.height=1080\nhw.lcd.density=240\nhw.bluetooth=no\n' >> "$CFG"
fi

# Find a free port
PORT=""
for p in $(seq 5554 2 5584); do
  if [ -z "$("$ADB" devices 2>/dev/null | grep "emulator-$p")" ]; then
    PORT=$p; break
  fi
done
[ -z "$PORT" ] && { echo "All emulator ports are in use!"; exit 1; }
SERIAL="emulator-$PORT"
echo "→ Using port $PORT"

# Boot
echo "→ Booting emulator..."
"$EMU" -avd "$DEVICE" -port "$PORT" \
  -gpu swiftshader_indirect \
  -no-snapshot -no-boot-anim -no-audio \
  -memory 3072 -cores 4 &
EMU_PID=$!
trap "echo '→ Shutting down...'; kill $EMU_PID 2>/dev/null || true" EXIT

# Wait for boot-complete
echo "→ Waiting for boot..."
"$ADB" -s "$SERIAL" wait-for-device
until [ "$("$ADB" -s "$SERIAL" shell getprop dev.bootcomplete 2>/dev/null | tr -d '\r')" = "1" ]; do
  sleep 3
done
echo "→ Boot complete."

# Disable animations for faster UI response
"$ADB" -s "$SERIAL" shell settings put global window_animation_scale 0.0
"$ADB" -s "$SERIAL" shell settings put global transition_animation_scale 0.0
"$ADB" -s "$SERIAL" shell settings put global animator_duration_scale 0.0

# Install Wolvic
if "$ADB" -s "$SERIAL" shell pm list packages 2>/dev/null | grep -q "com.igalia.wolvic"; then
  echo "→ Wolvic already installed."
else
  echo "→ Installing $APK_PATH..."
  "$ADB" -s "$SERIAL" install -r "$APK_PATH"
  echo "→ Installed."
fi

# Launch with URL
echo "→ Opening $OPEN_URL in Wolvic..."
"$ADB" -s "$SERIAL" shell am start \
  -a android.intent.action.VIEW \
  -d "$OPEN_URL" \
  -n "com.igalia.wolvic/com.igalia.wolvic.VRBrowserActivity"

echo ""
echo "Wolvic is running. Ctrl-C to shut down."
echo "Tip: adb -s $SERIAL logcat -s GeckoView"
wait "$EMU_PID"
