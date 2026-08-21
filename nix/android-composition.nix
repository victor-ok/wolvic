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

androidenv.composeAndroidPackages {
  buildToolsVersions = [ "35.0.0" ];
  platformVersions = [ "35" ];
  includeNDK = true;
  ndkVersions = [ "27.0.12077973" ];
  cmakeVersions = [ "3.22.1" ];
  inherit includeEmulator includeSystemImages;
  abiVersions = [
    "x86_64"
    "arm64-v8a"
  ];
}
