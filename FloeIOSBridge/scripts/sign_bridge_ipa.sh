#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_YML="${FLOE_BRIDGE_PROJECT:-$SCRIPT_DIR/../project.yml}"
HOST_ID="org.floeagent.iosbridge"
TUNNEL_ID="org.floeagent.iosbridge.tunnel"
CORE_ID="org.floeagent.iosbridge.core"
TEST_ID="org.floeagent.iosbridge"
IPA=""
HOST_PROFILE_REFERENCE=""
TUNNEL_PROFILE_REFERENCE=""
IDENTITY=""
OUTPUT=""
CHECK_ONLY=0
MODE="${FLOE_BRIDGE_SIGN_MODE:-}"
EXPECTED_VERSION=""
EXPECTED_BUILD=""
SOURCE_REF=""
SCRATCH_DIR="${FLOE_BRIDGE_SIGN_SCRATCH:-$REPO_ROOT/Local/Scratch/ios-bridge-1.0-20261101/signing}"

usage() {
    cat <<'USAGE'
usage: sign_bridge_ipa.sh --ipa <unsigned.ipa> --host-profile <path-or-uuid>
       --tunnel-profile <path-or-uuid> --identity <codesign identity>
       [--bundle-id <host-bundle-id>] [--output <signed.ipa>] [--check-only]
       [--project <project.yml>]
       [--mode qualification|product-qualification]
       [--expected-version <x.y.z>] [--expected-build <n>]
       [--source-ref <committed-ref>]

--mode defaults to the content policy derived from the trusted project source
(BridgeBuild.prototypeDiagnostics): the legacy Build 13 source selects
"qualification" and product content selects "product-qualification".
product-qualification accepts both canonical and explicit custom IDs; pass
--source-ref to bind the verification to frozen source. release is rejected
because public distribution IPAs must stay unsigned.

--bundle-id defaults to the existing canonical org.floeagent.iosbridge (so
current device upgrades are unchanged). A developer self-signing a public
build passes their own explicit reverse-DNS host ID; tunnel, core and xctest
IDs are derived as host+".tunnel", host+".core" and host respectively. The
profiles must authorize those exact IDs and both bundle Info.plists plus the
two nested BridgeCore copies are rewritten before signing. Executable bytes
and source constants are not patched.

Signs the single-app package inside-out:
  host/appex nested frameworks -> appex (its own profile) -> xctest (host id)
  -> host app (host profile).
It validates both profiles, certificate membership, team and bundle IDs, and
emits only the minimal NetworkExtension/Personal VPN/get-task-allow keys.
It never creates identities, changes accounts or writes device state.

The unsigned input is checked against the selected content policy before any
bundle-ID rewrite. The signed IPA is private qualification output; a public
release IPA must stay unsigned. After signing, the package is independently
re-opened and checked in the same mode with --allow-signed.
USAGE
}

fail() { echo "error: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ipa) IPA="${2:-}"; shift 2 ;;
        --host-profile) HOST_PROFILE_REFERENCE="${2:-}"; shift 2 ;;
        --tunnel-profile) TUNNEL_PROFILE_REFERENCE="${2:-}"; shift 2 ;;
        --identity) IDENTITY="${2:-}"; shift 2 ;;
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --project) PROJECT_YML="${2:-}"; shift 2 ;;
        --bundle-id) HOST_ID="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --expected-version) EXPECTED_VERSION="${2:-}"; shift 2 ;;
        --expected-build) EXPECTED_BUILD="${2:-}"; shift 2 ;;
        --source-ref) SOURCE_REF="${2:-}"; shift 2 ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

case "$MODE" in
    "") ;;
    qualification) ;;
    product-qualification) ;;
    release) fail "public release IPAs must remain unsigned; use product-qualification for private product content" ;;
    *) fail "mode must be qualification, product-qualification or release" ;;
esac

