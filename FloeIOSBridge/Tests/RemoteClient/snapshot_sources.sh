#!/bin/bash
# Copy the read-only Core/RPC and Host/RPC sources (owned by the RPC lane) into
# a build snapshot only after two consecutive hashes match. This keeps our
# adapter compile deterministic while another worker edits those files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="${1:?destination required}"
hash_sources() {
  find "$ROOT/FloeIOSBridge/Sources/BridgeCore/RPC" "$ROOT/FloeIOSBridge/Sources/BridgeHost/RPC" \
       "$ROOT/FloeIOSBridge/Sources/BridgeHost/Remote" -type f -name '*.swift' -print0 \
    | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}'
}
for attempt in $(seq 1 12); do
  before="$(hash_sources)"
  rm -rf "$DEST"
  mkdir -p "$DEST/BridgeCore" "$DEST/BridgeHost"
  cp "$ROOT"/FloeIOSBridge/Sources/BridgeCore/RPC/*.swift "$DEST/BridgeCore/"
  cp "$ROOT"/FloeIOSBridge/Sources/BridgeHost/RPC/*.swift "$DEST/BridgeHost/"
  cp "$ROOT"/FloeIOSBridge/Sources/BridgeHost/Remote/*.swift "$DEST/BridgeHost/"
  after="$(hash_sources)"
  if [ "$before" = "$after" ]; then
    ( cd "$DEST" && find . -type f -name '*.swift' -print0 | sort -z | xargs -0 shasum -a 256 > SOURCES.sha256 )
    echo "$DEST"
    exit 0
  fi
  sleep 2
done
echo "source snapshot did not stabilize" >&2
exit 1
