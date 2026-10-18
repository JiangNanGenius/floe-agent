#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
sdk="$FLOE_ANDROID_TOOLCHAINS/swift-6.4.1-RELEASE_android.artifactbundle/swift-android"
"$FLOE_SWIFT_BIN/swift" build --build-system native --package-path "$FLOE_ANDROID_ROOT/shared" \
    --scratch-path "$FLOE_ANDROID_CACHE_ROOT/swift-native" \
    --swift-sdks-path "$FLOE_SWIFT_SDKS" --swift-sdk swift-6.4.1-RELEASE_android \
    --triple aarch64-unknown-linux-android28 --jobs 6 -c release \
    -Xlinker -z -Xlinker max-page-size=16384 \
    -Xlinker -soname -Xlinker libFloeAndroidCore.so
output="$FLOE_ANDROID_ROOT/core/swiftbridge/src/main/jniLibs/arm64-v8a"
mkdir -p "$output"
cp "$FLOE_ANDROID_CACHE_ROOT/swift-native/aarch64-unknown-linux-android28/release/libFloeAndroidCore.so" "$output/"
# Bundle the SDK runtime required by the linked shared library; no host libraries.
find "$sdk/swift-resources/usr/lib/swift-aarch64/android" -maxdepth 1 -name '*.so' -exec cp '{}' "$output/" \;
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$output/"
python3 "$FLOE_ANDROID_ROOT/scripts/native-manifest.py" "$output"
