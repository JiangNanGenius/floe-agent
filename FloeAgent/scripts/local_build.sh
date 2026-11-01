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

# Pinned OCCT base slices are untracked vendor binaries; the installed slices
# additionally require the reviewed Standard_Type derivation (one object
# compile + deterministic archive splice). Prepare/verify them before building
# whenever the bootstrap manifest is present. Idempotent no-op when valid
# derived bytes and receipts are already installed; macOS + full Xcode only
# (the CLT-only path below explicitly excludes the iOS/CAD targets).
if [ "$(uname -s)" = "Darwin" ] && [ -f ThirdParty/FloeCADKit/bootstrap.py ]; then
    if xcodebuild -version >/dev/null 2>&1; then
        echo "== prepare/verify FloeCADKit OCCT slices =="
        python3 ThirdParty/FloeCADKit/bootstrap.py
    else
        echo "== FloeCADKit OCCT preparation skipped: full Xcode required; CLT-only build excludes iOS/CAD targets =="
    fi
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
