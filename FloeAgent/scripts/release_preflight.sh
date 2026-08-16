#!/bin/bash
# Validate a tag against project.yml before any release build or GitHub write.
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-${GITHUB_REF_NAME:-}}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: release tag must be SemVer in the form v1.2.3 (received '$TAG')" >&2
    exit 1
fi
if ! git rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null; then
    echo "error: release tag '$TAG' does not exist in this checkout" >&2
    exit 1
fi

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
if [[ "$TAG" != "v$VERSION" ]]; then
    echo "error: tag '$TAG' does not match MARKETING_VERSION '$VERSION'" >&2
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
        echo "bundle_id=$BUNDLE_ID"
        echo "previous_tag=$PREVIOUS_TAG"
        echo "asset_name=Floe-Agent-$VERSION-build$BUILD-unsigned.ipa"
    } >> "$GITHUB_OUTPUT"
fi
