# Shared Android SDK/NDK composition for Wolvic.
#
# Keep build-tools, platform, NDK, and CMake versions aligned with app/build.gradle
# and the nixpkgs Android manual:
# https://github.com/NixOS/nixpkgs/blob/master/doc/languages-frameworks/android.section.md
{
  androidenv,
  includeEmulator ? "if-supported",
  includeSystemImages ? true,
}:

let
  buildToolsVersion = "35.0.0";
  platformVersion   = "35";
  ndkVersion        = "27.0.12077973";
  cmakeVersion      = "3.22.1";
in
(androidenv.composeAndroidPackages {
  buildToolsVersions = [ buildToolsVersion ];
  platformVersions   = [ platformVersion ];
  includeNDK         = true;
  ndkVersions        = [ ndkVersion ];
  cmakeVersions      = [ cmakeVersion ];
  inherit includeEmulator includeSystemImages;
  abiVersions = [
    "x86_64"
    "arm64-v8a"
  ];
}) // { inherit buildToolsVersion platformVersion ndkVersion cmakeVersion; }
