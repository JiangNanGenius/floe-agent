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
    # rustup-init installs into ~/.cargo/bin; make it visible in this shell.
    export PATH="$HOME/.cargo/bin:$PATH"
    rustup target add aarch64-apple-ios aarch64-apple-ios-sim
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/floe-wheel-${FLOE_WHEEL_NAME}.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

curl --fail --location --retry 3 "$FLOE_WHEEL_SDIST_URL" --output "$stage/src.tar.gz"
actual="$(shasum -a 256 "$stage/src.tar.gz" | awk '{print $1}')"
test "$actual" = "$FLOE_WHEEL_SDIST_SHA256"

out_dir="$repo_root/ios-wheelhouse/out/$FLOE_WHEEL_NAME"
mkdir -p "$out_dir"

if [ "$FLOE_WHEEL_PURE" = "1" ]; then
    # Packages whose iOS build is pure Python anyway: build once on the host
    # in a controlled venv and require a universal py3-none-any wheel. The iOS
    # cibuildwheel testbed rejects pure output by design.
    python3 -m venv "$stage/venv"
    "$stage/venv/bin/pip" install --quiet --upgrade pip
    env $FLOE_WHEEL_ENV "$stage/venv/bin/python" -m pip wheel --no-deps \
        --wheel-dir "$stage/pure-out" "$stage/src.tar.gz"
    wheel="$(ls "$stage"/pure-out/*-none-any.whl 2>/dev/null || true)"
    if [ -z "$wheel" ]; then
        echo "error: expected a pure py3-none-any wheel for $FLOE_WHEEL_NAME" >&2
        ls "$stage/pure-out" >&2 || true
        exit 1
    fi
    # Smoke: install the wheel into the venv and run the package's checks.
    "$stage/venv/bin/pip" install --quiet "$wheel"
    FLOE_SMOKE_HOST=1 "$stage/venv/bin/python" "$repo_root/ios-wheelhouse/$FLOE_WHEEL_SMOKE"
    cp "$wheel" "$out_dir/"
    echo "pure wheel written to $out_dir"
    exit 0
fi

tar -xzf "$stage/src.tar.gz" -C "$stage"
source_dir="$stage/$FLOE_WHEEL_SDIST_DIR"
# Upstream sdists may carry their own [tool.cibuildwheel] tables written for a
# newer cibuildwheel than our pin (e.g. zstandard's cpython-freethreading
# enable group fails 4.2.1's parse before env overrides merge). We drive
# cibuildwheel entirely through CIBW_* env vars, so the sdist's own table is
# stripped after extraction.
python3 - "$source_dir/pyproject.toml" <<'PYEOF'
import re, sys
path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    raise SystemExit(0)
pattern = re.compile(r"(?ms)^\[tool\.cibuildwheel[^\]]*\].*?(?=^\[|\Z)")
stripped = pattern.sub("", text)
if stripped != text:
    open(path, "w", encoding="utf-8").write(stripped)
    print("stripped sdist-native [tool.cibuildwheel] config")
PYEOF
cp "$repo_root/ios-wheelhouse/$FLOE_WHEEL_SMOKE" "$source_dir/floe_wheel_smoke.py"

export CIBW_BUILD='cp313-ios_arm64_iphoneos cp313-ios_arm64_iphonesimulator'
export CIBW_XBUILD_TOOLS_IOS='ninja cmake'
export CIBW_ENVIRONMENT_IOS="$FLOE_WHEEL_ENV"
# Upstream sdists may carry their own [tool.cibuildwheel] config written for a
# newer cibuildwheel than our pin (e.g. zstandard's cpython-freethreading
# enable group). Our build fixes the exact target set via CIBW_BUILD; override
# the sdist's enable list with a valid no-op group instead of failing the
# parse (an empty value is treated as unset).
export CIBW_ENABLE='cpython-prerelease'
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
