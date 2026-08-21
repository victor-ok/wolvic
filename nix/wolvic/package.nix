{
  lib,
  stdenv,
  fetchFromGitHub,
  gradle_8,
  androidenv,
  jdk17,
  ninja,

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

  cmakeVersion = "3.22.1";
  ndkVersion   = "27.0.12077973";
  version      = "1.9";

  ndkPath = "${androidSdkPath}/ndk/${ndkVersion}";

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

  nativeBuildInputs = [ gradle ninja ];

  postPatch = ''
    # Fix 1: patch out `git rev-parse` — no .git dir in the sandbox
    substituteInPlace app/build.gradle \
      --replace-fail \
        "commandLine 'git', 'rev-parse', '--short', 'HEAD'" \
        "commandLine 'echo', 'v${finalAttrs.version}-nix'"

    # Fix 2: deterministic version code
    echo "useStaticVersionCode=true"     >> gradle.properties

    # Fix 3: debug signing so we don't need a real keystore
    echo "useDebugSigningOnRelease=true" >> gradle.properties

    # Fix 4: disable Gradle config cache
    echo "org.gradle.configuration-cache=false" >> gradle.properties
  '';

  env = {
    ANDROID_HOME     = androidSdkPath;
    ANDROID_SDK_ROOT = androidSdkPath;
    ANDROID_NDK_ROOT = ndkPath;
    ANDROID_NDK_HOME = ndkPath;
    JAVA_HOME        = "${jdk17}";
  };

  preBuild = ''
    export ANDROID_USER_HOME="$TMPDIR/.android"
    mkdir -p "$ANDROID_USER_HOME"

    # ── Provide a writable local.properties pointing at correct paths ────────
    # ndk.dir must be the versioned path (ndk/<version>), NOT ndk-bundle,
    # or AGP throws [CXX5304] "inconsistent location".
    cat > local.properties <<EOF
sdk.dir=${androidSdkPath}
ndk.dir=${ndkPath}
cmake.dir=$(echo ${androidSdkPath}/cmake/${cmakeVersion}.*/ | head -1 | sed 's:/*$::')
EOF

    # ── Put system ninja on PATH ahead of the NDK's bundled ninja ────────────
    # The Nix Android CMake package bundles a ninja that fails with
    #   ninja: fatal: posix_spawn: No such file or directory
    # inside the build sandbox. The nixpkgs `ninja` works correctly.
    export PATH="${ninja}/bin:$PATH"

    # ── Also add the CMake bin dir so `cmake` itself is found ────────────────
    NDK_CMAKE_BIN="$(echo "${androidSdkPath}/cmake/${cmakeVersion}".*/bin)"
    export PATH="$NDK_CMAKE_BIN:$PATH"

    # ── Force AGP to use the system ninja for its native builds ──────────────
    # -DCMAKE_MAKE_PROGRAM tells CMake which ninja to use; we inject it via a
    # gradle property that Wolvic's build.gradle forwards to externalNativeBuild.
    echo "Using ninja: $(command -v ninja)"
    ninja --version
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
    "-Pandroid.native.buildOutput=verbose"
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
    updateDeps = finalAttrs.finalPackage.mitmCache.updateScript;
  };

  meta = {
    description = "Wolvic XR Browser — noapi arm64 gecko debug APK";
    homepage    = "https://wolvic.com";
    license     = lib.licenses.mpl20;
    maintainers = [ ];
    platforms   = [ "x86_64-linux" ];
  };
})
