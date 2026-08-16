#!/bin/bash
# Package a CODE_SIGNING_ALLOWED=NO device build as a verifiably unsigned IPA.
set -euo pipefail

if (( $# != 3 )); then
    echo "usage: $0 <Floe Agent.app> <output-directory> <asset-name.ipa>" >&2
    exit 64
fi

APP_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT_DIRECTORY="$2"
ASSET_NAME="$3"

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
    echo "error: app bundle not found: $APP_PATH" >&2
    exit 1
fi
if [[ "$ASSET_NAME" != *-unsigned.ipa || "$ASSET_NAME" == */* ]]; then
    echo "error: asset name must end in -unsigned.ipa and contain no path separators" >&2
    exit 1
fi
if [[ -e "$APP_PATH/embedded.mobileprovision" || -d "$APP_PATH/_CodeSignature" ]]; then
    echo "error: app contains signing material" >&2
    exit 1
fi
if /usr/bin/codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    echo "error: app is signed; refusing to publish it as unsigned" >&2
    exit 1
fi

TEMP_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/floe-ipa.XXXXXX")"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT
mkdir -p "$TEMP_DIRECTORY/Payload" "$OUTPUT_DIRECTORY"
/usr/bin/ditto "$APP_PATH" "$TEMP_DIRECTORY/Payload/$(basename "$APP_PATH")"

IPA_PATH="$(cd "$OUTPUT_DIRECTORY" && pwd)/$ASSET_NAME"
(
    cd "$TEMP_DIRECTORY"
    /usr/bin/zip -qry -X "$IPA_PATH" Payload
)
/usr/bin/unzip -tq "$IPA_PATH" >/dev/null

APP_COUNT="$(/usr/bin/unzip -Z1 "$IPA_PATH" | awk -F/ '$1 == "Payload" && $2 ~ /\.app$/ && $3 == "" && NF == 3 {count++} END {print count+0}')"
if [[ "$APP_COUNT" != "1" ]]; then
    echo "error: IPA must contain exactly one top-level app bundle (found $APP_COUNT)" >&2
    exit 1
fi
if /usr/bin/unzip -Z1 "$IPA_PATH" | grep -Eq '(^|/)(embedded\.mobileprovision|_CodeSignature)(/|$)'; then
    echo "error: IPA contains signing material" >&2
    exit 1
fi

(
    cd "$OUTPUT_DIRECTORY"
    /usr/bin/shasum -a 256 "$ASSET_NAME" > "$ASSET_NAME.sha256"
)

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist")"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_PATH/Info.plist")"

echo "unsigned IPA OK: $IPA_PATH"
echo "bundle=$BUNDLE_ID version=$VERSION build=$BUILD minimumOS=$MINIMUM_OS"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "ipa_path=$IPA_PATH"
        echo "checksum_path=$IPA_PATH.sha256"
        echo "bundle_id=$BUNDLE_ID"
        echo "version=$VERSION"
        echo "build=$BUILD"
        echo "minimum_os=$MINIMUM_OS"
    } >> "$GITHUB_OUTPUT"
fi
