#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Component compile check: build library objects against the real iOS device
# and Simulator SDKs (no link, no device use, no Simulator boot).
# usage: build_ios_objects.sh <out_dir>
# Emits vtool -show-build evidence for one object per platform.
set -euo pipefail
OUT_DIR="$1"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
unset SDKROOT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/FloeLinuxVideoHost"
INC="$ROOT/Sources/FloeLinuxVideoNative/include"
mkdir -p "$OUT_DIR/iphoneos" "$OUT_DIR/iphonesimulator"

SRCS="FLVPixelFormats.m FLVBitstream.m FLVCodecRegistry.m FLVFormatDescription.m FLVSessionContext.m FLVHostContext.m FLVHostPublic.m FLVImageIOFallback.m"
if [ -f "$SRC/FLVProbeSamples.m" ]; then SRCS="$SRCS $SRC/FLVProbeSamples.m"; else SRCS="$SRCS $ROOT/tests/FLVProbeSamples_empty.m"; fi

build_set () {
  local sdk="$1"; local triple="$2"; local destdir="$3"
  local sysroot clang
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  clang=$(xcrun --sdk "$sdk" -f clang)
  echo "[$sdk] sysroot=$sysroot triple=$triple"
  for f in $SRCS; do
    case "$f" in
      /*) src="$f" ;;
      *) src="$SRC/$f" ;;
    esac
    "$clang" -target "$triple" -isysroot "$sysroot" -O2 -fobjc-arc -fblocks \
      -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability-new \
      -I"$INC" -I"$SRC" \
      -c "$src" -o "$destdir/$(basename "${f%.m}").o"
  done
  vtool -show-build "$destdir/FLVSessionContext.o" > "$destdir/FLVSessionContext.vtool.txt"
  otool -l "$destdir/FLVSessionContext.o" | grep -A3 LC_BUILD_VERSION > "$destdir/FLVSessionContext.build_version.txt" || true
}

build_set iphoneos arm64-apple-ios26.0 "$OUT_DIR/iphoneos"
build_set iphonesimulator arm64-apple-ios26.0-simulator "$OUT_DIR/iphonesimulator"
echo "ios object compile OK: $OUT_DIR/iphoneos $OUT_DIR/iphonesimulator"
cat "$OUT_DIR/iphoneos/FLVSessionContext.vtool.txt"
cat "$OUT_DIR/iphonesimulator/FLVSessionContext.vtool.txt"
