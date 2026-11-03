#!/bin/bash
# Developer ID distribution only. No --deep signing: sign nested code inside out.
set -euo pipefail
if [[ $# -ne 2 ]]; then echo 'Usage: sign_app.sh <app-path> <Developer-ID-identity>' >&2; exit 2; fi
app="$1"; identity="$2"
[[ -d "$app/Contents" && "$identity" == 'Developer ID Application:'* ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 2; }
framework="$app/Contents/Frameworks/Sparkle.framework"
[[ -L "$framework/Versions/Current" && -L "$framework/Sparkle" ]] || { echo 'Sparkle versioned framework symlinks are missing.' >&2; exit 2; }
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$framework/Resources/Info.plist")"
[[ "$version" == '2.10.1' ]] || { echo 'Unexpected Sparkle version.' >&2; exit 2; }
for component in \
  "$framework/Versions/B/Autoupdate" \
  "$framework/Versions/B/Updater.app" \
  "$framework/Versions/B/XPCServices/Installer.xpc" \
  "$framework/Versions/B/XPCServices/Downloader.xpc" \
  "$framework"; do
  [[ -e "$component" ]] || { echo "Missing nested code: $component" >&2; exit 2; }
  # Retain upstream component identifiers/entitlements; replace its signing
  # identity so hardened-runtime library validation accepts the embedded code.
  codesign --force --timestamp --options runtime --preserve-metadata=identifier,entitlements --sign "$identity" "$component"
  codesign --verify --strict --verbose=2 "$component"
done
codesign --force --timestamp --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