[ -f "$PROJECT_YML" ] || fail "project source not found: $PROJECT_YML"
if [ -z "$MODE" ]; then
    DERIVE_ARGS=(--derive-mode --project "$PROJECT_YML")
    [ -n "$SOURCE_REF" ] && DERIVE_ARGS+=(--source-ref "$SOURCE_REF")
    MODE="$(/usr/bin/python3 -B "$SCRIPT_DIR/verify_bridge.py" "${DERIVE_ARGS[@]}")" \
        || fail "could not derive signing mode from trusted project source"
    case "$MODE" in
        qualification|product-qualification) ;;
        *) fail "trusted project source produced an unexpected mode: $MODE" ;;
    esac
    echo "== derived signing mode from trusted source: $MODE =="
fi
if [ -n "$OUTPUT" ]; then
    case "$(basename "$OUTPUT")" in
        Floe-iOS-Bridge-*-unsigned.ipa)
            fail "refusing to write a signed IPA with a public release filename: $OUTPUT"
            ;;
    esac
fi

BUNDLE_IDS_JSON="$(/usr/bin/python3 -B "$SCRIPT_DIR/prepare_signing.py" --derive-only --bundle-id "$HOST_ID")" \
    || fail "invalid --bundle-id"
TUNNEL_ID="$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["tunnel"])' <<<"$BUNDLE_IDS_JSON")"
CORE_ID="$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["core"])' <<<"$BUNDLE_IDS_JSON")"
TEST_ID="$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["test"])' <<<"$BUNDLE_IDS_JSON")"

[ -n "$IPA" ] || fail "--ipa is required"
[ -n "$HOST_PROFILE_REFERENCE" ] || fail "--host-profile is required"
[ -n "$TUNNEL_PROFILE_REFERENCE" ] || fail "--tunnel-profile is required"
[ -n "$IDENTITY" ] || fail "--identity is required"
[ -f "$IPA" ] || fail "unsigned IPA not found: $IPA"

