#!/bin/bash
# Validate a tag against project.yml before any release build or GitHub write.
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-${GITHUB_REF_NAME:-}}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$ ]]; then
    echo "error: release tag must be SemVer in the form v1.2.3 or v1.2.3-beta.1 (received '$TAG')" >&2
    exit 1
fi
if ! git rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null; then
    echo "error: release tag '$TAG' does not exist in this checkout" >&2
    exit 1
fi
SOURCE_SHA="$(git rev-parse HEAD)"
TAG_SHA="$(git rev-parse "refs/tags/$TAG^{commit}")"
if [[ "$SOURCE_SHA" != "$TAG_SHA" ]]; then
    echo "error: checkout $SOURCE_SHA does not match release tag $TAG at $TAG_SHA" >&2
    exit 1
fi

# Same completeness requirement as FloeCoreTests' LocalizationCompletenessTests,
# but cheap enough to run before any build: JSON validity, dotted key
# namespaces, and non-empty en/zh-Hans values.
if ! python3 scripts/validate_localization_catalog.py FloeApp/Resources/Localizable.xcstrings; then
    echo "error: localization catalog completeness failed before build" >&2
    exit 1
fi

# Phase 2 (TinyEMU migration): no bundled native Python/Node may return to
# the project manifests; the IPA form of this audit runs after packaging.
if ! python3 scripts/audit_native_runtime_free.py --project; then
    echo "error: native Python/Node references returned to the project" >&2
    exit 1
fi

# The native Office framework is a separately compiled, pinned dependency.
# Fail before bootstrapping/building the App if its source changed without a
# matching rebuilt artifact. This is the same read-only check as bootstrap.
# The capability readout keeps the release log honest: a framework that only
# compiled and linked must never be presented as a device-qualified editor.
# For an Office-qualified release add `--require-release` to
# verify_office_app_embedding.py, which refuses every unproven capability.
python3 -B - <<'PY'
import sys
sys.path.insert(0, 'scripts')
from bootstrap_office_host import LOCK, checked_lock
lock, pin = checked_lock(LOCK)
from office_release_gates import capability_status
status = capability_status(pin)
for flag in status['unproven']:
    print(f'Office capability not proven by a device artifact: {flag}')
for failure in status['failures']:
    print(f'REJECTED Office capability claim: {failure}')
print('Office native source pin OK')
PY

setting() {
    local key="$1"
    awk -F': ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" {gsub(/[\"[:space:]]/, "", $2); print $2; exit}' project.yml
}

VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
BUNDLE_ID="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
if [[ -z "$VERSION" || -z "$BUILD" || -z "$BUNDLE_ID" || ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "error: version, integer build, and bundle identifier are required in project.yml" >&2
    exit 1
fi
if [[ "${TAG%%-beta.*}" != "v$VERSION" ]]; then
    echo "error: tag '$TAG' does not match MARKETING_VERSION '$VERSION'" >&2
    exit 1
fi

# App extensions must carry the same version/build as the containing app.
# Check every target, not only the first project.yml occurrence.
if ! awk -F': ' -v version="$VERSION" -v build="$BUILD" '
    $1 ~ /^[[:space:]]*MARKETING_VERSION$/ {
        gsub(/[\"[:space:]]/, "", $2); if ($2 != version) exit 1
    }
    $1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION$/ {
        gsub(/[\"[:space:]]/, "", $2); if ($2 != build) exit 1
    }
' project.yml; then
    echo "error: every app/extension target must use version $VERSION and build $BUILD" >&2
    exit 1
fi

# Reject stale checked-in Xcode metadata in the initial, dependency-free job.
# xcodegen's full consistency check still runs later after bootstrap.
if ! awk -F'=' -v version="$VERSION" -v build="$BUILD" '
    $1 ~ /^[[:space:]]*MARKETING_VERSION[[:space:]]*$/ {
        versions++; gsub(/[\";[:space:]]/, "", $2); if ($2 != version) mismatch=1
    }
    $1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*$/ {
        builds++; gsub(/[\";[:space:]]/, "", $2); if ($2 != build) mismatch=1
    }
    END { if (mismatch || !versions || !builds) exit 1 }
' FloeAgent.xcodeproj/project.pbxproj; then
    echo "error: generated Xcode project must match version $VERSION and build $BUILD; regenerate and commit it" >&2
    exit 1
fi

# Portable plist read: the lean release preflight runs on ubuntu-latest, where
# Apple's plutil does not exist. python3 plistlib reads the same XML/binary
# plists on macOS and Linux and is already required above.
SCREEN_SHARE_PLIST="FloeScreenShare/Info.plist"
SCREEN_SHARE_DISPLAY_NAME="$(python3 - "$SCREEN_SHARE_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

try:
    with Path(sys.argv[1]).open('rb') as stream:
        plist = plistlib.load(stream)
except Exception:
    plist = None
value = plist.get('CFBundleDisplayName') if isinstance(plist, dict) else None
sys.stdout.write(value.strip() if isinstance(value, str) else '')
PY
)"
if [[ -z "$SCREEN_SHARE_DISPLAY_NAME" ]]; then
    echo "error: $SCREEN_SHARE_PLIST must define a non-empty CFBundleDisplayName for App Store validation" >&2
    exit 1
fi

PREVIOUS_TAG="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 "${TAG}^" 2>/dev/null || true)"
if [[ -n "$PREVIOUS_TAG" ]]; then
    PREVIOUS_PROJECT="$(git show "$PREVIOUS_TAG:FloeAgent/project.yml" 2>/dev/null || true)"
    PREVIOUS_BUILD="$(awk -F': ' '$1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION$/ {gsub(/[\"[:space:]]/, "", $2); print $2; exit}' <<< "$PREVIOUS_PROJECT")"
    if [[ "$PREVIOUS_BUILD" =~ ^[0-9]+$ ]] && (( BUILD <= PREVIOUS_BUILD )); then
        echo "error: build $BUILD must be greater than $PREVIOUS_BUILD from $PREVIOUS_TAG" >&2
        exit 1
    fi
fi

echo "release preflight OK: $TAG (version $VERSION, build $BUILD)"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "tag=$TAG"
        echo "version=$VERSION"
        echo "build=$BUILD"
        echo "source_sha=$SOURCE_SHA"
        echo "bundle_id=$BUNDLE_ID"
        echo "previous_tag=$PREVIOUS_TAG"
        echo "asset_name=Floe-Agent-$VERSION-build$BUILD-unsigned.ipa"
    } >> "$GITHUB_OUTPUT"
fi
