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
# Keep this release pin independent of resolver defaults.
python3 - "$bridge_root/Package.resolved" <<'PYPIN'
import json,sys
pins=json.load(open(sys.argv[1]))['pins']
assert len(pins)==1 and pins[0]['identity']=='sparkle'
assert pins[0]['state']=={'revision':'ab7d71291238df6e0492143b120c9b696a35f603','version':'2.10.1'}
PYPIN
build_jobs="${FLOE_BRIDGE_BUILD_JOBS:-4}"
[[ "$build_jobs" =~ ^[1-4]$ ]] || { echo 'Use 1–4 compiler jobs.' >&2; exit 2; }
swift build --package-path "$bridge_root" --scratch-path "$cache_root" --configuration release --product FloeMacBridge --disable-automatic-resolution --jobs "$build_jobs"
bin_dir="$(swift build --package-path "$bridge_root" --scratch-path "$cache_root" --configuration release --show-bin-path --disable-automatic-resolution)"
sparkle_root="$cache_root/artifacts/sparkle/Sparkle"
sparkle_framework="$sparkle_root/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$sparkle_framework" && -f "$sparkle_root/LICENSE" ]] || { echo 'Pinned Sparkle artifact is missing.' >&2; exit 2; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$sparkle_framework/Resources/Info.plist")" == '2.10.1' ]] || { echo 'Unexpected Sparkle artifact.' >&2; exit 2; }
codesign --verify --deep --strict "$sparkle_framework"
app="$output_root/Floe Bridge.app"
if [[ -e "$app" ]]; then echo 'Refusing to overwrite an existing app artifact.' >&2; exit 2; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty" "$app/Contents/Frameworks"
cp "$bin_dir/FloeMacBridge" "$app/Contents/MacOS/FloeMacBridge"
[[ -f "$bridge_root/Resources/FloeBridge.icns" && -f "$bridge_root/Resources/FloeBrand.png" ]] || { echo 'Floe brand resources are missing.' >&2; exit 2; }
cp "$bridge_root/Info.plist" "$app/Contents/Info.plist"
ditto "$bridge_root/Resources" "$app/Contents/Resources"
# ditto preserves Sparkle's versioned symlinks, permissions and nested helpers.
ditto "$sparkle_framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_root/LICENSE" "$app/Contents/Resources/ThirdParty/Sparkle-LICENSE.txt"
cp "$bridge_root/Package.resolved" "$app/Contents/Resources/ThirdParty/Package.resolved"
[[ -L "$app/Contents/Frameworks/Sparkle.framework/Versions/Current" && -L "$app/Contents/Frameworks/Sparkle.framework/Sparkle" ]] || { echo 'Framework symlink preservation failed.' >&2; exit 2; }
otool -L "$app/Contents/MacOS/FloeMacBridge" | grep -F '@rpath/Sparkle.framework/' >/dev/null
otool -l "$app/Contents/MacOS/FloeMacBridge" | grep -F '@executable_path/../Frameworks' >/dev/null
printf '%s\n' "$source_sha" > "$app/Contents/Resources/source-commit.txt"
plutil -lint "$app/Contents/Info.plist"
file "$app/Contents/MacOS/FloeMacBridge"
printf 'Prepared UNSIGNED app (not public-installable): %s\n' "$app"
