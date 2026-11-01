#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
JOBS="${FLOE_BRIDGE_JOBS:-6}"
CACHE="${FLOE_BRIDGE_CACHE:-$HOME/Library/Caches/CodexBuild/FloeIOSBridge/1.0/Xcode27.1/iphoneos}"
MODE="${FLOE_BRIDGE_MODE:-qualification}"
SOURCE_REF="${FLOE_BRIDGE_SOURCE_REF:-}"
MARKETING_VERSION="${FLOE_BRIDGE_MARKETING_VERSION:-}"
BUILD_NUMBER="${FLOE_BRIDGE_BUILD_NUMBER:-}"
IPA_NAME="${FLOE_BRIDGE_IPA_NAME:-}"
ARTIFACT_DIR="${FLOE_BRIDGE_ARTIFACT_DIR:-$REPO_ROOT/Local/Artifacts/ios-bridge-1.0-20261101/$MODE}"
SCRATCH_DIR="${FLOE_BRIDGE_SCRATCH_DIR:-$REPO_ROOT/Local/Scratch/ios-bridge-1.0-20261101/$MODE}"
CHECK_ONLY=0
OVERWRITE=0
GENERATE_PROJECT=""
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"

usage() {
    cat <<'USAGE'
usage: build_bridge.sh [--mode qualification|product-qualification|release]
       [--source-ref <commit>] [--marketing-version <x.y.z>]
       [--build-number <n>] [--ipa-name <name.ipa>]
       [--artifact-dir <dir>] [--scratch-dir <dir>] [--generate-project|--no-generate-project]
       [--overwrite] [--check]

Qualification is the legacy private DDI/device lane and defaults to
FloeBridge-unsigned.ipa plus the existing prototype surfaces.
Product-qualification is the private product-content lane: it requires an
explicit committed --source-ref, rejects prototype/file/bearer/LAN-control
markers, defaults to FloeBridge-product-unsigned.ipa and never creates a public
summary. Release requires an explicit committed --source-ref, uses
Floe-iOS-Bridge-<version>-unsigned.ipa and must remain unsigned. Release never
overwrites existing evidence unless --overwrite is explicit.

--check is read-only: it validates project identity, the pinned idevice lock and
source provenance without creating directories, fetching, generating, building
or rewriting any lock.
USAGE
}

fail() { echo "error: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --source-ref) SOURCE_REF="${2:-}"; shift 2 ;;
        --marketing-version) MARKETING_VERSION="${2:-}"; shift 2 ;;
        --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
        --ipa-name) IPA_NAME="${2:-}"; shift 2 ;;
        --artifact-dir) ARTIFACT_DIR="${2:-}"; shift 2 ;;
        --scratch-dir) SCRATCH_DIR="${2:-}"; shift 2 ;;
        --generate-project) GENERATE_PROJECT=1; shift ;;
        --no-generate-project) GENERATE_PROJECT=0; shift ;;
        --overwrite) OVERWRITE=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

case "$MODE" in
    qualification)
        [ -z "$IPA_NAME" ] || true
        IPA_NAME="${IPA_NAME:-FloeBridge-unsigned.ipa}"
        ;;
    product-qualification)
        [ -n "$SOURCE_REF" ] || fail "product-qualification requires an explicit --source-ref"
        IPA_NAME="${IPA_NAME:-FloeBridge-product-unsigned.ipa}"
        ;;
    release)
        [ -n "$SOURCE_REF" ] || fail "release requires an explicit --source-ref"
        [ -z "$IPA_NAME" ] || fail "release uses the canonical filename; do not pass --ipa-name"
        ;;
    *) fail "mode must be qualification, product-qualification or release" ;;
esac

PACKAGE_CHECK_ARGS=(
    --check
    --mode "$MODE"
    --project "$PROJECT_DIR/project.yml"
    --repo-root "$REPO_ROOT"
)
[ -n "$SOURCE_REF" ] && PACKAGE_CHECK_ARGS+=(--source-ref "$SOURCE_REF")
[ -n "$MARKETING_VERSION" ] && PACKAGE_CHECK_ARGS+=(--marketing-version "$MARKETING_VERSION")
[ -n "$BUILD_NUMBER" ] && PACKAGE_CHECK_ARGS+=(--build-number "$BUILD_NUMBER")

if [ "$CHECK_ONLY" = "1" ]; then
    /usr/bin/python3 -B "$SCRIPT_DIR/package_bridge.py" "${PACKAGE_CHECK_ARGS[@]}"
    exit $?
fi

[ -x "$XCODEBUILD" ] || fail "xcodebuild not found at $XCODEBUILD"
if [ -z "$GENERATE_PROJECT" ]; then
    if [ "$MODE" = "qualification" ]; then GENERATE_PROJECT=1; else GENERATE_PROJECT=0; fi
fi
if [ "$GENERATE_PROJECT" = "1" ]; then
    command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required when generating the project"
fi

