#!/usr/bin/env bash
# Stable host Swift source-set manifest/hash for qualification evidence.
# Hashes the RESOLVED content of every Swift source/test file plus the package
# manifest and pins, sorted by repository-relative path. Symlinked original
# sources are hashed through their target, never by link text.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
OUT="${1:-}"
FILES="$(mktemp "${TMPDIR:-/tmp}/floe-swift-source-files.XXXXXX")"
trap 'rm -f "$FILES"' EXIT
{
  find -L shared/Sources shared/Tests -type f -print
  printf '%s\n' shared/Package.swift shared/Package.resolved
} | LC_ALL=C sort -u > "$FILES"
while IFS= read -r file; do
  shasum -a 256 "$file"
done < "$FILES" > "${OUT:-/dev/stdout}"
if [ -n "$OUT" ]; then
  shasum -a 256 "$OUT"
fi
