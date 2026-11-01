#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
BUILD="${FOREGROUND_HELPER_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/foreground-helper/host}"
mkdir -p "$BUILD"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -DBRIDGE_ENGINE_TESTING=1 -framework Foundation -framework CoreGraphics \
  -I "$ROOT/FloeIOSBridge/Sources/BridgeTests" \
  "$ROOT/FloeIOSBridge/Sources/BridgeTests/BridgeEnginePrivateShims.m" \
  "$ROOT/FloeIOSBridge/Tests/EngineRPC/ForegroundHelperTests.m" \
  -o "$BUILD/foreground-helper-tests"
"$BUILD/foreground-helper-tests"
