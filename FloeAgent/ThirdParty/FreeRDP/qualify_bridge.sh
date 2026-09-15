#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
platform="${1:?OS64 or SIMULATORARM64 required}"
deps="${2:?native dependency directory required}"
output="${3:?output directory required}"
case "$platform" in
  OS64) sdk=iphoneos; target=arm64-apple-ios26.0 ;;
  SIMULATORARM64) sdk=iphonesimulator; target=arm64-apple-ios26.0-simulator ;;
  *) exit 2 ;;
esac
root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$output/include"
xcrun --sdk "$sdk" clang -std=c11 -Wall -Wextra -Werror -O2 \
  -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
  -I "$root/Bridge/include" -I "$deps/include/freerdp3" -I "$deps/include/winpr3" \
  -c "$root/Bridge/FloeRDP.c" -o "$output/FloeRDP.o"
python3 - "$deps" "$output" <<'PY'
from pathlib import Path
import subprocess,sys
root=Path(sys.argv[1]); output=Path(sys.argv[2])
libraries=sorted(root.rglob('*.a'))
assert {'libfreerdp3.a','libwinpr3.a','libssl.a','libcrypto.a'} <= {p.name for p in libraries}
subprocess.run(['xcrun','libtool','-static','-o',str(output/'libFloeRDPNative.a'),str(output/'FloeRDP.o')]+[str(p) for p in libraries],check=True)
PY
cp "$root/Bridge/include/FloeRDP.h" "$output/include/"
cat > "$output/include/module.modulemap" <<'MAP'
module FloeRDPNative { header "FloeRDP.h" export * }
MAP
cat > "$output/link_probe.c" <<'PROBE'
#include "FloeRDP.h"
int main(void) { return floe_rdp_destroy(floe_rdp_create(0, (FloeRDPCallbacks){0})) ? 0 : 1; }
PROBE
# An actual link resolves transitive platform dependencies; compiling headers
# alone must not qualify a native library for the App.
xcrun --sdk "$sdk" clang -target "$target" \
  -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
  -I "$output/include" "$output/link_probe.c" "$output/libFloeRDPNative.a" \
  -framework Foundation -framework Security -framework SystemConfiguration \
  -framework CoreGraphics -framework CoreVideo -framework CoreMedia \
  -framework VideoToolbox -framework AudioToolbox -framework AVFoundation \
  -framework UIKit -lresolv -lz -liconv -o "$output/link-probe"
shasum -a 256 "$output/libFloeRDPNative.a" "$root/Bridge/FloeRDP.c" \
  "$root/Bridge/include/FloeRDP.h" > "$output/SHA256SUMS"
xcrun clang --version > "$output/toolchain.txt"
