#!/bin/zsh
# Build the FloeMachiningNative Rust staticlib for the three Apple arm64
# slices and package Vendor/FloeMachiningNative.xcframework under one C module
# name. Preserve the Rust archive symbol identities; use the shared internal cache.
#
#   Scripts/build_native.sh            # build all slices + xcframework
#   Scripts/build_native.sh <target>   # one rust target only
#
# Env: DEVELOPER_DIR, CARGO_HOME, CARGO_BUILD_JOBS (default 6), CARGO_TARGET_DIR,
# FLOE_NATIVE_XCF_OUTPUT (optional private candidate path, defaults to Vendor).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST="$ROOT/NativeRust"
VENDOR="$ROOT/Vendor"
XCF="${FLOE_NATIVE_XCF_OUTPUT:-$VENDOR/FloeMachiningNative.xcframework}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-6}"
task_checkout_id="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c 1-12)"
task_toolchain_id="$(xcodebuild -version | awk '/Build version/ {print $3}')"
task_cache_root="$HOME/Library/Caches/CodexBuild/FloeManufacturingKit/$task_checkout_id/xcode-$task_toolchain_id"
export CARGO_HOME="${CARGO_HOME:-$task_cache_root/cargo-home}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$task_cache_root/native-rust}"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export MACOSX_DEPLOYMENT_TARGET=13.0
export CARGO_NET_OFFLINE=true

# Add the iOS Simulator arm64 standard target if missing (allowed by contract).
if ! rustup target list --installed | grep -q '^aarch64-apple-ios-sim$'; then
  echo "[build] adding rust standard target aarch64-apple-ios-sim"
  rustup target add aarch64-apple-ios-sim
fi

build_slice() { # <rust-target>
  local target="$1"
  echo "[build] cargo build --release --locked --target $target"
  (cd "$RUST" && cargo build --release --locked --target "$target")
  local lib="$CARGO_TARGET_DIR/$target/release/libFloeMachiningNative.a"
  [ -f "$lib" ] || { echo "[build] missing $lib" >&2; exit 1; }
  # Apple strip -x removes Rust's private .llvm symbol disambiguators on this
  # toolchain, creating duplicate symbols in otherwise valid static archives.
  # Preserve cargo's archive unchanged. The final executable's normal linker
  # policy can discard unused code without rewriting this reusable library.
}

case "${1:-all}" in
  aarch64-apple-ios|aarch64-apple-ios-sim|aarch64-apple-darwin)
    build_slice "$1"
    exit 0
    ;;
  all|package) ;;
  *) echo "usage: $0 [all|aarch64-apple-ios|aarch64-apple-ios-sim|aarch64-apple-darwin]" >&2; exit 2;;
esac

# Serialize cross-target builds on the shared host.
if [ "$#" -eq 0 ] || [ "$1" != "package" ]; then
  for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
    build_slice "$target"
  done
fi

# ---- package XCFramework ----------------------------------------------------
TMP="$CARGO_TARGET_DIR/xcframework-staging"
task_new_xcf="$CARGO_TARGET_DIR/FloeMachiningNative.new.xcframework"
task_old_xcf="${XCF}.previous"
mkdir -p "$(dirname "$XCF")"
rm -rf "$TMP" "$task_new_xcf"
mkdir -p "$TMP"
declare -a SLICES=()
for spec in \
  "aarch64-apple-ios ios-arm64" \
  "aarch64-apple-ios-sim ios-arm64-simulator" \
  "aarch64-apple-darwin macos-arm64"; do
  target="${spec%% *}"
  name="${spec##* }"
  dir="$TMP/$name/FloeMachiningNative.framework"
  mkdir -p "$dir/Headers" "$dir/Modules"
  cp "$RUST/include/FloeMachiningNative.h" "$dir/Headers/"
  printf 'framework module FloeMachiningNative {\n  umbrella header "FloeMachiningNative.h"\n  export *\n}\n' > "$dir/Modules/module.modulemap"
  cp "$CARGO_TARGET_DIR/$target/release/libFloeMachiningNative.a" \
     "$dir/FloeMachiningNative"
  python3 - "$dir/Info.plist" "$name" <<'PY'
import plistlib, sys
# Xcode retains this metadata when it embeds a static framework with a stub
# executable. Match the package's supported deployment versions so that the
# resulting App bundle is valid for distribution as well as local linking.
if sys.argv[2] == "macos-arm64":
    deployment = {"LSMinimumSystemVersion": "15.0", "CFBundleSupportedPlatforms": ["MacOSX"]}
else:
    platform = "iPhoneSimulator" if sys.argv[2].endswith("-simulator") else "iPhoneOS"
    deployment = {"MinimumOSVersion": "26.0", "CFBundleSupportedPlatforms": [platform]}
with open(sys.argv[1], "wb") as stream:
    plistlib.dump({
        "CFBundleExecutable": "FloeMachiningNative",
        "CFBundleIdentifier": "org.floeagent.native.FloeMachiningNative",
        "CFBundleName": "FloeMachiningNative",
        "CFBundlePackageType": "FMWK",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "10",
        **deployment
    }, stream)
PY
  SLICES+=(-framework "$dir")
done

xcodebuild -create-xcframework "${SLICES[@]}" -output "$task_new_xcf"
if [ -e "$task_old_xcf" ]; then echo "Preserve existing rollback: $task_old_xcf" >&2; exit 1; fi
if [ -d "$XCF" ]; then mv "$XCF" "$task_old_xcf"; fi
if mv "$task_new_xcf" "$XCF"; then
  rm -rf "$task_old_xcf"
else
  if [ -d "$task_old_xcf" ]; then mv "$task_old_xcf" "$XCF"; fi
  exit 1
fi
echo "[build] wrote $XCF"
find "$XCF" -type f -name FloeMachiningNative -exec shasum -a 256 {} +
