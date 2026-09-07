#!/bin/bash
# Native CPython 3.13 iOS build experiment and release input gate.
# A wheel artifact alone is not app/runtime acceptance.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/floe-pandas.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
curl --fail --location --retry 3 \
  'https://files.pythonhosted.org/packages/be/4f/5f3422a2afec5ffc46308b79e53291365a93748b498ac2e58bead0197916/pandas-3.0.5.tar.gz' \
  --output "$stage/pandas.tar.gz"
actual="$(shasum -a 256 "$stage/pandas.tar.gz" | awk '{print $1}')"
test "$actual" = dca3734d6ab7c906e6730f0788b0a1dbb9f2467731f9711f77995c8e9d62d712
tar -xzf "$stage/pandas.tar.gz" -C "$stage"
cp "$repo_root/FloeAgent/scripts/test_native_pandas.py" "$stage/pandas-3.0.5/floe_pandas_smoke.py"
python "$repo_root/FloeAgent/scripts/prepare_pandas_ios.py" "$stage/pandas-3.0.5"
export CIBW_BUILD='cp313-ios_arm64_iphoneos cp313-ios_arm64_iphonesimulator'
export CIBW_XBUILD_TOOLS_IOS='ninja cmake'
# pip 26.2 separates isolated build constraints from runtime constraints.
export CIBW_ENVIRONMENT_IOS="PIP_EXTRA_INDEX_URL=https://pypi.anaconda.org/beeware/simple LDFLAGS=\"\" PIP_BUILD_CONSTRAINT=\"$repo_root/FloeAgent/scripts/pandas-ios-constraints.txt\" PIP_CONSTRAINT=\"$repo_root/FloeAgent/scripts/pandas-ios-constraints.txt\""
export CIBW_TEST_COMMAND='python -m floe_pandas_smoke'
export CIBW_TEST_SOURCES='floe_pandas_smoke.py'
export CIBW_TEST_EXTRAS=''
export CIBW_BUILD_VERBOSITY=1
cd "$stage/pandas-3.0.5"
python -m cibuildwheel --platform ios . --output-dir "$repo_root/pandas-wheelhouse"
