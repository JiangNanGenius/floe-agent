#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Build the standalone macOS arm64 static host library.
# usage: build_macos_archive.sh <out_dir>
# Produces <out_dir>/libFloeLinuxVideoHost.a plus per-object files and
# vtool evidence. No Simulator/device use, no network.
set -euo pipefail
OUT_DIR="$1"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
unset SDKROOT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/FloeLinuxVideoHost"
INC="$ROOT/Sources/FloeLinuxVideoNative/include"
CLANG="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
SYSROOT=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$OUT_DIR"

LIB_SRCS=("$SRC/FLVPixelFormats.m" "$SRC/FLVBitstream.m" "$SRC/FLVCodecRegistry.m" "$SRC/FLVFormatDescription.m" \
  "$SRC/FLVSessionContext.m" "$SRC/FLVHostContext.m" "$SRC/FLVHostPublic.m" "$SRC/FLVImageIOFallback.m")
if [ -f "$SRC/FLVProbeSamples.m" ]; then
  LIB_SRCS+=("$SRC/FLVProbeSamples.m")
else
  LIB_SRCS+=("$ROOT/tests/FLVProbeSamples_empty.m")
fi

objs=()
for f in "${LIB_SRCS[@]}"; do
  o="$OUT_DIR/$(basename "${f%.m}").o"
  env -u SDKROOT "$CLANG" -arch arm64 -target arm64-apple-macos15.0 -isysroot "$SYSROOT" \
    -O2 -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
    -I"$INC" -I"$SRC" -c "$f" -o "$o"
  objs+=("$o")
done
rm -f "$OUT_DIR/libFloeLinuxVideoHost.a"
libtool -static -o "$OUT_DIR/libFloeLinuxVideoHost.a" "${objs[@]}"
vtool -show-build "$OUT_DIR/FLVSessionContext.o" > "$OUT_DIR/FLVSessionContext.vtool.txt"
{
  echo "toolchain: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "sdk: $SYSROOT"
  echo "target: arm64-apple-macos15.0"
  echo "objects:"
  printf '  %s\n' "${objs[@]}"
} > "$OUT_DIR/BUILD_INFO.txt"
echo "archive built: $OUT_DIR/libFloeLinuxVideoHost.a"
