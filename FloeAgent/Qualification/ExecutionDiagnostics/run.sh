#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
cache="$HOME/Library/Caches/CodexBuild/Floe/execution-diagnostics"
mkdir -p "$cache"
scratch="$(mktemp -d "$cache/run.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 6 "$root/Sources/FloeCore/ExecutionBreadcrumbs.swift" \
  "$root/Qualification/ExecutionDiagnostics/main.swift" -o "$scratch/test"
"$scratch/test" "$scratch/journal"
