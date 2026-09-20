#!/bin/bash
# fetch_source.sh — pinned fetch + verification of the TinyEMU 2019-12-21
# source tarball (and the optional 2018 RISC-V demo disk image used by the
# qualification smoke test).
#
#   fetch_source.sh <dest_dir>          download + verify + extract
#   fetch_source.sh --check <dest_dir>  read-only: verify hashes of an
#                                       already-extracted tree/tarball
#
# Hashes are pinned here; never edit them to make a check pass — regenerate
# only as a deliberate, reviewed source upgrade.
set -euo pipefail

TINYEMU_URL="https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz"
TINYEMU_SHA256="be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555"
DEMO_URL="https://bellard.org/tinyemu/diskimage-linux-riscv-2018-09-23.tar.gz"
DEMO_SHA256="808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14"

sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else sha256sum "$1" | awk '{print $1}'; fi
}

fetch_one() {
  local url="$1" want="$2" dest="$3" name="$4"
  local tarball="$dest/$name.tar.gz"
  if [ ! -f "$tarball" ]; then
    echo "fetch: $url"
    curl -fL --retry 3 --max-time 600 -o "$tarball" "$url"
  fi
  local got; got="$(sha "$tarball")"
  if [ "$got" != "$want" ]; then
    echo "ERROR: $name SHA256 mismatch: got $got want $want" >&2
    exit 1
  fi
  echo "verified: $name sha256=$got"
  if [ ! -d "$dest/$name" ]; then
    tar xzf "$tarball" -C "$dest"
  fi
}

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
DEST="${1:?usage: fetch_source.sh [--check] <dest_dir>}"

if [ "$CHECK_ONLY" = "1" ]; then
  # read-only verification of existing tarballs; does not modify anything
  ok=1
  for spec in "tinyemu-2019-12-21 $TINYEMU_SHA256" "diskimage-linux-riscv-2018-09-23 $DEMO_SHA256"; do
    set -- $spec
    if [ -f "$DEST/$1.tar.gz" ]; then
      got="$(sha "$DEST/$1.tar.gz")"
      if [ "$got" = "$2" ]; then echo "check ok: $1"; else echo "check FAIL: $1 got $got want $2"; ok=0; fi
    else
      echo "check: $1 tarball absent (skipped)"
    fi
  done
  [ "$ok" = "1" ]
  exit $?
fi

mkdir -p "$DEST"
fetch_one "$TINYEMU_URL" "$TINYEMU_SHA256" "$DEST" "tinyemu-2019-12-21"
fetch_one "$DEMO_URL" "$DEMO_SHA256" "$DEST" "diskimage-linux-riscv-2018-09-23"
echo "done: sources in $DEST"
