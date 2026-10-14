#!/bin/bash
# stage-boot-pair.sh — generate or verify the bundled boot-pair resource
# consumed by LinuxGuestBootAssetUpdateService (FloeExecution) and wired
# into the App by project.yml.
#
#   stage-boot-pair.sh <source_dir>            # stage verified bytes (copy)
#   FLOE_BOOT_PAIR_SRC=<dir> stage-boot-pair.sh
#   stage-boot-pair.sh --check [source_dir]
#       # READ-ONLY: compare the staged files against the tracked manifest
#       # (and, when a source directory is given, the source bytes as well);
#       # exit non-zero with a clear message when missing or corrupted.
#       # Never writes, copies, downloads, or modifies anything.
#
# The source directory holds the retained, verified firmware + kernel
# bytes. There is NO implicit default: staging requires an explicit
# source_dir argument or FLOE_BOOT_PAIR_SRC, so no machine-specific or
# private path is baked into tracked configuration and a wrong-machine
# stage can never silently copy stale bytes.
#
# The tracked boot-pair-v2.manifest.json next to this script is the single
# authority for hashes/sizes; staging and --check both fail closed on any
# mismatch, so the App can never bundle unverified firmware/kernel.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/bundled-boot-pair"
MANIFEST="$HERE/boot-pair-v2.manifest.json"

MODE="stage"
SRC="${FLOE_BOOT_PAIR_SRC:-}"
for arg in "$@"; do
  if [ "$arg" = "--check" ]; then
    MODE="check"
  elif [ -z "$SRC" ]; then
    SRC="$arg"
  else
    echo "ERROR: unexpected extra argument: $arg" >&2; exit 2
  fi
done

[ -f "$MANIFEST" ] || { echo "ERROR: $MANIFEST missing" >&2; exit 1; }

read_manifest() {
  python3 -c 'import json,sys
m = json.load(open(sys.argv[1]))
p = m["pair"]
print(p["firmwareFileName"])
print(p["kernelFileName"])
print(p["firmwareSHA256"])
print(p["kernelSHA256"])
print(p["firmwareBytes"])
print(p["kernelBytes"])' "$MANIFEST"
}

IFS=$'\n' read -r -d '' FIRMWARE KERNEL FW_SHA K_SHA FW_BYTES K_BYTES <<< "$(read_manifest "$MANIFEST")" || true
[ -n "${K_BYTES:-}" ] || { echo "ERROR: could not parse $MANIFEST" >&2; exit 1; }

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else sha256sum "$1" | awk '{print $1}'; fi
}
size_of() {
  if stat -f %z "$1" >/dev/null 2>&1; then stat -f %z "$1"; else stat -c %s "$1"; fi
}

fail() { echo "ERROR: $1" >&2; exit 1; }

# Verify one file against expected size+sha. $4 = human role.
verify_one() {
  [ -f "$1" ] || fail "$4 missing: $1"
  local actual_size actual_sha
  actual_size=$(size_of "$1")
  [ "$actual_size" = "$3" ] || fail "$4 size mismatch ($actual_size != $3): $1"
  actual_sha=$(sha_of "$1")
  [ "$actual_sha" = "$2" ] || fail "$4 sha256 mismatch ($actual_sha != $2): $1"
}

if [ "$MODE" = "check" ]; then
  verify_one "$DEST/$FIRMWARE" "$FW_SHA" "$FW_BYTES" "staged firmware"
  verify_one "$DEST/$KERNEL" "$K_SHA" "$K_BYTES" "staged kernel"
  if ! cmp -s "$MANIFEST" "$DEST/boot-pair-v2.manifest.json"; then
    fail "staged manifest differs from tracked $MANIFEST"
  fi
  if [ -n "$SRC" ]; then
    # Optional source verification: proves the candidate source matches the
    # tracked manifest too. Read-only.
    verify_one "$SRC/$FIRMWARE" "$FW_SHA" "$FW_BYTES" "source firmware"
    verify_one "$SRC/$KERNEL" "$K_SHA" "$K_BYTES" "source kernel"
  fi
  echo "check ok: bundled boot pair matches tracked manifest"
  exit 0
fi

# Stage mode: an explicit source is mandatory — never an implicit
# machine-specific path.
if [ -z "$SRC" ]; then
  echo "ERROR: no source directory given." >&2
  echo "       Pass the directory that holds the verified ${FIRMWARE} + ${KERNEL}" >&2
  echo "       as the first argument, or set FLOE_BOOT_PAIR_SRC." >&2
  echo "       The tracked manifest ($MANIFEST) is the only authority;" >&2
  echo "       nothing is copied until both files match it." >&2
  exit 2
fi
verify_one "$SRC/$FIRMWARE" "$FW_SHA" "$FW_BYTES" "source firmware"
verify_one "$SRC/$KERNEL" "$K_SHA" "$K_BYTES" "source kernel"

mkdir -p "$DEST"
cp "$SRC/$FIRMWARE" "$DEST/$FIRMWARE"
cp "$SRC/$KERNEL" "$DEST/$KERNEL"
cp "$MANIFEST" "$DEST/boot-pair-v2.manifest.json"
echo "staged bundled boot pair -> $DEST"
