#!/bin/sh
set -eu

echo "Floe Agent Xcode Cloud environment probe"
echo "CI build: ${CI_BUILD_ID:-local}"
echo "Xcode: ${CI_XCODE_VERSION:-unknown}"
echo "macOS: $(sw_vers -productVersion)"
echo "Architecture: $(uname -m)"

# Xcode Cloud workers cannot present the interactive trust sheet required the
# first time a pinned Swift macro target is encountered. The package graph is
# still fixed by Package.resolved and validated by the normal CI/release gates.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
echo "Pinned Swift macro fingerprint prompt disabled for this CI worker"
echo "Logical CPUs: $(sysctl -n hw.logicalcpu 2>/dev/null || echo unknown)"

memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
if [ "$memory_bytes" -gt 0 ] 2>/dev/null; then
  echo "Memory GiB: $((memory_bytes / 1024 / 1024 / 1024))"
else
  echo "Memory GiB: unknown"
fi

echo "Workspace filesystem:"
df -h "${CI_WORKSPACE_PATH:-.}"

echo "Required Collabora tools:"
for tool in git make autoconf automake pkg-config xcodebuild; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  $tool: $(command -v "$tool")"
  else
    echo "  $tool: missing"
  fi
done

echo "Probe complete; Collabora build is intentionally disabled."
