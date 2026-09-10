#!/bin/bash
# Build one ios-wheelhouse package into cp313 iOS wheels (device+simulator).
# A wheel artifact alone is not app/runtime acceptance: candidates are
# reviewed, published as an immutable GitHub Release, then SHA-256 pinned into
# install_python_binary_packages.sh. See ios-wheelhouse/README.md.
set -euo pipefail

package="${1:?usage: build_ios_wheel.sh <package from ios-wheelhouse/manifest.json>}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

eval "$(python3 "$(dirname "$0")/ios_wheelhouse.py" env "$package")"

if [ "$FLOE_WHEEL_RUST" = "1" ]; then
    # maturin/PyO3 cross link: rustup toolchains with the two iOS targets.
    if ! command -v rustup >/dev/null 2>&1; then
        brew install rustup
        rustup-init -y --default-toolchain stable
    fi
    rustup target add aarch64-apple-ios aarch64-apple-ios-sim
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/floe-wheel-${FLOE_WHEEL_NAME}.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

curl --fail --location --retry 3 "$FLOE_WHEEL_SDIST_URL" --output "$stage/src.tar.gz"
actual="$(shasum -a 256 "$stage/src.tar.gz" | awk '{print $1}')"
test "$actual" = "$FLOE_WHEEL_SDIST_SHA256"
tar -xzf "$stage/src.tar.gz" -C "$stage"
source_dir="$stage/$FLOE_WHEEL_SDIST_DIR"
cp "$repo_root/ios-wheelhouse/$FLOE_WHEEL_SMOKE" "$source_dir/floe_wheel_smoke.py"

export CIBW_BUILD='cp313-ios_arm64_iphoneos cp313-ios_arm64_iphonesimulator'
export CIBW_XBUILD_TOOLS_IOS='ninja cmake'
export CIBW_ENVIRONMENT_IOS="$FLOE_WHEEL_ENV"
export CIBW_TEST_COMMAND='python -m floe_wheel_smoke'
export CIBW_TEST_SOURCES='floe_wheel_smoke.py'
export CIBW_TEST_EXTRAS=''
export CIBW_BUILD_VERBOSITY=1
if [ "$FLOE_WHEEL_RUST" = "1" ]; then
    export CIBW_ENVIRONMENT_IOS="$CIBW_ENVIRONMENT_IOS PYO3_CROSS=1 CARGO_NET_GIT_FETCH_WITH_CLI=1"
fi

cd "$source_dir"
python -m cibuildwheel --platform ios . --output-dir "$repo_root/ios-wheelhouse/out/$FLOE_WHEEL_NAME"
echo "wheel candidates written to ios-wheelhouse/out/$FLOE_WHEEL_NAME"
