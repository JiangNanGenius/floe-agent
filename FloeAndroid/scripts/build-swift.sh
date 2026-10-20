#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
sdk="$FLOE_ANDROID_TOOLCHAINS/swift-6.4.1-RELEASE_android.artifactbundle/swift-android"
JOBS="${FLOE_SWIFT_JOBS:-6}"
"$FLOE_SWIFT_BIN/swift" build --build-system native --package-path "$FLOE_ANDROID_ROOT/shared" \
    --scratch-path "$FLOE_ANDROID_CACHE_ROOT/swift-native" \
    --swift-sdks-path "$FLOE_SWIFT_SDKS" --swift-sdk swift-6.4.1-RELEASE_android \
    --triple aarch64-unknown-linux-android28 --jobs "$JOBS" -c release \
    -Xlinker -z -Xlinker max-page-size=16384 \
    -Xlinker -soname -Xlinker libFloeAndroidCore.so
output="$FLOE_ANDROID_ROOT/core/swiftbridge/src/main/jniLibs/arm64-v8a"
mkdir -p "$output"
cp "$FLOE_ANDROID_CACHE_ROOT/swift-native/aarch64-unknown-linux-android28/release/libFloeAndroidCore.so" "$output/"
# Bundle the SDK runtime required by the linked shared library; no host libraries.
find "$sdk/swift-resources/usr/lib/swift-aarch64/android" -maxdepth 1 -name '*.so' -exec cp '{}' "$output/" \;
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$output/"
# Export the VERIFIED security corpus as a swiftbridge APK asset. The Android
# Swift toolchain defines SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE, so the
# SwiftPM Bundle.module of FloeSecurity cannot be assumed inside the APK. The
# corpus travels as an exact byte copy, hash-pinned here, and is loaded at
# runtime through QualificationSeam.swift (same Codable + same regex path;
# any mismatch fails closed — never empty patterns).
corpus_src="$FLOE_ANDROID_ROOT/shared/Sources/FloeSecurity/Resources/catastrophic-patterns.json"
corpus_asset_dir="$FLOE_ANDROID_ROOT/core/swiftbridge/src/main/assets/security"
corpus_asset="$corpus_asset_dir/catastrophic-patterns.json"
corpus_expected="b20667f2d9713961231327c931188cc74474cdbd294593c6071c804edf0c038b"
[ -f "$corpus_src" ] || { echo "build-swift: security corpus source missing: $corpus_src" >&2; exit 1; }
corpus_actual="$(shasum -a 256 "$corpus_src" | cut -d' ' -f1)"
[ "$corpus_actual" = "$corpus_expected" ] || {
    echo "build-swift: security corpus hash mismatch (got $corpus_actual)" >&2; exit 1; }
mkdir -p "$corpus_asset_dir"
cp "$corpus_src" "$corpus_asset"
corpus_asset_actual="$(shasum -a 256 "$corpus_asset" | cut -d' ' -f1)"
[ "$corpus_asset_actual" = "$corpus_expected" ] || {
    echo "build-swift: exported corpus hash mismatch (got $corpus_asset_actual)" >&2; exit 1; }
python3 "$FLOE_ANDROID_ROOT/scripts/native-manifest.py" "$output"
