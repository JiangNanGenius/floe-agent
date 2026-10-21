#!/usr/bin/env bash
# Build the floe-probe static executable with the pinned NDK toolchain.
# The probe is shipped as a jniLibs payload named libfloeprobe.so so the APK
# installs it into the app native library directory (the only file location a
# targetSdk>=29 app may execute from besides the runtime itself).
#
# Usage: bash FloeAndroid/core/linuxruntime/native-build/build-probe.sh
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd -P)"

# shellcheck source=FloeAndroid/scripts/env.sh
source "$REPO_ROOT/FloeAndroid/scripts/env.sh"

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
CC="$TOOLCHAIN/bin/aarch64-linux-android28-clang"
OUT_DIR="$MODULE_DIR/src/main/jniLibs/arm64-v8a"
mkdir -p "$OUT_DIR"

CFLAGS=(
  -static
  -O2
  -Wall
  -Wextra
  -ffunction-sections -fdata-sections
  -Wl,--gc-sections
  -Wl,-z,max-page-size=16384
  -Wl,-z,common-page-size=16384
  -Wl,-z,noexecstack
  -Wl,--build-id=sha1
)

"$CC" "${CFLAGS[@]}" \
  -o "$OUT_DIR/libfloeprobe.so" \
  "$MODULE_DIR/src/main/cpp/floe_probe.c"

shasum -a 256 "$OUT_DIR/libfloeprobe.so"
echo "built $OUT_DIR/libfloeprobe.so"
