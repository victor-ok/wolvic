{
  description = "Wolvic XR Browser dev environment and reproducible APK builds";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        inherit (nixpkgs.legacyPackages.${system}) lib;

        androidUnfreeNames = [
          "android-ndk"
          "android-sdk-ndk" 
          "ndk"                      
          "android-ndk-r27-linux.zip"
          "android-sdk-build-tools"
          "android-sdk-cmdline-tools"
          "android-sdk-platform-tools"
          "android-sdk-platforms"
          "android-sdk-tools"
          "build-tools"
          "cmake"
          "cmdline-tools"
          "emulator"                  # needed when includeEmulator = true
          "android-sdk-emulator"
          "ndk-bundle"
          "platform-tools"
          "platforms"
          "system-images"             # needed when includeSystemImages = true
          "android-sdk-system-images"
          "tools"
          "emulate-wolvic-noapi"
          "emulate-wolvic-with-app"
          "emulate-wolvic-emulator-bare"
        ];

        # ── pkgs ──────────────────────────────────────────────────────────────
        # FIXED: `overlays` must be a top-level key of the import attrset,
        # NOT nested inside `config`. Placing it inside config is silently
        # ignored by nixpkgs, which is why etc2comp / fxr-compressor were
        # never actually added to pkgs.
        pkgs = import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
          overlays = [
            (final: prev: {
              etc2comp      = final.callPackage ./nix/etc2comp/package.nix { };
              fxr-compressor = final.callPackage ./nix/compressor/package.nix { };
            })
          ];
        };

        # ── Android SDK (build only — no emulator, no system images) ─────────
        androidComposition = pkgs.callPackage ./nix/android-composition.nix {
          includeEmulator     = false;
          includeSystemImages = false;
        };
        androidSdkPath    = "${androidComposition.androidsdk}/libexec/android-sdk";
        buildToolsVersion = "35.0.0";

        # ── Android SDK for the emulator (adds emulator + x86_64 image) ──────
        # Kept separate so `nix build .#default` doesn't force a ~2 GB
        # system-image download for everyone who just wants to compile the APK.
        androidCompositionEmu = pkgs.callPackage ./nix/android-composition.nix {
          includeEmulator     = true;
          includeSystemImages = true;
        };

        # ── APK derivation ────────────────────────────────────────────────────
        wolvicPackage = pkgs.callPackage ./nix/wolvic/package.nix { 
          androidenv = pkgs.androidenv;
        };

        # ── APK signing helper ────────────────────────────────────────────────
        signScript = pkgs.writeShellScriptBin "sign-apk" ''
          set -euo pipefail
          mkdir -p build
          pushd build > /dev/null

          if [ ! -f release.keystore ]; then
            echo "Generating new release.keystore..."
            ${pkgs.jdk17}/bin/keytool \
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
            SIGNED_NAME="signed-''${BASE_NAME/-unsigned/}"
            echo "Signing $SIGNED_NAME..."
            cp "$APK_PATH" "$SIGNED_NAME"
            chmod +w "$SIGNED_NAME"
            ${pkgs.apksigner}/bin/apksigner sign \
              --ks release.keystore --ks-key-alias androiddebugkey \
              --ks-pass pass:android --key-pass pass:android \
              "$SIGNED_NAME"
            ${pkgs.apksigner}/bin/apksigner verify "$SIGNED_NAME" \
              && echo "  ✓ Verified OK"
          done

          echo "Done. Signed APKs are in $(pwd)/"
          popd > /dev/null
        '';

        # ── Emulator convenience runner ───────────────────────────────────────
        # One-shot script: boot AVD, wait for boot-complete, install Wolvic,
        # open a URL.  Pass a URL as the first argument or it defaults to
        # https://wolvic.com
        runEmulator = pkgs.writeShellScriptBin "run-emulator" ''
          set -euo pipefail

          OPEN_URL="''${1:-https://wolvic.com}"
          EMU_SDK="${androidCompositionEmu.androidsdk}/libexec/android-sdk"
          ADB="$EMU_SDK/platform-tools/adb"
          AVDMGR="$EMU_SDK/cmdline-tools/bin/avdmanager"
          EMU="$EMU_SDK/emulator/emulator"
          DEVICE="wolvic-test"

          export ANDROID_HOME="$EMU_SDK"
          export ANDROID_AVD_HOME="''${ANDROID_AVD_HOME:-$HOME/.android/avd}"
          mkdir -p "$ANDROID_AVD_HOME"

          # Locate APK: env var → ./result/ → build first
          if [ -n "''${WOLVIC_APK:-}" ]; then
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
          wait $EMU_PID
        '';

      in
      {
        # ── Packages ──────────────────────────────────────────────────────────
        packages = {
          etc2comp       = pkgs.etc2comp;
          fxr-compressor = pkgs.fxr-compressor;

          default            = wolvicPackage;
          wolvic-apk         = wolvicPackage;
          wolvic-noapi-debug = wolvicPackage;
          wolvic-update-deps = wolvicPackage.mitmCache.updateScript;

          # ── Bare emulator (no APK pre-loaded) ───────────────────────────────
          # Use this to confirm your AVD / KVM setup works before the APK build.
          #   nix run .#emulator
          emulator = pkgs.androidenv.emulateApp {
            name            = "emulate-wolvic-noapi";
            platformVersion = "35";
            abiVersion      = "x86_64";
            systemImageType = "default";
            deviceName      = "wolvic-test";
            configOptions   = {
              "hw.keyboard"    = "yes";
              "hw.lcd.width"   = "1920";
              "hw.lcd.height"  = "1080";
              "hw.lcd.density" = "240";
              "hw.bluetooth"   = "no";
            };
            androidEmulatorFlags = lib.concatStringsSep " " [
              "-gpu swiftshader_indirect"
              "-no-snapshot"
              "-no-boot-anim"
              "-no-audio"
              "-memory 3072"
              "-cores 4"
            ];
            sdkExtraArgs = {
              # Pull the emulator from the emu composition, not the build one
              includeEmulator     = true;
              includeSystemImages = true;
              systemImageTypes    = [ "default" ];
              abiVersions         = [ "x86_64" ];
            };
          };

          # ── Full emulator: boots + installs + launches Wolvic ────────────────
          # Requires `nix build .#wolvic-apk` to have run first.
          #   nix run .#emulator-with-app
          emulator-with-app = pkgs.androidenv.emulateApp {
            name            = "emulate-wolvic-with-app";
            platformVersion = "35";
            abiVersion      = "x86_64";
            systemImageType = "default";
            deviceName      = "wolvic-test-app";
            configOptions   = {
              "hw.keyboard"    = "yes";
              "hw.lcd.width"   = "1920";
              "hw.lcd.height"  = "1080";
              "hw.lcd.density" = "240";
              "hw.bluetooth"   = "no";
            };
            androidEmulatorFlags = lib.concatStringsSep " " [
              "-gpu swiftshader_indirect"
              "-no-snapshot"
              "-no-boot-anim"
              "-no-audio"
              "-memory 3072"
              "-cores 4"
            ];
            sdkExtraArgs = {
              includeEmulator     = true;
              includeSystemImages = true;
              systemImageTypes    = [ "default" ];
              abiVersions         = [ "x86_64" ];
            };
            # Wire the Nix-built APK directly — emulateApp globs for *.apk
            app      = "${wolvicPackage}";
            package  = "com.igalia.wolvic";
            activity = "com.igalia.wolvic.VRBrowserActivity";
          };

          # ── One-shot runner script ────────────────────────────────────────────
          # Boot → wait → install → open URL.  Usage:
          #   nix run .#run-emulator
          #   nix run .#run-emulator -- https://example.com
          run-emulator = runEmulator;
        };

        # ── Apps (nix run targets) ─────────────────────────────────────────────
        apps = {
          sign-apk = {
            type    = "app";
            program = "${lib.getExe signScript}";
          };
          emulator = {
            type    = "app";
            program = "${pkgs.androidenv.emulateApp {
              name            = "emulate-wolvic-noapi";
              platformVersion = "35";
              abiVersion      = "x86_64";
              systemImageType = "default";
              sdkExtraArgs    = {
                includeEmulator     = true;
                includeSystemImages = true;
                systemImageTypes    = [ "default" ];
                abiVersions         = [ "x86_64" ];
              };
            }}/bin/run-test-emulator";
          };
          run-emulator = {
            type    = "app";
            program = "${lib.getExe runEmulator}";
          };
        };

        # ── Dev shell ──────────────────────────────────────────────────────────
        devShells.default = pkgs.mkShell {
          name = "wolvic-dev";

          packages = with pkgs; [
            androidComposition.androidsdk
            android-tools
            fxr-compressor
            gitMinimal
            gradle_8
            jdk17
            ninja
            python3
            signScript
            runEmulator        
          ];

          env = {
            ANDROID_HOME     = androidSdkPath;
            ANDROID_SDK_ROOT = androidSdkPath;
            ANDROID_NDK_ROOT = "${androidSdkPath}/ndk-bundle";
            JAVA_HOME        = "${pkgs.jdk17}";
            GRADLE_OPTS      = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdkPath}/build-tools/${buildToolsVersion}/aapt2";
          };

          shellHook = ''
            export PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
            export GRADLE_USER_HOME="$PROJECT_ROOT/.gradle-home"
            mkdir -p "$GRADLE_USER_HOME"

            cmake_root="$(echo "$ANDROID_HOME/cmake/"*/)"
            export PATH="$cmake_root/bin:$PATH"

            cat > "$PROJECT_ROOT/local.properties" <<EOF
sdk.dir=$ANDROID_HOME
ndk.dir=$ANDROID_NDK_ROOT
cmake.dir=$cmake_root
EOF

            cat <<EOF

            ==================
             Wolvic dev shell
            ==================
             ANDROID_HOME    : $ANDROID_HOME
             ANDROID_NDK_ROOT: $ANDROID_NDK_ROOT
             JAVA_HOME       : $JAVA_HOME
            ==================

            Initialise submodules (required once):
              git submodule update --init --recursive

            Build APK with Gradle (interactive):
              ./gradlew app:assembleNoapiX64GeckoGenericDebug

            Build APK with Nix (reproducible):
              nix run .#wolvic-update-deps   # first time / after dep changes
              nix build .#wolvic-apk

            Sign built APKs from ./result:
              nix run .#sign-apk

            Run emulator (bare):
              nix run .#emulator

            Run emulator + install + open Wolvic:
              run-emulator
              run-emulator https://wolvic.com

            List assemble tasks:
              ./gradlew tasks --all | grep '^app:assemble'
            EOF
          '';
        };
      }
    );
}
