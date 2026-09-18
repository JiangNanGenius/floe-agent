#!/bin/bash
# Build and run the in-flight URLSession cancellation probe.
#
# Compiles the current FloeExecution/HTTPRequestService.swift with a small
# @main probe against the cached FloeCore/FloeTools modules and static
# libraries from a previous local build (same compiler that built them), then
# points it at a local stalling TCP server. No SwiftPM, no network beyond
# 127.0.0.1.
#
# Requires: FloeAgent/.build/out/Products/Debug/{FloeCore,FloeTools}.swiftmodule
# and lib{FloeCore,FloeTools}.a from a prior local FloePackage build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO="$ROOT/FloeAgent"
PRODUCTS="$REPO/.build/out/Products/Debug"
BUILD="${HARNESS_SCRATCH:-${TMPDIR:-/tmp}/floe-feedback-http-cancel}"
mkdir -p "$BUILD"

for artifact in "$PRODUCTS/FloeCore.swiftmodule" "$PRODUCTS/FloeTools.swiftmodule" \
                "$PRODUCTS/libFloeCore.a" "$PRODUCTS/libFloeTools.a"; do
  if [ ! -e "$artifact" ]; then
    echo "missing cached module/library: $artifact" >&2
    echo "run one local FloePackage build once to populate the module cache" >&2
    exit 2
  fi
done

# Use the toolchain that produced the cached modules (Command Line Tools here);
# override with DEVELOPER_DIR when the cache came from Xcode.
unset DEVELOPER_DIR
echo "== building cancellation probe"
/usr/bin/xcrun swiftc -swift-version 6 \
  -I "$PRODUCTS" \
  -L "$PRODUCTS" -lFloeCore -lFloeTools \
  "$REPO/Sources/FloeExecution/HTTPRequestService.swift" \
  "$SCRIPT_DIR/feedback_http_cancel_probe.swift" \
  -o "$BUILD/feedback_http_cancel_probe"

echo "== starting stalling server"
PORT_FILE="$BUILD/stall.port"
rm -f "$PORT_FILE"
python3 -c "
import socket, time
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 0))
server.listen(1)
open('$PORT_FILE', 'w').write(str(server.getsockname()[1]))
connection, _ = server.accept()
connection.recv(4096)
time.sleep(25)
" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$PORT_FILE" ] || { echo "stalling server did not start" >&2; exit 2; }

PORT="$(cat "$PORT_FILE")"
echo "== running probe against 127.0.0.1:$PORT"
"$BUILD/feedback_http_cancel_probe" "$PORT"
