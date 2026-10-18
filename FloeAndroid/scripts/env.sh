#!/usr/bin/env bash
# Source from task-local build commands; never changes xcode-select or shell profiles.
set -euo pipefail
FLOE_ANDROID_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FLOE_REPOSITORY_ROOT="$(cd "$FLOE_ANDROID_ROOT/.." && pwd -P)"
export FLOE_ANDROID_TOOLCHAINS="${FLOE_ANDROID_TOOLCHAINS:-$FLOE_REPOSITORY_ROOT/Local/Private/android-toolchains}"
export ANDROID_HOME="${ANDROID_HOME:-$FLOE_ANDROID_TOOLCHAINS/android-sdk}"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/30.0.16248370"
export JAVA_HOME="${JAVA_HOME:-$(find "$FLOE_ANDROID_TOOLCHAINS/jdk" -maxdepth 4 -type d -path '*/Contents/Home' -print -quit)}"
export ANDROID_USER_HOME="$FLOE_ANDROID_TOOLCHAINS/android-user"
export ANDROID_AVD_HOME="$FLOE_ANDROID_TOOLCHAINS/avd"
FLOE_CHECKOUT_ID="$(printf '%s' "$FLOE_REPOSITORY_ROOT" | shasum -a 256 | cut -c1-12)"
# User's latest choice: internal cache for speed; SDK/AVD stay on external storage.
export FLOE_ANDROID_CACHE_ROOT="${FLOE_ANDROID_CACHE_ROOT:-$HOME/Library/Caches/CodexBuild/FloeAndroid/$FLOE_CHECKOUT_ID/jdk21}"
export FLOE_ANDROID_BUILD_ROOT="$FLOE_ANDROID_CACHE_ROOT/outputs"
export GRADLE_USER_HOME="$FLOE_ANDROID_CACHE_ROOT/gradle"
export FLOE_SWIFT_SDKS="$FLOE_ANDROID_TOOLCHAINS/swift-sdks"
export FLOE_SWIFT_BIN="$FLOE_ANDROID_TOOLCHAINS/swift-6.4.1.xctoolchain/usr/bin"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Keep Apple's host linker ahead of NDK's `ld`; Android's explicit ld.lld remains discoverable.
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/22.0/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH:$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
mkdir -p "$FLOE_ANDROID_CACHE_ROOT" "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME"
