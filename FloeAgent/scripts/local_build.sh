#!/bin/bash
# local_build.sh — Build + test the cross-platform SPM subset on a machine
# without full Xcode (Command Line Tools only). iOS-only targets and the
# app target are excluded from test; they are CI-gated on macos-15 runners.
#
# Environment notes (observed on this host):
#   - SwiftPM's internal sandbox-exec fails under some agent/CI shells;
#     set SWIFTPM_NO_SANDBOX=1 to pass --disable-sandbox.
#   - Swift Testing macro plugins ship only with full Xcode; with CLT-only,
#     `swift test` cannot load TestingMacros. Set DEVELOPER_DIR to a full
#     Xcode to run tests locally.
set -euo pipefail

cd "$(dirname "$0")/.."

# Prefer an already selected full Xcode. If the machine's global
# xcode-select points at CommandLineTools, use a local Xcode installation
# for this script only; never mutate the user's global selection.
if ! xcodebuild -version >/dev/null 2>&1; then
    for xcode_app in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -x "$xcode_app/Contents/Developer/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="$xcode_app/Contents/Developer"
            break
        fi
    done
fi

SANDBOX_FLAG=""
if [ "${SWIFTPM_NO_SANDBOX:-0}" = "1" ]; then
    SANDBOX_FLAG="--disable-sandbox"
fi

# Pinned OCCT slices are untracked vendor binaries: fetch + SHA-256 verify them
# before building whenever the bootstrap manifest is present. Idempotent no-op
# when the exact bytes are already installed; macOS-only (the app/CAD stack).
if [ "$(uname -s)" = "Darwin" ] && [ -f ThirdParty/FloeCADKit/bootstrap.py ]; then
    echo "== bootstrap pinned OCCT slices =="
    python3 ThirdParty/FloeCADKit/bootstrap.py
fi

echo "== swift build (all SPM targets) =="
swift build $SANDBOX_FLAG

if xcodebuild -version >/dev/null 2>&1; then
    echo "== swift test =="
    swift test $SANDBOX_FLAG
else
    echo "== swift test skipped: full Xcode required for Swift Testing macros =="
fi

echo "local_build OK"
