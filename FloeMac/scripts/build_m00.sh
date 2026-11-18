#!/bin/bash
# Floe Mac M00 — build the one M00 app package from three explicit targets.
#
# This script compiles locally only. It does not install, sign for
# distribution, notarize, upload or touch the standalone Floe Bridge.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

XCODE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEVELOPER_DIR/../Info.plist")"
if [[ "$XCODE_VERSION" != "27.2" ]]; then
  echo "Expected Xcode 27.2, found $XCODE_VERSION. Set DEVELOPER_DIR explicitly." >&2
  exit 2
fi
TOOLCHAIN_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEVELOPER_DIR/../Info.plist")"
CHECKOUT_ID="$(printf '%s' "$REPO" | shasum -a 256 | cut -c1-12)"
CACHE_ROOT="${FLOE_MAC_M00_CACHE:-$HOME/Library/Caches/CodexBuild/floe-mac-m00/$CHECKOUT_ID/$TOOLCHAIN_ID}"
DERIVED="$CACHE_ROOT/DerivedData"
PACKAGE_ROOT="$CACHE_ROOT/package"
LOG_DIR="$CACHE_ROOT/logs"
JOBS="${FLOE_MAC_M00_JOBS:-2}"
# These are hard gates from the repository resource policy, not tuning knobs:
# no build below 30 GiB free on the internal SSD and no second compile when
# another Swift/Xcode build is active. There is deliberately no environment
# override for either gate.
MIN_FREE_BYTES=$((30 * 1024 * 1024 * 1024))

mkdir -p "$DERIVED" "$PACKAGE_ROOT" "$LOG_DIR"

available_kib="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
available_bytes=$((available_kib * 1024))
free_gib="$(awk -v b="$available_bytes" 'BEGIN { printf "%.2f", b / (1024*1024*1024) }')"
if (( available_bytes < MIN_FREE_BYTES )); then
  echo "Internal SSD has ${free_gib} GiB (${available_bytes} bytes) free; M00 requires at least 30 GiB (${MIN_FREE_BYTES} bytes). No build was started." >&2
  exit 2
fi
ACTIVE_COMPILER="$(pgrep -x xcodebuild || true; pgrep -x swift-build || true; pgrep -x swift-frontend || true)"
if [[ -n "$ACTIVE_COMPILER" ]]; then
  echo "Another Swift/Xcode compile is active. No M00 build was started; re-run when it is idle." >&2
  echo "$ACTIVE_COMPILER" | sed 's/^/active pid: /' >&2
  exit 2
fi
BUILD_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Xcode $XCODE_VERSION ($TOOLCHAIN_ID); scratch=$CACHE_ROOT; free=${free_gib}GiB (${available_bytes} bytes); jobs=$JOBS; compiler_state=idle"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to regenerate the project." >&2
  exit 2
fi
xcodegen generate --spec "$ROOT/project.yml" > "$LOG_DIR/xcodegen.log" 2>&1

build_target() {
  local scheme="$1"
  local destination="$2"
  local log="$3"
  echo "Building $scheme -> $destination"
  xcodebuild \
    -project "$ROOT/FloeMac.xcodeproj" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$DERIVED" \
    -jobs "$JOBS" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build > "$log" 2>&1
  echo "Built $scheme"
}

build_target FloeMacHost 'platform=macOS,arch=arm64' "$LOG_DIR/host-build.log"
build_target FloeMacBridgeService 'platform=macOS,arch=arm64' "$LOG_DIR/bridge-build.log"
build_target FloeMacAgentUI 'platform=macOS,variant=Mac Catalyst' "$LOG_DIR/catalyst-build.log"

HOST_APP="$DERIVED/Build/Products/Debug/Floe.app"
BRIDGE_APP="$DERIVED/Build/Products/Debug/FloeMacBridgeService.app"
CATALYST_APP="$DERIVED/Build/Products/Debug-maccatalyst/FloeAgentUI.app"
for product in "$HOST_APP" "$BRIDGE_APP" "$CATALYST_APP"; do
  if [[ ! -d "$product" ]]; then
    echo "Missing build product: $product" >&2
    exit 2
  fi
