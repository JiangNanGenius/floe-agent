#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

BUNDLE_ID="org.floeagent.iosbridge"
IPA=""
PROFILE_REFERENCE=""
IDENTITY=""
OUTPUT=""
SCRATCH_DIR="${CANARY_SCRATCH_DIR:-$REPO_ROOT/Local/Scratch/ios-bridge-20261031/canary}"

usage() {
    echo "usage: $0 --ipa <unsigned.ipa> --profile <path-or-uuid> --identity <codesign identity> [--output <signed.ipa>]"
    echo
    echo "Signs the single-app BootstrapCanary package inside-out: nested frameworks,"
    echo "PlugIns/*.xctest, then the host app with the development profile entitlements."
    echo "Uses the existing identity/profile only; it never creates or modifies identities."
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ipa)
            IPA="${2:-}"; shift 2 ;;
        --profile)
            PROFILE_REFERENCE="${2:-}"; shift 2 ;;
        --identity)
            IDENTITY="${2:-}"; shift 2 ;;
        --output)
            OUTPUT="${2:-}"; shift 2 ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2 ;;
    esac
done

fail() {
    echo "error: $*" >&2
    exit 1
}

# Reads an entitlement by its exact flat key. Do not use plutil keypaths here:
# keys such as com.apple.developer.team-identifier contain dots but are flat.
flat_entitlement() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    entitlements = plistlib.load(handle)
value = entitlements.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

[ -n "$IPA" ] || fail "--ipa is required"
[ -n "$PROFILE_REFERENCE" ] || fail "--profile is required"
[ -n "$IDENTITY" ] || fail "--identity is required"
[ -f "$IPA" ] || fail "unsigned IPA not found: $IPA"

mkdir -p "$SCRATCH_DIR"
WORK_DIR="$(mktemp -d "$SCRATCH_DIR/sign.XXXXXX")"
cleanup() {
    if [ "${CANARY_KEEP_SIGN_WORK:-0}" = "1" ]; then
        echo "signing work kept at $WORK_DIR"
    else
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

if [ -f "$PROFILE_REFERENCE" ]; then
    PROFILE_PATH="$PROFILE_REFERENCE"
else
    PROFILE_PATH=""
    for directory in \
        "$HOME/Library/MobileDevice/Provisioning Profiles" \
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
        if [ -d "$directory" ]; then
            candidate="$(find "$directory" -maxdepth 1 -type f -iname "${PROFILE_REFERENCE}.mobileprovision" -print -quit 2>/dev/null || true)"
            if [ -n "$candidate" ]; then
                PROFILE_PATH="$candidate"
                break
            fi
        fi
    done
fi
[ -n "$PROFILE_PATH" ] && [ -f "$PROFILE_PATH" ] || fail "provisioning profile not found for reference (searched profile directories)"

if ! /usr/bin/security cms -D -i "$PROFILE_PATH" > "$WORK_DIR/profile.plist" 2>"$WORK_DIR/profile.err"; then
    fail "could not decode provisioning profile: $(cat "$WORK_DIR/profile.err")"
fi
if ! /usr/bin/plutil -extract Entitlements xml1 -o "$WORK_DIR/entitlements.plist" "$WORK_DIR/profile.plist" >/dev/null 2>&1; then
    fail "provisioning profile has no Entitlements dictionary"
fi

PROFILE_APP_ID="$(flat_entitlement "$WORK_DIR/entitlements.plist" application-identifier)"
[ -n "$PROFILE_APP_ID" ] || fail "profile entitlements have no application-identifier"

/usr/bin/python3 "$SCRIPT_DIR/prepare_signing.py" \
    --profile-plist "$WORK_DIR/profile.plist" \
    --identity "$IDENTITY" \
    --bundle-id "$BUNDLE_ID" \
    --output-entitlements "$WORK_DIR/canary-entitlements.plist" \
    > "$WORK_DIR/prepare-signing.json"
cat "$WORK_DIR/prepare-signing.json"

SIGNING_APP_ID="$(flat_entitlement "$WORK_DIR/canary-entitlements.plist" application-identifier)"
SIGNING_TEAM="$(flat_entitlement "$WORK_DIR/canary-entitlements.plist" com.apple.developer.team-identifier)"
[ -n "$SIGNING_APP_ID" ] || fail "minimal canary entitlements have no application-identifier"
[ -n "$SIGNING_TEAM" ] || fail "minimal canary entitlements have no team identifier"
[ "$SIGNING_APP_ID" = "$SIGNING_TEAM.$BUNDLE_ID" ] || fail "minimal canary application-identifier is not canonical"
SIGNING_KEY_COUNT="$(/usr/bin/plutil -convert json -o - "$WORK_DIR/canary-entitlements.plist" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[ "$SIGNING_KEY_COUNT" -le 3 ] || fail "minimal canary entitlements contain extra keys"
GET_TASK_ALLOW="$(flat_entitlement "$WORK_DIR/canary-entitlements.plist" get-task-allow)"
case "$GET_TASK_ALLOW" in
    true|YES|1) ;;
    *) fail "minimal canary entitlements do not carry get-task-allow=true" ;;