if [ -e "$ARTIFACT_DIR/manifest.json" ] || compgen -G "$ARTIFACT_DIR/*.ipa" >/dev/null; then
    if [ "$OVERWRITE" != "1" ]; then
        fail "artifact directory already contains evidence: $ARTIFACT_DIR (use --overwrite to replace it)"
    fi
fi

mkdir -p "$CACHE" "$ARTIFACT_DIR" "$SCRATCH_DIR"
export DEVELOPER_DIR

echo "== preflight identity, source and pinned lock (read-only) =="
/usr/bin/python3 -B "$SCRIPT_DIR/package_bridge.py" "${PACKAGE_CHECK_ARGS[@]}" \
    > "$SCRATCH_DIR/preflight-check.json"
/usr/bin/python3 - "$SCRATCH_DIR/preflight-check.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(json.dumps({
    "mode": data["mode"],
    "identity": data["identity"],
    "sourceRef": data["sourceRef"],
    "sourceTreeSHA256": data["sourceTreeSHA256"],
    "sourceFileCount": data["sourceFileCount"],
}, indent=2, sort_keys=True))
if not data["ok"]:
    raise SystemExit("preflight failed: " + json.dumps(data["failures"]))
PY

echo "== verify pinned idevice slice =="
bash "$SCRIPT_DIR/fetch_idevice.sh"

echo "== core packet/lifecycle checks =="
FLOE_BRIDGE_SCRATCH="$SCRATCH_DIR" FLOE_BRIDGE_CHECK_OUTPUT="$ARTIFACT_DIR" \
    bash "$SCRIPT_DIR/run_core_checks.sh"

cd "$PROJECT_DIR"
if [ "$GENERATE_PROJECT" = "1" ]; then
    xcodegen generate
else
    [ -f "$PROJECT_DIR/FloeIOSBridge.xcodeproj/project.pbxproj" ] \
        || fail "release mode expects a committed/generated Xcode project"
    echo "using existing generated Xcode project (no xcodegen rewrite)"
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

PACKAGE_COMMAND="python3 $SCRIPT_DIR/package_bridge.py --app $CACHE/Build/Products/Release-iphoneos/BridgeHost.app --xctest <runner>/PlugIns/BridgeTests.xctest --output-dir $ARTIFACT_DIR --repo-root $REPO_ROOT --mode $MODE"
if [ "$MODE" != "release" ]; then
    PACKAGE_COMMAND="$PACKAGE_COMMAND --ipa-name $IPA_NAME"
fi
[ -n "$SOURCE_REF" ] && PACKAGE_COMMAND="$PACKAGE_COMMAND --source-ref $SOURCE_REF"

{
    echo "MODE=$MODE"
    echo "SOURCE_REF=$SOURCE_REF"
    echo "DEVELOPER_DIR=$DEVELOPER_DIR"
    echo "$XCODEBUILD -project FloeIOSBridge.xcodeproj -scheme BridgeTests ${COMMON_ARGS[*]} build"
    echo "$XCODEBUILD -project FloeIOSBridge.xcodeproj -scheme BridgeHost ${COMMON_ARGS[*]} build"
    echo "$PACKAGE_COMMAND"
} > "$ARTIFACT_DIR/build-command.txt"

echo "== building embedded test bundle =="
"$XCODEBUILD" -project FloeIOSBridge.xcodeproj -scheme BridgeTests \
    "${COMMON_ARGS[@]}" build 2>&1 | tee "$ARTIFACT_DIR/build-test.log"

echo "== building host + appex + core =="
"$XCODEBUILD" -project FloeIOSBridge.xcodeproj -scheme BridgeHost \
    "${COMMON_ARGS[@]}" build 2>&1 | tee "$ARTIFACT_DIR/build-host.log"

BUILD_DIR="$CACHE/Build/Products/Release-iphoneos"
[ -d "$BUILD_DIR/BridgeHost.app" ] || fail "host app missing at $BUILD_DIR/BridgeHost.app"
XCTEST_PATH="$BUILD_DIR/BridgeTests-Runner.app/PlugIns/BridgeTests.xctest"
if [ ! -d "$XCTEST_PATH" ]; then
    XCTEST_PATH="$BUILD_DIR/BridgeTests.xctest"
fi
[ -d "$XCTEST_PATH" ] || fail "built xctest bundle not found under $BUILD_DIR"

DSYMS=()
for candidate in \
    "$BUILD_DIR/BridgeHost.app.dSYM" \
    "$BUILD_DIR/BridgeTunnel.appex.dSYM" \
    "$BUILD_DIR/BridgeCore.framework.dSYM" \
    "$(dirname "$XCTEST_PATH")/BridgeTests.xctest.dSYM"; do
    if [ -d "$candidate" ]; then
        DSYMS+=(--dSYM "$candidate")
    fi
done
if [ "$MODE" = "release" ] && [ "${#DSYMS[@]}" -ne 8 ]; then
    fail "release requires host, appex, core and test dSYMs under $BUILD_DIR"
fi

