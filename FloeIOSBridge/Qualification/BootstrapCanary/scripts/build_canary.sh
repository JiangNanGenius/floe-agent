#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANARY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CANARY_DIR/../../.." && pwd)"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
JOBS="${CANARY_BUILD_JOBS:-6}"
CACHE="${CANARY_BUILD_CACHE:-$HOME/Library/Caches/CodexBuild/FloeIOSBridge/bootstrap-canary/Xcode27.1/iphoneos}"
ARTIFACT_DIR="${CANARY_ARTIFACT_DIR:-$REPO_ROOT/Local/Artifacts/ios-bridge-20261031/canary}"
SCRATCH_DIR="${CANARY_SCRATCH_DIR:-$REPO_ROOT/Local/Scratch/ios-bridge-20261031/canary}"
BUILD_DIR="$CACHE/Build/Products/Release-iphoneos"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"

if [ ! -x "$XCODEBUILD" ]; then
    echo "error: xcodebuild not found at $XCODEBUILD" >&2
    exit 1
fi

mkdir -p "$CACHE" "$ARTIFACT_DIR" "$SCRATCH_DIR"
cd "$CANARY_DIR"

if command -v xcodegen >/dev/null 2>&1 && [ "${CANARY_NO_XCODEGEN:-0}" != "1" ]; then
    xcodegen generate
fi

COMMON_ARGS=(
    -configuration Release
    -destination "generic/platform=iOS"
    -derivedDataPath "$CACHE"
    -jobs "$JOBS"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
    ARCHS=arm64
    ONLY_ACTIVE_ARCH=NO
)

{
    echo "DEVELOPER_DIR=$DEVELOPER_DIR"
    echo "$XCODEBUILD -project BootstrapCanary.xcodeproj -scheme BootstrapCanaryUITests ${COMMON_ARGS[*]} build"
    echo "$XCODEBUILD -project BootstrapCanary.xcodeproj -scheme BootstrapCanary ${COMMON_ARGS[*]} build"
    echo "/usr/bin/python3 $SCRIPT_DIR/package_canary.py --app $BUILD_DIR/BootstrapCanary.app --xctest $BUILD_DIR/BootstrapCanaryUITests-Runner.app/PlugIns/BootstrapCanaryUITests.xctest --output-dir $ARTIFACT_DIR --repo-root $REPO_ROOT --dSYM-host $BUILD_DIR/BootstrapCanary.app.dSYM --dSYM-test $BUILD_DIR/BootstrapCanaryUITests-Runner.app/PlugIns/BootstrapCanaryUITests.xctest.dSYM"
} > "$ARTIFACT_DIR/build-command.txt"

export DEVELOPER_DIR
echo "== building UI test bundle =="
"$XCODEBUILD" -project BootstrapCanary.xcodeproj -scheme BootstrapCanaryUITests \
    "${COMMON_ARGS[@]}" build 2>&1 | tee "$ARTIFACT_DIR/build-test.log"

echo "== building host app =="
"$XCODEBUILD" -project BootstrapCanary.xcodeproj -scheme BootstrapCanary \
    "${COMMON_ARGS[@]}" build 2>&1 | tee "$ARTIFACT_DIR/build-host.log"

XCTEST_PATH="$BUILD_DIR/BootstrapCanaryUITests-Runner.app/PlugIns/BootstrapCanaryUITests.xctest"
if [ ! -d "$XCTEST_PATH" ]; then
    XCTEST_PATH="$BUILD_DIR/BootstrapCanaryUITests.xctest"
fi
if [ ! -d "$XCTEST_PATH" ]; then
    echo "error: built .xctest bundle not found under $BUILD_DIR" >&2
    exit 1
fi
if [ ! -d "$BUILD_DIR/BootstrapCanary.app" ]; then
    echo "error: built host app not found at $BUILD_DIR/BootstrapCanary.app" >&2
    exit 1
fi

TEST_DSYM="$(dirname "$XCTEST_PATH")/BootstrapCanaryUITests.xctest.dSYM"
HOST_DSYM="$BUILD_DIR/BootstrapCanary.app.dSYM"

echo "== packaging unsigned IPA and evidence =="
/usr/bin/python3 "$SCRIPT_DIR/package_canary.py" \
    --app "$BUILD_DIR/BootstrapCanary.app" \
    --xctest "$XCTEST_PATH" \
    --output-dir "$ARTIFACT_DIR" \
    --repo-root "$REPO_ROOT" \
    --dSYM-host "$HOST_DSYM" \
    --dSYM-test "$TEST_DSYM" | tee "$ARTIFACT_DIR/package-result.json"

IPA="$ARTIFACT_DIR/BootstrapCanary-unsigned.ipa"
rm -f "$ARTIFACT_DIR/otool-L-host.txt" "$ARTIFACT_DIR/otool-L-test.txt"
/usr/bin/otool -L "$ARTIFACT_DIR/BootstrapCanary.app/BootstrapCanary" > "$ARTIFACT_DIR/otool-dylibs-host.txt"
/usr/bin/otool -l "$ARTIFACT_DIR/BootstrapCanary.app/BootstrapCanary" > "$ARTIFACT_DIR/otool-loadcommands-host.txt"
/usr/bin/otool -L "$ARTIFACT_DIR/BootstrapCanary.app/PlugIns/BootstrapCanaryUITests.xctest/BootstrapCanaryUITests" > "$ARTIFACT_DIR/otool-dylibs-test.txt"
/usr/bin/otool -l "$ARTIFACT_DIR/BootstrapCanary.app/PlugIns/BootstrapCanaryUITests.xctest/BootstrapCanaryUITests" > "$ARTIFACT_DIR/otool-loadcommands-test.txt"
/usr/bin/plutil -p "$ARTIFACT_DIR/BootstrapCanary.app/Info.plist" > "$ARTIFACT_DIR/plutil-host.txt"
/usr/bin/plutil -p "$ARTIFACT_DIR/BootstrapCanary.app/PlugIns/BootstrapCanaryUITests.xctest/Info.plist" > "$ARTIFACT_DIR/plutil-test.txt"
/usr/bin/file "$ARTIFACT_DIR/BootstrapCanary.app/BootstrapCanary" > "$ARTIFACT_DIR/file-host.txt"
/usr/bin/file "$ARTIFACT_DIR/BootstrapCanary.app/PlugIns/BootstrapCanaryUITests.xctest/BootstrapCanaryUITests" > "$ARTIFACT_DIR/file-test.txt"
/usr/bin/python3 "$SCRIPT_DIR/verify_canary.py" \
    --app "$ARTIFACT_DIR/BootstrapCanary.app" \
    --ipa "$IPA" > "$ARTIFACT_DIR/verify.txt"

echo "== result =="
/usr/bin/shasum -a 256 "$IPA"
du -sh "$IPA" "$ARTIFACT_DIR/BootstrapCanary.app"
echo "artifact: $IPA"
echo "sign with: $SCRIPT_DIR/sign_canary_ipa.sh --ipa $IPA --profile <profile-path-or-uuid> --identity <codesign-identity> --output $ARTIFACT_DIR/BootstrapCanary-signed.ipa"
