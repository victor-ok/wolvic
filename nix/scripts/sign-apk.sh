#!/usr/bin/env bash
set -euo pipefail

mkdir -p build
pushd build > /dev/null

if [ ! -f release.keystore ]; then
  echo "Generating new release.keystore..."
  keytool \
    -genkey -v -keystore release.keystore \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US" \
    -storepass android -keypass android
fi

APK_PATHS=$(find -L ../result -name "*.apk" 2>/dev/null || true)
if [ -z "$APK_PATHS" ]; then
  echo "No APKs found in result/. Did you run 'nix build .#wolvic-apk'?"
  exit 1
fi

for APK_PATH in $APK_PATHS; do
  BASE_NAME=$(basename "$APK_PATH")
  SIGNED_NAME="signed-${BASE_NAME/-unsigned/}"
  echo "Signing $SIGNED_NAME..."
  cp "$APK_PATH" "$SIGNED_NAME"
  chmod +w "$SIGNED_NAME"
  apksigner sign \
    --ks release.keystore --ks-key-alias androiddebugkey \
    --ks-pass pass:android --key-pass pass:android \
    "$SIGNED_NAME"
  apksigner verify "$SIGNED_NAME" \
    && echo "  ✓ Verified OK"
done

echo "Done. Signed APKs are in $(pwd)/"
popd > /dev/null
