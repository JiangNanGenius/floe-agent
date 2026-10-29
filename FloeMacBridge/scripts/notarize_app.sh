#!/bin/bash
set -euo pipefail
if [[ $# -ne 3 ]]; then echo 'Usage: notarize_app.sh <app-path> <Developer-ID-identity> <keychain-profile>' >&2; exit 2; fi
app="$1"; identity="$2"; notary_profile="$3"
[[ -d "$app/Contents" && "$identity" == 'Developer ID Application:'* ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 2; }
output="$(dirname "$app")"
dmg="$output/Floe-Bridge.dmg"
[[ ! -e "$dmg" ]] || { echo 'Refusing to overwrite an existing distribution.' >&2; exit 2; }
codesign --force --timestamp --options runtime --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"
app_zip="$output/Floe-Bridge-notary.zip"
[[ ! -e "$app_zip" ]] || { echo 'Refusing to overwrite an existing notary transport.' >&2; exit 2; }
ditto -c -k --keepParent "$app" "$app_zip"
xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait --output-format json > "$output/app-notarization-private.json"
python3 - "$output/app-notarization-private.json" <<'PYAPP'
import json,sys
assert json.load(open(sys.argv[1]))['status']=='Accepted', 'App notarization was not accepted'
PYAPP
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
hdiutil create -volname 'Floe Bridge' -srcfolder "$app" -format UDZO "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait --output-format json > "$output/notarization-private.json"
python3 - "$output/notarization-private.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['status']=='Accepted', 'Notarization was not accepted'
PY
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type execute --verbose=2 "$app"
shasum -a 256 "$dmg" > "$dmg.sha256"
shasum -a 256 "$app/Contents/MacOS/FloeMacBridge" > "$output/Floe-Bridge-executable.sha256"
echo 'Signed, notarized and stapled. Publish only the reviewed DMG and checksum; keep the notary response private.'
