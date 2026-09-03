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
        inherit (pkgs) lib;

        pkgs = import nixpkgs {
          inherit system;
          config.android_sdk.accept_license = true;
          config.allowUnfree = true;
          overlays = [
            (final: prev: {
              etc2comp = final.callPackage ./nix/etc2comp/package.nix { };
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
        buildToolsVersion = androidComposition.buildToolsVersion;

        # ── Android SDK for the emulator (adds emulator + x86_64 image) ──────
        # Kept separate so `nix build .#default` doesn't force a ~2 GB
        # system-image download for everyone who just wants to compile the APK.
        androidCompositionEmu = pkgs.callPackage ./nix/android-composition.nix {
          includeEmulator     = true;
          includeSystemImages = true;
        };

        # ── APK derivation ────────────────────────────────────────────────────
        wolvicApk = pkgs.callPackage ./nix/wolvic/package.nix { 
          inherit androidComposition androidSdkPath;
        };

        # ── APK signing helper ────────────────────────────────────────────────
        signScript = pkgs.writeShellApplication {
          name = "sign-apk";
          runtimeInputs = [ pkgs.jdk17 pkgs.apksigner ];
          text = builtins.readFile ./nix/scripts/sign-apk.sh;
        };

        # ── Emulator convenience runner ───────────────────────────────────────
        # One-shot script: boot AVD, wait for boot-complete, install Wolvic,
        # open a URL.  Pass a URL as the first argument or it defaults to
        # https://wolvic.com
        runEmulator = pkgs.writeShellApplication {
          name = "run-emulator";
          text = pkgs.replaceVars ./nix/scripts/run-emulator.sh {
            emuSdk = "${androidCompositionEmu.androidsdk}/libexec/android-sdk";
          };
        };


      in
      {
        packages = {
          etc2comp       = pkgs.etc2comp;
          fxr-compressor = pkgs.fxr-compressor;

          default            = wolvicApk;
          wolvic-apk         = wolvicApk;
          wolvic-noapi-debug = wolvicApk;
          wolvic-update-deps = wolvicApk.mitmCache.updateScript;

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
            app      = "${wolvicApk}";
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
