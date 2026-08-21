{
  lib,
  stdenv,
  fetchFromGitHub,
  gradle_8,
  androidenv,
  jdk17,
  ninja,
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

    # ── Fix 5: force nixpkgs ninja as CMAKE_MAKE_PROGRAM ─────────────────────
    # AGP passes -DCMAKE_MAKE_PROGRAM pointing at the SDK's bundled ninja, which
    # fails with "posix_spawn: No such file or directory" in the Nix sandbox.
    # CMAKE_MAKE_PROGRAM in the defaultConfig cmake {} arguments propagates to
    # ALL native sub-invocations including the compiler check, so this is the
    # reliable place to override it.
    # The exact literal in app/build.gradle (defaultConfig) is:
    #   arguments "-DANDROID_STL=c++_shared"
    substituteInPlace app/build.gradle \
      --replace-fail \
        'arguments "-DANDROID_STL=c++_shared"' \
        'arguments "-DANDROID_STL=c++_shared", "-DCMAKE_MAKE_PROGRAM=${ninja}/bin/ninja"'

    # They use #!/usr/bin/env bash which doesn't exist in the sandbox.
    patchShebangs .
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

    # Locate the CMake directory robustly
    CMAKE_DIR=""
    for candidate in "${androidSdkPath}/cmake/${cmakeVersion}" "${androidSdkPath}/cmake/${cmakeVersion}".*; do
      if [ -x "$candidate/bin/cmake" ]; then
        CMAKE_DIR="$candidate"
        break
      fi
    done
    if [ -z "$CMAKE_DIR" ]; then
      echo "ERROR: could not locate cmake under ${androidSdkPath}/cmake/"
      ls -la "${androidSdkPath}/cmake/" || true
      exit 1
    fi
    echo "Resolved CMAKE_DIR=$CMAKE_DIR"

    cat > local.properties <<EOF
sdk.dir=${androidSdkPath}
ndk.dir=${ndkPath}
cmake.dir=$CMAKE_DIR
EOF
    echo "--- local.properties ---"
    cat local.properties

    export PATH="${ninja}/bin:$CMAKE_DIR/bin:$PATH"

    echo "Using ninja: $(command -v ninja)"
    ninja --version
    echo "Using cmake: $(command -v cmake)"
    cmake --version | head -1

    CLANG="${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
    if [ -x "$CLANG" ]; then
      echo "NDK clang version:"
      "$CLANG" --version 2>&1 | head -2 || echo "WARNING: clang --version failed"
    fi
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
