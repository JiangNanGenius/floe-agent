#!/usr/bin/env bash
# Reproducible verification for the vendored liblzma 5.8.1 pinned build.
#
# Compiles exactly the 74-object liblzma unit set (XZ_THREADS=no, static)
# for the Apple host (arm64) and Android NDK arm64-v8a / android-28 using
# ONLY -DHAVE_CONFIG_H plus the pinned floe/config.h macro sets — proving
# that the SwiftPM CLzma target recipe (defines + header search paths) is
# self-sufficient. It does not link: final linking happens in Main's grouped
# Swift 6 Android build (16KiB page alignment is a .so-link property, see
# RECIPE.md).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT="${1:-/tmp/floe-liblzma-verify}"
mkdir -p "$OUT/macos" "$OUT/android"

SRCS=(
  src/common/tuklib_physmem.c src/liblzma/check/check.c src/liblzma/check/crc32_fast.c
  src/liblzma/check/crc64_fast.c src/liblzma/check/sha256.c src/liblzma/common/alone_decoder.c
  src/liblzma/common/alone_encoder.c src/liblzma/common/auto_decoder.c
  src/liblzma/common/block_buffer_decoder.c src/liblzma/common/block_buffer_encoder.c
  src/liblzma/common/block_decoder.c src/liblzma/common/block_encoder.c
  src/liblzma/common/block_header_decoder.c src/liblzma/common/block_header_encoder.c
  src/liblzma/common/block_util.c src/liblzma/common/common.c
  src/liblzma/common/easy_buffer_encoder.c src/liblzma/common/easy_decoder_memusage.c
  src/liblzma/common/easy_encoder.c src/liblzma/common/easy_encoder_memusage.c
  src/liblzma/common/easy_preset.c src/liblzma/common/file_info.c
  src/liblzma/common/filter_buffer_decoder.c src/liblzma/common/filter_buffer_encoder.c
  src/liblzma/common/filter_common.c src/liblzma/common/filter_decoder.c
  src/liblzma/common/filter_encoder.c src/liblzma/common/filter_flags_decoder.c
  src/liblzma/common/filter_flags_encoder.c src/liblzma/common/hardware_physmem.c
  src/liblzma/common/index.c src/liblzma/common/index_decoder.c src/liblzma/common/index_encoder.c
  src/liblzma/common/index_hash.c src/liblzma/common/lzip_decoder.c
  src/liblzma/common/microlzma_decoder.c src/liblzma/common/microlzma_encoder.c
  src/liblzma/common/stream_buffer_decoder.c src/liblzma/common/stream_buffer_encoder.c
  src/liblzma/common/stream_decoder.c src/liblzma/common/stream_encoder.c
  src/liblzma/common/stream_flags_common.c src/liblzma/common/stream_flags_decoder.c
  src/liblzma/common/stream_flags_encoder.c src/liblzma/common/string_conversion.c
  src/liblzma/common/vli_decoder.c src/liblzma/common/vli_encoder.c src/liblzma/common/vli_size.c
  src/liblzma/delta/delta_common.c src/liblzma/delta/delta_decoder.c src/liblzma/delta/delta_encoder.c
  src/liblzma/lz/lz_decoder.c src/liblzma/lz/lz_encoder.c src/liblzma/lz/lz_encoder_mf.c
  src/liblzma/lzma/fastpos_table.c src/liblzma/lzma/lzma2_decoder.c src/liblzma/lzma/lzma2_encoder.c
  src/liblzma/lzma/lzma_decoder.c src/liblzma/lzma/lzma_encoder.c
  src/liblzma/lzma/lzma_encoder_optimum_fast.c src/liblzma/lzma/lzma_encoder_optimum_normal.c
  src/liblzma/lzma/lzma_encoder_presets.c src/liblzma/rangecoder/price_table.c
  src/liblzma/simple/arm.c src/liblzma/simple/arm64.c src/liblzma/simple/armthumb.c
  src/liblzma/simple/ia64.c src/liblzma/simple/powerpc.c src/liblzma/simple/riscv.c
  src/liblzma/simple/simple_coder.c src/liblzma/simple/simple_decoder.c
  src/liblzma/simple/simple_encoder.c src/liblzma/simple/sparc.c src/liblzma/simple/x86.c
)
INC=(
  -I"$HERE/src/liblzma/api" -I"$HERE/src/liblzma/common" -I"$HERE/src/liblzma/check"
  -I"$HERE/src/liblzma/lz" -I"$HERE/src/liblzma/rangecoder" -I"$HERE/src/liblzma/lzma"
  -I"$HERE/src/liblzma/delta" -I"$HERE/src/liblzma/simple" -I"$HERE/src/common"
  -I"$HERE/floe"
)
FLAGS=(-DHAVE_CONFIG_H -std=gnu17)

echo "== macOS host arm64 =="
for f in "${SRCS[@]}"; do
  clang --target=arm64-apple-macos13 -c "$HERE/$f" "${FLAGS[@]}" "${INC[@]}" \
    -o "$OUT/macos/$(basename "$f").o" -Wall 2> "$OUT/macos/$(basename "$f").log" || {
      echo "FAILED: $f"; cat "$OUT/macos/$(basename "$f").log"; exit 1; }
done
echo "74/74 ok"

echo "== Android NDK arm64-v8a android-28 =="
: "${ANDROID_NDK_HOME:?source FloeAndroid scripts/env.sh first (NDK 30.0.16248370)}"
CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android28-clang"
for f in "${SRCS[@]}"; do
  "$CC" -c "$HERE/$f" "${FLAGS[@]}" "${INC[@]}" \
    -o "$OUT/android/$(basename "$f").o" -Wall 2> "$OUT/android/$(basename "$f").log" || {
      echo "FAILED: $f"; cat "$OUT/android/$(basename "$f").log"; exit 1; }
done
echo "74/74 ok"
echo "verified both platforms; objects in $OUT"
