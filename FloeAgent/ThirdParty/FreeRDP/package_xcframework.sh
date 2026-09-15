#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Assemble the reviewed per-platform bridge outputs into a consumable
# FloeRDPNative.xcframework and prove Xcode can archive, inspect and link it.
set -euo pipefail
os64="${1:?OS64 bridge output directory required}"
sim="${2:?SIMULATORARM64 bridge output directory required}"
output="${3:?output directory required}"
mkdir -p "$output"
framework="$output/FloeRDPNative.xcframework"
rm -rf "$framework"

# The previous LTO build failed here: bitcode archive members made lipo
# report "Unknown header: 0xb17c0de". Inspect both inputs before packaging.
xcrun lipo -info "$os64/libFloeRDPNative.a"
xcrun lipo -info "$sim/libFloeRDPNative.a"

xcodebuild -create-xcframework \
  -library "$os64/libFloeRDPNative.a" -headers "$os64/include" \
  -library "$sim/libFloeRDPNative.a" -headers "$sim/include" \
  -output "$framework"

# Every slice must stay inspectable after packaging.
find "$framework" -name 'libFloeRDPNative.a' -exec xcrun lipo -info '{}' \;

# A packaged library that cannot link is not deliverable: probe each slice
# against the real SDKs and system frameworks the App uses.
probe="$(mktemp -d)/probe"
mkdir -p "$probe"
cat > "$probe/link_probe.c" <<'PROBE'
#include "FloeRDP.h"
int main(void) { return floe_rdp_destroy(floe_rdp_create(0, (FloeRDPCallbacks){0})) ? 0 : 1; }
PROBE
probe_slice() {
  slice="${1:?xcframework slice directory required}"
  sdk="${2:?SDK name required}"
  target="${3:?clang target triple required}"
  xcrun --sdk "$sdk" clang -target "$target" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -I "$slice/Headers" "$probe/link_probe.c" "$slice/libFloeRDPNative.a" \
    -framework Foundation -framework Security -framework SystemConfiguration \
    -framework CoreGraphics -framework CoreVideo -framework CoreMedia \
    -framework VideoToolbox -framework AudioToolbox -framework AVFoundation \
    -framework UIKit -lresolv -lz -liconv -o "$probe/probe-${sdk}"
}
device_slice="$(find "$framework" -maxdepth 1 -type d -name 'ios-arm64' -print -quit)"
sim_slice="$(find "$framework" -maxdepth 1 -type d -name 'ios-arm64-simulator' -print -quit)"
test -n "$device_slice" && test -n "$sim_slice"
probe_slice "$device_slice" iphoneos arm64-apple-ios26.0
probe_slice "$sim_slice" iphonesimulator arm64-apple-ios26.0-simulator

cp "$os64/FreeRDP-LICENSE" "$os64/OpenSSL-LICENSE" "$output/"
find "$framework" -name 'libFloeRDPNative.a' -print0 | sort -z | xargs -0 shasum -a 256 > "$output/SHA256SUMS"
xcrun clang --version > "$output/toolchain.txt"
printf 'packaged %s\n' "$framework"
