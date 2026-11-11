#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Focused qualification for FloeCore.Help: compiles the real production Core
# sources (Foundation-only) with this host and runs behavior checks against
# the real generated built-in package on macOS. Digest uses CryptoKit SHA-256,
# the same algorithm FloeDigest.sha256Hex injects in production.
#
# Usage (wrapped by the shared native window):
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
#     python3 Local/Private/shared-native-window/with_native_window.py \
#     --label help-core -- FloeAgent/Qualification/HelpCore/run_help_core_qualification.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# HelpCore -> Qualification -> FloeAgent -> repo root ("IOS AI AGENT")
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
APP_ROOT="$REPO_ROOT/FloeAgent"
PACKAGE="$APP_ROOT/FloeApp/Resources/Help"
CHECKOUT_KEY="$(printf '%s' "$REPO_ROOT" | shasum -a 256 | cut -c1-12)"
TOOLCHAIN_KEY="$(xcrun swiftc --version 2>/dev/null | shasum -a 256 | cut -c1-8)"
SCRATCH="${CODEX_BUILD_SCRATCH:-$HOME/Library/Caches/CodexBuild/FloeAgent/$CHECKOUT_KEY/$TOOLCHAIN_KEY/help-core-macos}"
mkdir -p "$SCRATCH"

BIN="$SCRATCH/help-core-qualification"
DEFAULT_LOG="$REPO_ROOT/Local/Private/help-implementation-20261111/content/help-core-qualification.log"
LOG="${HELP_CORE_LOG:-$DEFAULT_LOG}"
mkdir -p "$(dirname "$LOG")"

{
  echo "== toolchain =="
  xcrun swiftc --version
  echo "== compile =="
  xcrun swiftc -O -swift-version 6 \
    -o "$BIN" \
    "$APP_ROOT/Sources/FloeCore/Help/HelpContracts.swift" \
    "$APP_ROOT/Sources/FloeCore/Help/HelpLibrary.swift" \
    "$HERE/main.swift" \
    -Xfrontend -enable-actor-data-race-checks
  echo "== run =="
  HELP_CORE_PACKAGE_ROOT="$PACKAGE" "$BIN"
  echo "== qualification exit 0 =="
} 2>&1 | tee "$LOG"
