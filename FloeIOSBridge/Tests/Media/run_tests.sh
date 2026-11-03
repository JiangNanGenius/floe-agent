#!/bin/bash
# Build the real BridgeCore module (including Runtime and the new Media muxer),
# the host media service as a separate module, then run the plain Swift media
# harness on this Mac. No App, Simulator, device or XCTest is used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="$(uname -m)-apple-macosx15.0"
BUILD="${MEDIA_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/media/build/mac}"
ARTIFACTS="${MEDIA_ARTIFACT_DIR:-$ROOT/Local/Private/ios-bridge-1.0-20261101/media/evidence/artifacts}"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$ARTIFACTS"

COMMON=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -g -Onone
        -sdk "$MAC_SDK" -target "$TARGET")

CORE_SOURCES=()
while IFS= read -r file; do CORE_SOURCES+=("$file"); done < <(find "$ROOT/FloeIOSBridge/Sources/BridgeCore" -name '*.swift' | sort)
HOST_SOURCES=()
while IFS= read -r file; do HOST_SOURCES+=("$file"); done < <(find "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media" -name '*.swift' | sort)

echo "== BridgeCore module + library (Runtime + RPC + Media) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -o "$BUILD/libBridgeCore.dylib" \
  "${CORE_SOURCES[@]}"

echo "== BridgeHostMedia module + library (imports BridgeCore) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeHostMedia \
  -I "$BUILD" -L "$BUILD" -lBridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeHostMedia.swiftmodule" \
  -o "$BUILD/libBridgeHostMedia.dylib" \
  "${HOST_SOURCES[@]}"

echo "== Test executable =="
"$SWIFTC" "${COMMON[@]}" -parse-as-library \
  -module-name MediaTests \
  -I "$BUILD" -L "$BUILD" -lBridgeCore -lBridgeHostMedia \
  -framework AVFoundation -framework CoreMedia -framework VideoToolbox \
  -framework CoreGraphics -framework ImageIO \
  "$ROOT"/FloeIOSBridge/Tests/Media/*.swift \
  -o "$BUILD/media-tests" \
  -Xlinker -rpath -Xlinker "$BUILD"

echo "== Contract checks =="
grep -q 'public final class BridgeVideoService: BridgeRPCStreamSource' \
  "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media/BridgeVideoService.swift"
grep -q 'public let contentType: String = BridgeVideoService.streamContentType' \
  "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media/BridgeVideoService.swift"
grep -q '"video/mp4"' "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media/BridgeVideoService.swift"
grep -q 'func openStream(clientID: String, channel: BridgeRPCStreamChannel) async -> Bool' \
  "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media/BridgeVideoService.swift"
grep -q 'func stop()' "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media/BridgeVideoService.swift"
grep -q 'kVTCompressionPropertyKey_AllowFrameReordering' \
  "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media/BridgeVideoEncoder.swift"
grep -q 'kCVPixelFormatType_32BGRA' \
  "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media/BridgeVideoEncoder.swift"
if grep -R -n 'import XCTest\|import UIKit\|XCUIScreen' \
  "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media" \
  "$ROOT/FloeIOSBridge/Sources/BridgeCore/Media"; then
  echo "forbidden XCTest/UIKit dependency in host media" >&2
  exit 1
fi
if grep -R -n 'write(to:\|FileManager.default\|NSLog\|print(' \
  "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media" \
  "$ROOT/FloeIOSBridge/Sources/BridgeCore/Media"; then
  echo "forbidden file/log output in production media source" >&2
  exit 1
fi
echo "public seam, VideoToolbox properties, no XCTest/UIKit, no frame persistence"

echo "== Run =="
rm -f "$ARTIFACTS"/*.mp4 "$ARTIFACTS"/*.rgb 2>/dev/null || true
DYLD_LIBRARY_PATH="$BUILD" MEDIA_ARTIFACT_DIR="$ARTIFACTS" "$BUILD/media-tests"

echo "== ffprobe / ffmpeg decode proof =="
for artifact in "$ARTIFACTS"/stream-initial.mp4 "$ARTIFACTS"/stream-decode.mp4 "$ARTIFACTS"/stream-portrait.mp4; do
  test -s "$artifact"
  echo "-- $artifact"
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,level,width,height,pix_fmt \
    -of default=noprint_wrappers=1 "$artifact"
  ffmpeg -v error -i "$artifact" -f null -
  ffmpeg -v error -i "$artifact" -frames:v 1 -pix_fmt rgb24 -f rawvideo \
    "$ARTIFACTS/$(basename "$artifact" .mp4)-first.rgb" -y
  python3 - "$ARTIFACTS/$(basename "$artifact" .mp4)-first.rgb" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
if len(data) < 3 or len(data) % 3 != 0:
    raise SystemExit('decoded RGB payload is empty')
values = [sum(data[i::3]) / (len(data) // 3) for i in range(3)]
if max(values) - min(values) < 3:
    raise SystemExit(f'decoded frame is monochrome: {values}')
print('decoded RGB bytes', len(data), 'mean', [round(v, 1) for v in values])
PY
done

echo "== Media checks passed =="
