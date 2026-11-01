#!/bin/bash
# Build the pinned, patched native slice. No prebuilt upstream fallback.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
LOCK="$PROJECT_DIR/Vendor/idevice.lock.json"
CACHE="${FLOE_IDEVICE_CACHE:-$HOME/Library/Caches/CodexBuild/FloeIOSBridge/1.0/ddi-native}"
SCRATCH="${FLOE_IDEVICE_SOURCE_ROOT:-$REPO_DIR/Local/Scratch/ios-bridge-1.0-20261101/ddi/recipe}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET=26.0
export CARGO_TARGET_DIR="$CACHE/target"
CHECK=0
[ "${1:-}" != --check ] || CHECK=1
/usr/bin/python3 "$PROJECT_DIR/Vendor/verify_idevice.py" --lock "$LOCK" --project "$PROJECT_DIR"
if [ "$CHECK" = 1 ]; then exit 0; fi
mkdir -p "$SCRATCH" "$CACHE"
/usr/bin/python3 "$PROJECT_DIR/Vendor/verify_idevice.py" --lock "$LOCK" --project "$PROJECT_DIR" --prepare "$SCRATCH"
SOURCE="$SCRATCH/source"
printf -v CARGO_ENCODED_RUSTFLAGS '%s\037%s' "--remap-path-prefix=$SOURCE=/floe/idevice" "--remap-path-prefix=$HOME/.cargo/registry/src=/floe/cargo"
export CARGO_ENCODED_RUSTFLAGS
FEATURES="ring,cryptexd,tunnel_tcp_stack,mobile_image_mounter,tss,tcp"
# --locked must fail rather than silently rewriting upstream dependencies.
cargo test --manifest-path "$SOURCE/Cargo.toml" -p idevice-ffi --locked --no-default-features --features "$FEATURES" -j "${FLOE_IDEVICE_JOBS:-6}" --lib ddi_control::tests
cargo rustc --manifest-path "$SOURCE/Cargo.toml" -p idevice-ffi --locked --release --target aarch64-apple-ios --no-default-features --features "$FEATURES" -j "${FLOE_IDEVICE_JOBS:-6}" --lib --crate-type staticlib
/usr/bin/python3 "$PROJECT_DIR/Vendor/verify_idevice.py" --lock "$LOCK" --project "$PROJECT_DIR" --export "$CACHE/IDevice.xcframework" --source "$SOURCE" --library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libidevice_ffi.a"
echo "verified patched native slice: $CACHE/IDevice.xcframework"
