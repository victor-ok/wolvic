{
  lib,
  stdenv,
  fetchFromGitHub,
  gradle_8,
  androidenv,
  jdk17,
}:

let
  gradle = gradle_8.override { java = jdk17; };

  androidComposition = androidenv.composeAndroidPackages {
    buildToolsVersions  = [ "35.0.0" ];
    platformVersions    = [ "35" ];
    includeNDK          = true;
    ndkVersions         = [ "27.0.12077973" ];
    cmakeVersions       = [ "3.22.1" ];
    includeSystemImages = false;
    includeEmulator     = false;
  };

  androidSdk     = androidComposition.androidsdk;
  androidSdkPath = "${androidSdk}/libexec/android-sdk";
  androidNdkPath = "${androidSdkPath}/ndk-bundle";

  cmakeVersion = "3.22.1";
  ndkVersion   = "27.0.12077973";
  version      = "1.9";

in
stdenv.mkDerivation (finalAttrs: {
  pname = "wolvic";
  inherit version;

  src = fetchFromGitHub {
    owner           = "Igalia";
    repo            = "wolvic";
    rev             = "v${finalAttrs.version}";
    hash            = "sha256-Itc9vIJ58QOfpKpoj/On1azLytPW67IEq8LoUjUrJpY=";
    fetchSubmodules = true;
  };

  nativeBuildInputs = [ gradle ];

  postPatch = ''
    # Fix 1: patch out `git rev-parse` — no .git dir in the sandbox
    substituteInPlace app/build.gradle \
      --replace-fail \
        "commandLine 'git', 'rev-parse', '--short', 'HEAD'" \
        "commandLine 'echo', 'v${finalAttrs.version}-nix'"

    # Fix 2: deterministic version code (date-derived by default)
    echo "useStaticVersionCode=true"     >> gradle.properties

    # Fix 3: debug signing so we don't need a real keystore
    echo "useDebugSigningOnRelease=true" >> gradle.properties

    # Fix 4: disable Gradle config cache (Nix store paths change between envs)
    echo "org.gradle.configuration-cache=false" >> gradle.properties
  '';

  env = {
    ANDROID_HOME     = androidSdkPath;
    ANDROID_SDK_ROOT = androidSdkPath;
    ANDROID_NDK_ROOT = androidNdkPath;
    JAVA_HOME        = "${jdk17}";
  };

  preBuild = ''
    export ANDROID_USER_HOME="$TMPDIR/.android"
    mkdir -p "$ANDROID_USER_HOME"

    # NDK bundles CMake under a build-number-suffixed path, e.g. 3.22.1.12345678/bin
    NDK_CMAKE_BIN="$(echo "${androidSdkPath}/cmake/${cmakeVersion}".*/bin)"
    export PATH="$NDK_CMAKE_BIN:$PATH"
  '';

  gradleUpdateTask = "assembleNoapiArm64GeckoGenericDebug";

  mitmCache = gradle.fetchDeps {
    pkg  = finalAttrs.finalPackage;
    data = ./deps.json;
  };

  __darwinAllowLocalNetworking = true;

  gradleFlags = [
    "-Dfile.encoding=utf-8"
    "-Dorg.gradle.configuration-cache=false"
    "-Pandroid.aapt2FromMavenOverride=${androidSdkPath}/build-tools/35.0.0/aapt2"
    "-Pandroid.injected.testOnly=false"
  ];

  gradleBuildTask = "assembleNoapiArm64GeckoGenericDebug";

  doCheck = false;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    find app/build/outputs/apk -name "*.apk" -exec cp -v {} "$out/" \;
    apk_count=$(find "$out" -name "*.apk" | wc -l)
    if [ "$apk_count" -eq 0 ]; then
      echo "ERROR: No APK found in app/build/outputs/apk"
      exit 1
    fi
    echo "Installed $apk_count APK(s) to $out"
    runHook postInstall
  '';

  passthru = {
    inherit cmakeVersion ndkVersion;
    updateDeps = finalAttrs.finalPackage.mitmCache;
  };

  meta = {
    description = "Wolvic XR Browser — noapi arm64 gecko debug APK";
    longDescription = ''
      Reproducible Nix build of the Wolvic XR Browser targeting the `noapi`
      platform variant (standard Android, no proprietary VR SDK required),
      using GeckoView (Firefox engine) as the web backend.
      Output is an unsigned debug APK; use the sign-apk devShell script
      to sign it for device installation.
    '';
    homepage    = "https://wolvic.com";
    license     = lib.licenses.mpl20;
    maintainers = [ ];
    platforms   = [ "x86_64-linux" ];
  };
})
