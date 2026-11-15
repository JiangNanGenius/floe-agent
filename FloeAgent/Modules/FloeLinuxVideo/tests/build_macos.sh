#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Build one component test against the macOS SDK.
# usage: build_macos.sh <test_name e.g. flv_test_capabilities> <out_binary> [extra test sources]
# Repaired 2026-11-11: source lists are expanded via arrays so paths with
# spaces are not word-split (checkout dir contains one).
set -euo pipefail
TEST_NAME="$1"; OUT="$2"; shift 2 || true
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/FloeLinuxVideoHost"
INC="$ROOT/Sources/FloeLinuxVideoNative/include"
CLANG="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
# Explicit SDK sysroot: without it the toolchain cannot resolve Foundation
# headers in this environment (observed 2026-11-11, attempt-03/04 evidence).
SYSROOT=$(xcrun --sdk macosx --show-sdk-path)

LIB_SRCS=("$SRC/FLVPixelFormats.m" "$SRC/FLVBitstream.m" "$SRC/FLVCodecRegistry.m" \
  "$SRC/FLVFormatDescription.m" "$SRC/FLVSessionContext.m" "$SRC/FLVHostContext.m" \
  "$SRC/FLVHostPublic.m" "$SRC/FLVImageIOFallback.m")
if [ -f "$SRC/FLVProbeSamples.m" ]; then
  LIB_SRCS+=("$SRC/FLVProbeSamples.m")
else
  LIB_SRCS+=("$ROOT/tests/FLVProbeSamples_empty.m")
fi
FRAMEWORKS=(-framework Foundation -framework CoreFoundation -framework CoreMedia \
  -framework CoreVideo -framework VideoToolbox -framework ImageIO -framework CoreGraphics)

env -u SDKROOT "$CLANG" -arch arm64 -target arm64-apple-macos15.0 -isysroot "$SYSROOT" -O2 -fobjc-arc -fblocks \
  -Wall -Wextra -Wno-unused-parameter \
  -I"$INC" -I"$SRC" \
  "${LIB_SRCS[@]}" "$ROOT/tests/$TEST_NAME.m" "$ROOT/tests/flv_test_util.m" "$@" \
  "${FRAMEWORKS[@]}" \
  -o "$OUT"
