#!/usr/bin/env bash
# Pins the Node runtime and bundled tool entry points.
#
# The runtime itself is linked into the app as NodeMobile.framework from the
# nodejs-mobile iOS release (JIT disabled). Tool entry points (npm, pnpm,
# yarn) are pure JavaScript tarballs extracted into Resources/NodeTools.
#
# Usage: scripts/pin_node_tools.sh [--check]
# Requires: curl, shasum, tar, unzip (all system tools).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/NodeMobile"
RESOURCES="$ROOT/FloeApp/Resources/NodeTools"
LOCK="$ROOT/scripts/node_tools.lock.json"
CHECK="${1:-}"

NODE_MOBILE_VERSION="18.20.4"
NODE_MOBILE_URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v${NODE_MOBILE_VERSION}/nodejs-mobile-v${NODE_MOBILE_VERSION}-ios.zip"
NPM_VERSION="10.9.2"
NPM_URL="https://registry.npmjs.org/npm/-/npm-${NPM_VERSION}.tgz"
PNPM_VERSION="9.15.9"
PNPM_URL="https://registry.npmjs.org/pnpm/-/pnpm-${PNPM_VERSION}.tgz"
YARN_VERSION="1.22.22"
YARN_URL="https://registry.npmjs.org/yarn/-/yarn-${YARN_VERSION}.tgz"

fetch() {
  local url="$1" destination="$2"
  if [[ -f "$destination" && "$CHECK" != "--check" ]]; then
    echo "cache hit: $destination"
    return
  fi
  echo "fetching $url"
  curl -fsSL "$url" -o "$destination"
}

if [[ "$CHECK" != "--check" ]]; then
  mkdir -p "$VENDOR" "$RESOURCES" "$(dirname "$LOCK")"
  fetch "$NODE_MOBILE_URL" "$VENDOR/nodejs-mobile-${NODE_MOBILE_VERSION}-ios.zip"
  mkdir -p "$VENDOR/extracted"
  unzip -q -o "$VENDOR/nodejs-mobile-${NODE_MOBILE_VERSION}-ios.zip" -d "$VENDOR/extracted"

  fetch "$NPM_URL" "$RESOURCES/npm-${NPM_VERSION}.tgz"
  fetch "$PNPM_URL" "$RESOURCES/pnpm-${PNPM_VERSION}.tgz"
  fetch "$YARN_URL" "$RESOURCES/yarn-${YARN_VERSION}.tgz"
  rm -rf "$RESOURCES/npm" "$RESOURCES/pnpm" "$RESOURCES/yarn"
  mkdir -p "$RESOURCES/npm" "$RESOURCES/pnpm" "$RESOURCES/yarn"
  tar -xzf "$RESOURCES/npm-${NPM_VERSION}.tgz" -C "$RESOURCES/npm" --strip-components=1
  tar -xzf "$RESOURCES/pnpm-${PNPM_VERSION}.tgz" -C "$RESOURCES/pnpm" --strip-components=1
  tar -xzf "$RESOURCES/yarn-${YARN_VERSION}.tgz" -C "$RESOURCES/yarn" --strip-components=1
fi

python3 - "$LOCK" "$NODE_MOBILE_VERSION" "$VENDOR/nodejs-mobile-${NODE_MOBILE_VERSION}-ios.zip" \
  "$NPM_VERSION" "$RESOURCES/npm-${NPM_VERSION}.tgz" \
  "$PNPM_VERSION" "$RESOURCES/pnpm-${PNPM_VERSION}.tgz" \
  "$YARN_VERSION" "$RESOURCES/yarn-${YARN_VERSION}.tgz" <<'PY'
import hashlib, json, pathlib, sys
lock_path = pathlib.Path(sys.argv[1])
def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
def entry(name, version, path, extras=None):
    data = {"name": name, "version": version, "sha256": digest(path)}
    if extras:
        data.update(extras)
    return data
payload = {
    "schemaVersion": 1,
    "runtime": entry("nodejs-mobile", sys.argv[2], sys.argv[3], {"abi": 108, "jit": False}),
    "tools": [
        entry("npm", sys.argv[4], sys.argv[5], {"entry": "bin/npm-cli.js"}),
        entry("pnpm", sys.argv[6], sys.argv[7], {"entry": "pnpm.cjs"}),
        entry("yarn", sys.argv[8], sys.argv[9], {"entry": "bin/yarn.js"}),
    ],
}
lock_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(f"wrote {lock_path}")
PY

echo "node tools pinned."