esac

/usr/bin/ditto -x -k "$IPA" "$WORK_DIR/ipa"
APP_COUNT="$(find "$WORK_DIR/ipa/Payload" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[ "$APP_COUNT" = "1" ] || fail "unsigned IPA must contain exactly one Payload/*.app"
APP="$(find "$WORK_DIR/ipa/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
HOST_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Info.plist" 2>/dev/null || true)"
[ "$HOST_BUNDLE_ID" = "$BUNDLE_ID" ] || fail "IPA host bundle ID is not $BUNDLE_ID"

NESTED_APPS="$(find "$APP" -mindepth 1 \( -name '*.app' -o -name '*.appex' \) -print -quit)"
[ -z "$NESTED_APPS" ] || fail "canary helper refuses nested apps/appex; found $NESTED_APPS"

XCTEST_COUNT="$(find "$APP/PlugIns" -maxdepth 1 -type d -name '*.xctest' | wc -l | tr -d ' ')"
[ "$XCTEST_COUNT" = "1" ] || fail "unsigned IPA must contain exactly one PlugIns/*.xctest"
XCTEST="$(find "$APP/PlugIns" -maxdepth 1 -type d -name '*.xctest' -print -quit)"
XCTEST_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$XCTEST/Info.plist" 2>/dev/null || true)"
[ "$XCTEST_ID" = "$HOST_BUNDLE_ID" ] || fail "xctest bundle ID does not align with host bundle ID"

cp "$PROFILE_PATH" "$APP/embedded.mobileprovision"

if [ -d "$APP/Frameworks" ]; then
    while IFS= read -r -d '' item; do
        /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$item"
    done < <(find "$APP/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
fi

# The upstream signer signs PlugIns/*.xctest without entitlements; the host
# process already carries get-task-allow from the app profile.
/usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$XCTEST"

/usr/bin/codesign --force --sign "$IDENTITY" \
    --entitlements "$WORK_DIR/canary-entitlements.plist" \
    --timestamp=none --generate-entitlement-der "$APP"

if [ -z "$OUTPUT" ]; then
    OUTPUT="$(dirname "$IPA")/BootstrapCanary-signed.ipa"
fi
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_DIR/ipa/Payload" "$OUTPUT"

/usr/bin/ditto -x -k "$OUTPUT" "$WORK_DIR/readback"
READBACK_APP="$(find "$WORK_DIR/readback/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
READBACK_XCTEST="$(find "$READBACK_APP/PlugIns" -maxdepth 1 -type d -name '*.xctest' -print -quit)"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$READBACK_APP" > "$WORK_DIR/codesign-verify.txt" 2>&1
/usr/bin/codesign --verify --strict --verbose=2 "$READBACK_XCTEST" >> "$WORK_DIR/codesign-verify.txt" 2>&1

/usr/bin/codesign -d --entitlements :- "$READBACK_APP" > "$WORK_DIR/signed-entitlements.plist" 2>/dev/null
SIGNED_APP_ID="$(flat_entitlement "$WORK_DIR/signed-entitlements.plist" application-identifier)"
SIGNED_TEAM="${SIGNED_APP_ID%%.*}"
[ "$SIGNED_APP_ID" = "$SIGNING_APP_ID" ] || fail "signed app application-identifier is not the canonical host identifier"
[ "$SIGNED_TEAM" = "$SIGNING_TEAM" ] || fail "signed app team identifier does not match the profile"

SIGNED_GET_TASK="$(flat_entitlement "$WORK_DIR/signed-entitlements.plist" get-task-allow)"
case "$SIGNED_GET_TASK" in
    true|YES|1) ;;
    *) fail "signed app does not carry get-task-allow=true" ;;
esac
SIGNED_KEY_COUNT="$(/usr/bin/plutil -convert json -o - "$WORK_DIR/signed-entitlements.plist" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[ "$SIGNED_KEY_COUNT" -le 3 ] || fail "signed app contains extra entitlements beyond the minimal canary set"
if /usr/bin/plutil -p "$WORK_DIR/signed-entitlements.plist" | grep -E 'networkextension|vpn\.api|keychain-access-groups|aps-environment|associated-domains' >/dev/null; then
    fail "signed app contains a non-canary entitlement"
fi

/usr/bin/security cms -D -i "$READBACK_APP/embedded.mobileprovision" > "$WORK_DIR/readback-profile.plist"
READBACK_PROFILE_APP_ID="$(/usr/bin/python3 - "$WORK_DIR/readback-profile.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    profile = plistlib.load(handle)
print((profile.get("Entitlements") or {}).get("application-identifier", ""))
PY
)"
[ "$READBACK_PROFILE_APP_ID" = "$PROFILE_APP_ID" ] || fail "signed IPA embedded profile does not match the supplied profile"

if /usr/bin/otool -L "$READBACK_APP/BootstrapCanary" | grep -E 'XCTest|XCTestCore|XCUIAutomation|XCTAutomationSupport' >/dev/null; then
    fail "signed host binary unexpectedly links a DDI XCTest framework"
fi

IPA_SHA256="$(/usr/bin/shasum -a 256 "$OUTPUT" | awk '{print $1}')"
IPA_BYTES="$(/usr/bin/stat -f%z "$OUTPUT")"
RESULT_PATH="$(dirname "$OUTPUT")/signing-result.json"
/usr/bin/python3 - "$OUTPUT" "$IPA_SHA256" "$IPA_BYTES" "$BUNDLE_ID" "$RESULT_PATH" <<'PY'
import json
import sys

output, sha256, size, bundle_id, result_path = sys.argv[1:6]
result = {
    "signed": True,
    "ipa": output,
    "ipaSHA256": sha256,
    "ipaBytes": int(size),
    "hostBundleIdentifier": bundle_id,
    "xctestBundleIdentifierAligned": True,
    "codesignDeepStrictVerify": "passed",
    "getTaskAllow": True,
    "profileAuthorizedBundleAndTeam": True,
    "embeddedProfileReadBackMatches": True,
    "hostLoadsNoXCTest": True,
    "xctestSignedWithoutEntitlements": True,
    "identityCertificateInProfile": True,
    "minimalEntitlementsOnly": True,
    "networkExtensionEntitlementsOmitted": True,
    "keychainGroupOmitted": True,
}
with open(result_path, "w", encoding="utf-8") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(json.dumps(result, indent=2, sort_keys=True))
PY

echo "signed IPA: $OUTPUT"
echo "sha256: $IPA_SHA256"
