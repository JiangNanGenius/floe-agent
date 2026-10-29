#!/bin/bash
set -euo pipefail
bridge_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(git -C "$bridge_root" rev-parse --show-toplevel)"
source_sha="$(git -C "$repo_root" rev-parse HEAD)"
if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  echo 'Commit the reviewed source before producing a distributable bridge.' >&2; exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
checkout_id="$(printf '%s' "$repo_root" | shasum -a 256 | cut -c1-12)"
toolchain_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEVELOPER_DIR/../Info.plist")"
cache_root="${FLOE_BRIDGE_BUILD_CACHE:-$HOME/Library/Caches/CodexBuild/FloeMacBridge/$checkout_id/$toolchain_id/macos-arm64}"
xcrun --sdk macosx --show-sdk-version
df -h "$cache_root/.." "$repo_root" 2>/dev/null || df -h "$HOME" "$repo_root"
vm_stat
sysctl vm.swapusage
output_root="${FLOE_BRIDGE_OUTPUT:-$repo_root/Local/Artifacts/mac-bridge/$source_sha}"
mkdir -p "$cache_root" "$output_root"
swift build --package-path "$bridge_root" --scratch-path "$cache_root" --configuration release --product FloeMacBridge --jobs 6
app="$output_root/Floe Bridge.app"
if [[ -e "$app" ]]; then echo 'Refusing to overwrite an existing app artifact.' >&2; exit 2; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$cache_root/release/FloeMacBridge" "$app/Contents/MacOS/FloeMacBridge"
cp "$bridge_root/Info.plist" "$app/Contents/Info.plist"
cp -R "$bridge_root/Resources/" "$app/Contents/Resources/"
printf '%s\n' "$source_sha" > "$app/Contents/Resources/source-commit.txt"
plutil -lint "$app/Contents/Info.plist"
file "$app/Contents/MacOS/FloeMacBridge"
printf 'Prepared UNSIGNED app (not public-installable): %s\n' "$app"