mkdir -p "$SCRATCH_DIR"
WORK_DIR="$(mktemp -d "$SCRATCH_DIR/sign.XXXXXX")"
cleanup() {
    if [ "${FLOE_BRIDGE_KEEP_SIGN_WORK:-0}" = "1" ]; then
        echo "signing work kept at $WORK_DIR"
    else
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

resolve_profile() {
    local reference="$1"
    if [ -f "$reference" ]; then
        printf '%s\n' "$reference"
        return 0
    fi
    local directory candidate
    for directory in \
        "$HOME/Library/MobileDevice/Provisioning Profiles" \
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
        if [ -d "$directory" ]; then
            candidate="$(find "$directory" -maxdepth 1 -type f -iname "${reference}.mobileprovision" -print -quit 2>/dev/null || true)"
            if [ -n "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

HOST_PROFILE="$(resolve_profile "$HOST_PROFILE_REFERENCE")" || fail "host profile not found"
TUNNEL_PROFILE="$(resolve_profile "$TUNNEL_PROFILE_REFERENCE")" || fail "tunnel profile not found"

/usr/bin/security cms -D -i "$HOST_PROFILE" > "$WORK_DIR/host-profile.plist" 2>"$WORK_DIR/host-profile.err" \
    || fail "could not decode host profile: $(cat "$WORK_DIR/host-profile.err")"
/usr/bin/security cms -D -i "$TUNNEL_PROFILE" > "$WORK_DIR/tunnel-profile.plist" 2>"$WORK_DIR/tunnel-profile.err" \
    || fail "could not decode tunnel profile: $(cat "$WORK_DIR/tunnel-profile.err")"

/usr/bin/python3 "$SCRIPT_DIR/prepare_signing.py" \
    --host-profile-plist "$WORK_DIR/host-profile.plist" \
    --tunnel-profile-plist "$WORK_DIR/tunnel-profile.plist" \
    --identity "$IDENTITY" \
    --bundle-id "$HOST_ID" \
    --output-dir "$WORK_DIR" | tee "$WORK_DIR/prepare-signing.json"

HOST_ENTITLEMENTS="$WORK_DIR/host-entitlements.plist"
TUNNEL_ENTITLEMENTS="$WORK_DIR/tunnel-entitlements.plist"
[ -f "$HOST_ENTITLEMENTS" ] || fail "host entitlement plist was not produced"
[ -f "$TUNNEL_ENTITLEMENTS" ] || fail "tunnel entitlement plist was not produced"

flat_entitlement() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    value = plistlib.load(handle).get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

HOST_APP_ID="$(flat_entitlement "$HOST_ENTITLEMENTS" application-identifier)"
TUNNEL_APP_ID="$(flat_entitlement "$TUNNEL_ENTITLEMENTS" application-identifier)"
HOST_TEAM="$(flat_entitlement "$HOST_ENTITLEMENTS" com.apple.developer.team-identifier)"
TUNNEL_TEAM="$(flat_entitlement "$TUNNEL_ENTITLEMENTS" com.apple.developer.team-identifier)"
[ "$HOST_APP_ID" = "$HOST_TEAM.$HOST_ID" ] || fail "host application-identifier is not canonical"
[ "$TUNNEL_APP_ID" = "$TUNNEL_TEAM.$TUNNEL_ID" ] || fail "tunnel application-identifier is not canonical"
[ "$HOST_TEAM" = "$TUNNEL_TEAM" ] || fail "host and tunnel teams differ"

/usr/bin/python3 - "$HOST_ENTITLEMENTS" "$TUNNEL_ENTITLEMENTS" <<'PY'
import plistlib, sys
host = plistlib.load(open(sys.argv[1], "rb"))
tunnel = plistlib.load(open(sys.argv[2], "rb"))
expected_host = {
    "application-identifier", "com.apple.developer.team-identifier", "get-task-allow",
    "com.apple.developer.networking.vpn.api", "com.apple.developer.networking.networkextension",
}
expected_tunnel = {
    "application-identifier", "com.apple.developer.team-identifier", "get-task-allow",
    "com.apple.developer.networking.networkextension",
}
if set(host) != expected_host:
    raise SystemExit(f"host entitlement keys are not minimal: {sorted(host)}")
if set(tunnel) != expected_tunnel:
    raise SystemExit(f"tunnel entitlement keys are not minimal: {sorted(tunnel)}")
if host.get("com.apple.developer.networking.vpn.api") != ["allow-vpn"]:
    raise SystemExit("host vpn.api is not the single allow-vpn value")
if host.get("com.apple.developer.networking.networkextension") != ["packet-tunnel-provider"]:
    raise SystemExit("host networkextension is not the single packet-tunnel-provider value")
if tunnel.get("com.apple.developer.networking.networkextension") != ["packet-tunnel-provider"]:
    raise SystemExit("tunnel networkextension is not the single packet-tunnel-provider value")
if host.get("get-task-allow") is not True or tunnel.get("get-task-allow") is not True:
    raise SystemExit("development get-task-allow is missing")
PY

/usr/bin/ditto -x -k "$IPA" "$WORK_DIR/ipa"
APP_COUNT="$(find "$WORK_DIR/ipa/Payload" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[ "$APP_COUNT" = "1" ] || fail "unsigned IPA must contain exactly one Payload/*.app"
APP="$(find "$WORK_DIR/ipa/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"

echo "== pre-sign content policy verification ($MODE) =="
PRE_VERIFY_ARGS=(--app "$APP" --mode "$MODE" --project "$PROJECT_YML")
[ -n "$EXPECTED_VERSION" ] && PRE_VERIFY_ARGS+=(--expected-version "$EXPECTED_VERSION")
[ -n "$EXPECTED_BUILD" ] && PRE_VERIFY_ARGS+=(--expected-build "$EXPECTED_BUILD")
[ -n "$SOURCE_REF" ] && PRE_VERIFY_ARGS+=(--source-ref "$SOURCE_REF")
if ! /usr/bin/python3 -B "$SCRIPT_DIR/verify_bridge.py" "${PRE_VERIFY_ARGS[@]}" \
        > "$WORK_DIR/pre-sign-verify.txt" 2>&1; then
    cat "$WORK_DIR/pre-sign-verify.txt" >&2
    fail "unsigned input does not satisfy the $MODE content policy; nothing was signed"
fi

echo "== rewriting explicit bundle identifiers before signing =="
/usr/bin/python3 -B "$SCRIPT_DIR/prepare_signing.py" \
    --apply-bundle-ids --app "$APP" --bundle-id "$HOST_ID" \
    | tee "$WORK_DIR/bundle-ids.json"

[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Info.plist")" = "$HOST_ID" ] \
    || fail "IPA host bundle ID is not $HOST_ID"
NESTED_APPS="$(find "$APP" -mindepth 1 -name '*.app' -print -quit)"
[ -z "$NESTED_APPS" ] || fail "unexpected nested .app: $NESTED_APPS"
APPEX_COUNT="$(find "$APP/PlugIns" -maxdepth 1 -type d -name '*.appex' | wc -l | tr -d ' ')"
[ "$APPEX_COUNT" = "1" ] || fail "unsigned IPA must contain exactly one PlugIns/*.appex"
APPEX="$(find "$APP/PlugIns" -maxdepth 1 -type d -name '*.appex' -print -quit)"
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APPEX/Info.plist")" = "$TUNNEL_ID" ] \
    || fail "appex bundle ID is not $TUNNEL_ID"
HOST_CORE="$APP/Frameworks/BridgeCore.framework"
APPEX_CORE="$APPEX/Frameworks/BridgeCore.framework"
[ -f "$HOST_CORE/Info.plist" ] || fail "host BridgeCore Info.plist is missing"
[ -f "$APPEX_CORE/Info.plist" ] || fail "appex BridgeCore Info.plist is missing"
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$HOST_CORE/Info.plist")" = "$CORE_ID" ] \
    || fail "host BridgeCore bundle ID is not $CORE_ID"
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APPEX_CORE/Info.plist")" = "$CORE_ID" ] \
    || fail "appex BridgeCore bundle ID is not $CORE_ID"
XCTEST_COUNT="$(find "$APP/PlugIns" -maxdepth 1 -type d -name '*.xctest' | wc -l | tr -d ' ')"
[ "$XCTEST_COUNT" = "1" ] || fail "unsigned IPA must contain exactly one PlugIns/*.xctest"
XCTEST="$(find "$APP/PlugIns" -maxdepth 1 -type d -name '*.xctest' -print -quit)"
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$XCTEST/Info.plist")" = "$TEST_ID" ] \
    || fail "xctest bundle ID does not align with host bundle ID"
if /usr/bin/otool -L "$APP/BridgeHost" | grep -E 'XCTest|XCTestCore|XCUIAutomation|XCTAutomationSupport' >/dev/null; then
    fail "unsigned host unexpectedly links a DDI XCTest framework"
fi

if [ "$CHECK_ONLY" = "1" ]; then
    /usr/bin/python3 - "$APP" "$APPEX" "$XCTEST" "$WORK_DIR" "$HOST_ID" "$TUNNEL_ID" "$CORE_ID" "$TEST_ID" <<'PY'
import json, os, sys
app, appex, xctest, work, host_id, tunnel_id, core_id, test_id = sys.argv[1:9]
print(json.dumps({
    "checkOnly": True,
    "hostBundle": app,
    "appex": appex,
    "xctest": xctest,
    "bundleIds": {
        "host": host_id,
        "tunnel": tunnel_id,
        "core": core_id,
        "test": test_id,
    },
    "hostEntitlements": os.path.join(work, "host-entitlements.plist"),
    "tunnelEntitlements": os.path.join(work, "tunnel-entitlements.plist"),
    "signed": False,
}, indent=2, sort_keys=True))
PY
    exit 0
fi

cp "$HOST_PROFILE" "$APP/embedded.mobileprovision"
cp "$TUNNEL_PROFILE" "$APPEX/embedded.mobileprovision"

echo "== signing appex nested frameworks =="
if [ -d "$APPEX/Frameworks" ]; then
    while IFS= read -r -d '' item; do
        /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$item"
    done < <(find "$APPEX/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
fi

echo "== signing appex with its own profile =="
/usr/bin/codesign --force --sign "$IDENTITY" \
    --entitlements "$TUNNEL_ENTITLEMENTS" \
    --timestamp=none --generate-entitlement-der "$APPEX"

echo "== signing host nested frameworks =="
if [ -d "$APP/Frameworks" ]; then
    while IFS= read -r -d '' item; do
        /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$item"
    done < <(find "$APP/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
fi

echo "== signing xctest with host id (no entitlements) =="
/usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$XCTEST"

echo "== signing host app with host profile =="
/usr/bin/codesign --force --sign "$IDENTITY" \
    --entitlements "$HOST_ENTITLEMENTS" \
    --timestamp=none --generate-entitlement-der "$APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" > "$WORK_DIR/codesign-verify.txt" 2>&1
/usr/bin/codesign --verify --strict --verbose=2 "$APPEX" >> "$WORK_DIR/codesign-verify.txt" 2>&1
/usr/bin/codesign --verify --strict --verbose=2 "$XCTEST" >> "$WORK_DIR/codesign-verify.txt" 2>&1

/usr/bin/codesign -d --entitlements :- "$APP" > "$WORK_DIR/signed-host-entitlements.plist" 2>/dev/null
/usr/bin/codesign -d --entitlements :- "$APPEX" > "$WORK_DIR/signed-tunnel-entitlements.plist" 2>/dev/null
/usr/bin/python3 - "$WORK_DIR/signed-host-entitlements.plist" "$WORK_DIR/signed-tunnel-entitlements.plist" \
    "$HOST_APP_ID" "$TUNNEL_APP_ID" <<'PY'
import plistlib, sys
host = plistlib.load(open(sys.argv[1], "rb"))
tunnel = plistlib.load(open(sys.argv[2], "rb"))
if host.get("application-identifier") != sys.argv[3]:
    raise SystemExit("signed host application-identifier readback mismatch")
if tunnel.get("application-identifier") != sys.argv[4]:
    raise SystemExit("signed appex application-identifier readback mismatch")
if "com.apple.developer.networking.vpn.api" not in host:
    raise SystemExit("signed host lost the Personal VPN entitlement")
if host.get("com.apple.developer.networking.networkextension") != ["packet-tunnel-provider"]:
    raise SystemExit("signed host NetworkExtension entitlement mismatch")
if tunnel.get("com.apple.developer.networking.networkextension") != ["packet-tunnel-provider"]:
    raise SystemExit("signed appex NetworkExtension entitlement mismatch")
if "com.apple.developer.networking.vpn.api" in tunnel:
    raise SystemExit("signed appex carries an unnecessary Personal VPN entitlement")
PY

/usr/bin/security cms -D -i "$APP/embedded.mobileprovision" > "$WORK_DIR/host-readback.plist"
/usr/bin/security cms -D -i "$APPEX/embedded.mobileprovision" > "$WORK_DIR/tunnel-readback.plist"
/usr/bin/python3 - "$WORK_DIR/host-readback.plist" "$WORK_DIR/tunnel-readback.plist" \
    "$WORK_DIR/host-profile.plist" "$WORK_DIR/tunnel-profile.plist" <<'PY'
import plistlib, sys
def app_id(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle).get("Entitlements", {}).get("application-identifier")
if app_id(sys.argv[1]) != app_id(sys.argv[3]):
    raise SystemExit("host embedded profile does not match the supplied host profile")
if app_id(sys.argv[2]) != app_id(sys.argv[4]):
    raise SystemExit("appex embedded profile does not match the supplied tunnel profile")
PY

if [ -z "$OUTPUT" ]; then
    if [ "$MODE" = "product-qualification" ]; then
        OUTPUT="$(dirname "$IPA")/FloeBridge-product-signed.ipa"
    else
        OUTPUT="$(dirname "$IPA")/FloeBridge-signed.ipa"
    fi
fi
case "$(basename "$OUTPUT")" in
    Floe-iOS-Bridge-*-unsigned.ipa)
        fail "refusing to write a signed IPA with a public release filename: $OUTPUT"
        ;;
esac
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_DIR/ipa/Payload" "$OUTPUT"

/usr/bin/ditto -x -k "$OUTPUT" "$WORK_DIR/readback"
READBACK_APP="$(find "$WORK_DIR/readback/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$READBACK_APP" >> "$WORK_DIR/codesign-verify.txt" 2>&1
if /usr/bin/otool -L "$READBACK_APP/BridgeHost" | grep -E 'XCTest|XCTestCore|XCUIAutomation|XCTAutomationSupport' >/dev/null; then
    fail "signed host links a DDI XCTest framework"
fi

VERIFY_ARGS=(--ipa "$OUTPUT" --allow-signed --mode "$MODE" --project "$PROJECT_YML" --bundle-id "$HOST_ID")
[ -n "$EXPECTED_VERSION" ] && VERIFY_ARGS+=(--expected-version "$EXPECTED_VERSION")
[ -n "$EXPECTED_BUILD" ] && VERIFY_ARGS+=(--expected-build "$EXPECTED_BUILD")
[ -n "$SOURCE_REF" ] && VERIFY_ARGS+=(--source-ref "$SOURCE_REF")
/usr/bin/python3 -B "$SCRIPT_DIR/verify_bridge.py" "${VERIFY_ARGS[@]}" > "$WORK_DIR/verify-signed.txt"

IPA_SHA256="$(/usr/bin/shasum -a 256 "$OUTPUT" | awk '{print $1}')"
IPA_BYTES="$(/usr/bin/stat -f%z "$OUTPUT")"
RESULT_PATH="$(dirname "$OUTPUT")/signing-result.json"
/usr/bin/python3 - "$OUTPUT" "$IPA_SHA256" "$IPA_BYTES" "$HOST_ID" "$TUNNEL_ID" "$CORE_ID" "$TEST_ID" "$RESULT_PATH" "$MODE" <<'PY'
import json, sys
output, sha256, size, host_id, tunnel_id, core_id, test_id, result_path, mode = sys.argv[1:10]
result = {
    "signed": True,
    "mode": mode,
    "artifactIntent": "private-qualification",
    "publicDistribution": False,
    "ipa": output,
    "ipaSHA256": sha256,
    "ipaBytes": int(size),
    "hostBundleIdentifier": host_id,
    "tunnelBundleIdentifier": tunnel_id,
    "coreBundleIdentifier": core_id,
    "testBundleIdentifier": test_id,
    "singleTopLevelApp": True,
    "exactlyOneAppex": True,
    "exactlyOneXctest": True,
    "appexSignedWithTunnelProfile": True,
    "hostSignedWithHostProfile": True,
    "xctestSignedWithHostIdentityAndId": True,
    "codesignDeepStrictVerify": "passed",
    "hostNoXCTestLoad": True,
    "minimalHostEntitlements": True,
    "minimalTunnelEntitlements": True,
    "embeddedProfilesReadBackMatch": True,
    "packageVerification": "passed",
}
with open(result_path, "w", encoding="utf-8") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(json.dumps(result, indent=2, sort_keys=True))
PY

echo "mode: $MODE (private qualification; not a public distribution artifact)"
echo "signed IPA: $OUTPUT"
echo "sha256: $IPA_SHA256"
