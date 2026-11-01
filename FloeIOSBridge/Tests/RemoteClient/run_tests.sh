#!/bin/bash
# Focused verification for the self-contained remote page, host resource adapter
# and reference client. Source-only: no App build, simulator, device, signing or
# publication.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/FloeIOSBridge/Tests/RemoteClient"
EVIDENCE="${REMOTE_EVIDENCE_DIR:-$ROOT/Local/Private/ios-bridge-1.0-20261101/remote/evidence}"
LOG="$EVIDENCE/run-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$EVIDENCE"
exec > >(tee "$LOG") 2>&1
echo "== Floe Bridge remote verification =="
echo "root: $ROOT"
echo "log:  $LOG"
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

echo "== 1. generated page is current =="
python3 "$HERE/build_remote_page.py" --check
echo

echo "== 2. Python and JavaScript syntax =="
python3 - <<'PY'
import pathlib
paths = [
    pathlib.Path("FloeIOSBridge/Tests/RemoteClient/build_remote_page.py"),
    pathlib.Path("FloeIOSBridge/Tests/RemoteClient/mock_bridge.py"),
    pathlib.Path("FloeIOSBridge/Tests/RemoteClient/test_browser.py"),
    pathlib.Path("FloeIOSBridge/Tests/RemoteClient/test_reference_client.py"),
    pathlib.Path("FloeIOSBridge/scripts/RemoteClient/floe_bridge_client.py"),
]
for path in paths:
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
print("python syntax ok: %d file(s)" % len(paths))
PY
for file in "$HERE"/*.mjs; do
  node --check "$file"
  echo "node syntax ok: $(basename "$file")"
done
find "$ROOT/FloeIOSBridge" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo

echo "== 3. shipped core crypto/geometry checks (WebCrypto and fallback) =="
node "$HERE/test_core.mjs"
echo

echo "== 4. reference client contract tests =="
python3 "$HERE/test_reference_client.py"
echo

echo "== 5. real headless-browser checks (secure and plain-HTTP fallback) =="
python3 "$HERE/test_browser.py" --evidence-dir "$EVIDENCE"
echo

echo "== 6. host resource adapter runtime check =="
bash "$HERE/run_resource_check.sh"
echo

echo "== 7. real Swift 6 arm64 iOS 26 object compilation =="
bash "$HERE/verify_ios_objects.sh"
echo

find "$ROOT/FloeIOSBridge" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "== ALL REMOTE CHECKS PASSED =="