done

APP="$PACKAGE_ROOT/Floe.app"
rm -rf "$APP"
ditto "$HOST_APP" "$APP"
mkdir -p "$APP/Contents/Helpers"
ditto "$BRIDGE_APP" "$APP/Contents/Helpers/FloeMacBridgeService.app"
ditto "$CATALYST_APP" "$APP/Contents/Helpers/FloeMacAgentUI.app"

# One visible product. These are internal components, not separately
# installed apps.
if find "$APP/Contents" -maxdepth 1 -name '*.app' | grep -q .; then
  echo "Unexpected top-level nested app; only Contents/Helpers is allowed." >&2
  exit 2
fi
[[ -x "$APP/Contents/MacOS/Floe" ]]
[[ -x "$APP/Contents/Helpers/FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService" ]]
[[ -x "$APP/Contents/Helpers/FloeMacAgentUI.app/Contents/MacOS/FloeAgentUI" ]]

# Ad-hoc signing is local development only; this is not distribution
# signing, notarization or an install. It keeps local nested-app launches
# deterministic. Any signing or verification failure ends the build; there is
# no environment switch that can silently ship an unsigned/invalid package.
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/FloeMacBridgeService.app" \
  > "$LOG_DIR/sign-bridge.log" 2>&1 || { echo "Ad-hoc signing the Bridge component failed." >&2; exit 2; }
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/FloeMacAgentUI.app" \
  > "$LOG_DIR/sign-catalyst.log" 2>&1 || { echo "Ad-hoc signing the Catalyst component failed." >&2; exit 2; }
codesign --force --sign - --timestamp=none "$APP" > "$LOG_DIR/sign-host.log" 2>&1 \
  || { echo "Ad-hoc signing the host failed." >&2; exit 2; }
codesign --verify --deep --strict "$APP" > "$LOG_DIR/codesign-verify.log" 2>&1 \
  || { echo "codesign verification failed; the package is not usable." >&2; exit 2; }

python3 - "$APP" "$REPO" "$DEVELOPER_DIR" "$CACHE_ROOT" "$available_bytes" "$BUILD_STARTED_AT" <<'PY'
import hashlib, json, os, subprocess, sys
app, repo, developer, cache, available_bytes, build_started_at = sys.argv[1:]
def sha(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for chunk in iter(lambda: f.read(1<<20), b''):
            h.update(chunk)
    return h.hexdigest()
info={
 'schema':'floe-mac-m00-build-v1',
 'source_commit': subprocess.check_output(['git','-C',repo,'rev-parse','HEAD'], text=True).strip(),
 'source_dirty': bool(subprocess.check_output(['git','-C',repo,'status','--porcelain'], text=True).strip()),
 'xcode': subprocess.check_output(['/usr/libexec/PlistBuddy','-c','Print CFBundleShortVersionString',os.path.join(os.path.dirname(os.path.normpath(developer)),'Info.plist')], text=True).strip(),
 'toolchain_build': subprocess.check_output(['/usr/libexec/PlistBuddy','-c','Print CFBundleVersion',os.path.join(os.path.dirname(os.path.normpath(developer)),'Info.plist')], text=True).strip(),
 'free_bytes_at_start': int(available_bytes),
 'free_gib_at_start': round(int(available_bytes) / (1024**3), 2),
 'parallel_compiler_at_start': 'idle',
 'build_started_at': build_started_at,
 'app': app,
 'host_sha256': sha(os.path.join(app,'Contents','MacOS','Floe')),
 'bridge_sha256': sha(os.path.join(app,'Contents','Helpers','FloeMacBridgeService.app','Contents','MacOS','FloeMacBridgeService')),
 'catalyst_sha256': sha(os.path.join(app,'Contents','Helpers','FloeMacAgentUI.app','Contents','MacOS','FloeAgentUI')),
}
open(os.path.join(cache,'build-manifest.json'),'w').write(json.dumps(info,indent=2,sort_keys=True)+'\n')
print(json.dumps(info,indent=2,sort_keys=True))
PY

echo "M00 package prepared (ad-hoc/local only): $APP"
du -sh "$APP" "$CACHE_ROOT"