echo "== packaging IPA =="
PACKAGE_ARGS=(
    --app "$BUILD_DIR/BridgeHost.app"
    --xctest "$XCTEST_PATH"
    --output-dir "$ARTIFACT_DIR"
    --repo-root "$REPO_ROOT"
    --project "$PROJECT_DIR/project.yml"
    --mode "$MODE"
)
[ -n "$SOURCE_REF" ] && PACKAGE_ARGS+=(--source-ref "$SOURCE_REF")
[ -n "$MARKETING_VERSION" ] && PACKAGE_ARGS+=(--marketing-version "$MARKETING_VERSION")
[ -n "$BUILD_NUMBER" ] && PACKAGE_ARGS+=(--build-number "$BUILD_NUMBER")
[ "$MODE" != "release" ] && PACKAGE_ARGS+=(--ipa-name "$IPA_NAME")
[ "$OVERWRITE" = "1" ] && PACKAGE_ARGS+=(--overwrite)
PACKAGE_ARGS+=("${DSYMS[@]}")

/usr/bin/python3 -B "$SCRIPT_DIR/package_bridge.py" "${PACKAGE_ARGS[@]}" \
    | tee "$ARTIFACT_DIR/package-result.json"
IPA="$(/usr/bin/python3 - "$ARTIFACT_DIR/package-result.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["ipa"])
PY
)"
[ -f "$IPA" ] || fail "packaged IPA missing: $IPA"

echo "== extracted evidence =="
/usr/bin/otool -L "$ARTIFACT_DIR/BridgeHost.app/BridgeHost" > "$ARTIFACT_DIR/otool-dylibs-host.txt"
/usr/bin/otool -l "$ARTIFACT_DIR/BridgeHost.app/BridgeHost" > "$ARTIFACT_DIR/otool-loadcommands-host.txt"
/usr/bin/otool -L "$ARTIFACT_DIR/BridgeHost.app/PlugIns/BridgeTunnel.appex/BridgeTunnel" > "$ARTIFACT_DIR/otool-dylibs-tunnel.txt"
/usr/bin/otool -L "$ARTIFACT_DIR/BridgeHost.app/PlugIns/BridgeTests.xctest/BridgeTests" > "$ARTIFACT_DIR/otool-dylibs-test.txt"
/usr/bin/plutil -p "$ARTIFACT_DIR/BridgeHost.app/Info.plist" > "$ARTIFACT_DIR/plutil-host.txt"
/usr/bin/plutil -p "$ARTIFACT_DIR/BridgeHost.app/PlugIns/BridgeTunnel.appex/Info.plist" > "$ARTIFACT_DIR/plutil-tunnel.txt"
/usr/bin/file "$ARTIFACT_DIR/BridgeHost.app/BridgeHost" > "$ARTIFACT_DIR/file-host.txt"
/usr/bin/file "$ARTIFACT_DIR/BridgeHost.app/PlugIns/BridgeTunnel.appex/BridgeTunnel" > "$ARTIFACT_DIR/file-tunnel.txt"
/usr/bin/file "$ARTIFACT_DIR/BridgeHost.app/PlugIns/BridgeTests.xctest/BridgeTests" > "$ARTIFACT_DIR/file-test.txt"

VERIFY_ARGS=(--ipa "$IPA" --mode "$MODE" --project "$PROJECT_DIR/project.yml")
[ -n "$SOURCE_REF" ] && VERIFY_ARGS+=(--source-ref "$SOURCE_REF")
[ -n "$MARKETING_VERSION" ] && VERIFY_ARGS+=(--expected-version "$MARKETING_VERSION")
[ -n "$BUILD_NUMBER" ] && VERIFY_ARGS+=(--expected-build "$BUILD_NUMBER")
/usr/bin/python3 -B "$SCRIPT_DIR/verify_bridge.py" "${VERIFY_ARGS[@]}" > "$ARTIFACT_DIR/verify.txt"

echo "== result =="
/usr/bin/shasum -a 256 "$IPA"
du -sh "$IPA" "$ARTIFACT_DIR/BridgeHost.app"
echo "artifact: $IPA"
if [ "$MODE" = "qualification" ]; then
    echo "sign with: $SCRIPT_DIR/sign_bridge_ipa.sh --ipa $IPA --host-profile <host-profile> --tunnel-profile <tunnel-profile> --identity <codesign-identity> --mode qualification --output $ARTIFACT_DIR/FloeBridge-signed.ipa"
elif [ "$MODE" = "product-qualification" ]; then
    echo "private product sign: $SCRIPT_DIR/sign_bridge_ipa.sh --ipa $IPA --host-profile <host-profile> --tunnel-profile <tunnel-profile> --identity <codesign-identity> --mode product-qualification --source-ref $SOURCE_REF --output $ARTIFACT_DIR/FloeBridge-product-signed.ipa"
    echo "public artifact must remain unsigned; do not publish the signed private IPA"
else
    echo "public artifact must remain unsigned; do not sign or embed profiles"
fi
