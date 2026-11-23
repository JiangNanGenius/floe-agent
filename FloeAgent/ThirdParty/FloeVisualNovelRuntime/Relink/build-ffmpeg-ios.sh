#!/bin/bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo 'Usage: build-ffmpeg-ios.sh FFMPEG_SOURCE NEW_WORK_DIRECTORY' >&2
    exit 2
fi

source_dir=$(cd "$1" && pwd -P)
work_dir="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
if [[ "$source_dir$work_dir" =~ [[:space:]] || ! -f "$source_dir/configure" ]]; then
    echo 'Use source and work directories without whitespace, and unpack the FFmpeg source first.' >&2
    exit 2
fi

mkdir "$work_dir"
min_ios=17.0
common=(
    --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-network
    --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample --disable-pixelutils
    --disable-debug --enable-static --disable-shared --enable-pic --enable-cross-compile
    --target-os=darwin --arch=aarch64
    --enable-demuxer=asf,mpegps,mpegvideo
    --enable-decoder=wmv1,wmv2,wmv3,vc1,wmav1,wmav2,wmapro,wmalossless,mpeg1video,mpeg2video,mp2,mp3
    --enable-parser=mpegvideo,mpegaudio
)

build() (
    slice=$1
    sdk=$2
    min_flag=$3
    dir="$work_dir/$slice"
    mkdir "$dir"
    cd "$dir"

    sdk_root=$(xcrun --sdk "$sdk" --show-sdk-path)
    compiler=$(xcrun --sdk "$sdk" --find clang)
    "$source_dir/configure" "${common[@]}" --prefix=/usr/local --sysroot="$sdk_root" \
        --cc="$compiler" --extra-cflags="-arch arm64 $min_flag" --extra-ldflags="-arch arm64 $min_flag"
    make -j "${FLOE_BUILD_JOBS:-6}"
    make install DESTDIR="$dir/stage"
    mv "$dir/stage/usr/local" "$dir/install"
    libtool -static -o "$dir/libffmpeg.a" "$dir/install/lib/libavformat.a" \
        "$dir/install/lib/libavcodec.a" "$dir/install/lib/libavutil.a"

    headers="$dir/install/include"
    cat > "$headers/CFFmpeg.h" <<'HEADER'
#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libavutil/channel_layout.h"
#include "libavutil/mem.h"
#include "libavutil/samplefmt.h"
HEADER
    mkdir "$headers/CFFmpeg"
    cat > "$headers/CFFmpeg/module.modulemap" <<'MODULE'
module CFFmpeg {
  header "../CFFmpeg.h"
  link "ffmpeg"
  export *
}
MODULE
)

build device iphoneos "-miphoneos-version-min=$min_ios"
build simulator iphonesimulator "-mios-simulator-version-min=$min_ios"

xcodebuild -create-xcframework \
    -library "$work_dir/device/libffmpeg.a" -headers "$work_dir/device/install/include" \
    -library "$work_dir/simulator/libffmpeg.a" -headers "$work_dir/simulator/install/include" \
    -output "$work_dir/ShioriFFmpeg.xcframework"
