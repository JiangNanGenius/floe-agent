#!/bin/bash
# Exercise actual dynamic alloc/init and event helper paths using local fake
# SDK classes. No XCTest framework/session, Simulator or device is involved.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
BUILD="${APPSTATE_OWNERSHIP_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/appstate-ownership/final}"
mkdir -p "$BUILD"
xcrun clang -fobjc-arc -fblocks -fsanitize=address -fno-omit-frame-pointer -g -O1 \
  -Wall -Wextra -Werror -Wno-unused-parameter -framework Foundation -framework CoreGraphics \
  -I "$ROOT/FloeIOSBridge/Sources/BridgeTests" \
  "$ROOT/FloeIOSBridge/Sources/BridgeTests/BridgeEnginePrivateShims.m" \
  "$ROOT/FloeIOSBridge/Tests/EngineRPC/AppStateOwnershipTests.m" \
  -o "$BUILD/appstate-ownership-tests"
ASAN_OPTIONS=detect_leaks=0 NSZombieEnabled=YES "$BUILD/appstate-ownership-tests"
ASAN_OPTIONS=detect_leaks=0 NSZombieEnabled=NO "$BUILD/appstate-ownership-tests"
