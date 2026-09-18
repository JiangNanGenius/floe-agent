#!/bin/bash
# Compile and run the desktop shell-bridge host harness.
#
# The harness compiles the real FloeShellBridge.mm against a scripted stub of
# the pinned ios_system engine (fixtures/ios_system/ios_system.h). It checks
# the run gate, readiness drain and descriptor-ownership state machine on the
# host. It is not an iOS or engine qualification; device behavior stays with
# the user's manual pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD="${HARNESS_SCRATCH:-${TMPDIR:-/tmp}/floe-feedback-shell-bridge}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

echo "== building shell bridge host"
xcrun clang++ \
  -fobjc-arc -fblocks -std=c++17 -x objective-c++ \
  -I "$SCRIPT_DIR/fixtures" \
  -I "$ROOT/FloeAgent/FloeApp/Execution" \
  -Wno-deprecated-declarations \
  -framework Foundation \
  -o "$BUILD/feedback_shell_bridge_host" \
  "$SCRIPT_DIR/feedback_shell_bridge_host.mm"

echo "== running shell bridge host"
"$BUILD/feedback_shell_bridge_host"
