#!/usr/bin/env bash
# Builds the local l10n SwiftSyntax helper binaries into a task-owned cache
# (never into the worktree — they are regenerable host executables).
# Uses only the Xcode default toolchain's host SwiftSyntax dylibs.
#
# Override output dir with FLOE_L10N_BIN (defaults to the CodexBuild cache).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
D="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host"
OUT="${FLOE_L10N_BIN:-$HOME/Library/Caches/CodexBuild/Floe/promo-english/l10n-bin}"
mkdir -p "$OUT"
LIBS=(-lSwiftSyntax -lSwiftParser -lSwiftSyntaxBuilder)
build() {
  local src="$1" out="$2"
  xcrun swiftc -parse-as-library -O "$src" \
    -I "$D" -L "$D" "${LIBS[@]}" \
    -Xlinker -rpath -Xlinker "$D" \
    -o "$OUT/$out"
}
build "$HERE/Extract.swift" "l10n-extract"
if [[ -f "$HERE/Rewrite.swift" ]]; then
  build "$HERE/Rewrite.swift" "l10n-rewrite"
fi
echo "built l10n tools in $OUT"
