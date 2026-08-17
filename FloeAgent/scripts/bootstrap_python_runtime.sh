#!/bin/bash
# Install the pinned CPython 3.13 iOS runtime used by exec.localPython.
# The 40+ MB XCFramework and generated stdlib stay out of Git; the URL and
# digest below make the build input reproducible and auditable.
set -euo pipefail

cd "$(dirname "$0")/.."

archive_name="Python-3.13-iOS-support.b10.tar.gz"
runtime_url="https://github.com/beeware/Python-Apple-support/releases/download/3.13-b10/${archive_name}"
expected_sha256="1e6723176bcd6bb3217109bda763421ef090e6252dd21e3e9671df057427773b"
cache_dir="${TMPDIR:-/tmp}/floe-python-runtime-3.13-b10"
archive_path="${cache_dir}/${archive_name}"
extract_dir="${cache_dir}/extracted"

mkdir -p "$cache_dir"
if [ ! -f "$archive_path" ]; then
    curl --fail --location --retry 3 --output "$archive_path" "$runtime_url"
fi

actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "error: CPython archive SHA256 mismatch" >&2
    exit 1
fi

if [ ! -d "$extract_dir/Python.xcframework" ]; then
    mkdir -p "$extract_dir"
    tar -xzf "$archive_path" -C "$extract_dir"
fi

mkdir -p Vendor FloeApp/Resources
rsync -a --delete "$extract_dir/Python.xcframework/" Vendor/Python.xcframework/

# The Python source library is architecture independent. Keep the pure-Python
# standard library and omit tests, package installers, GUI stacks, virtualenv,
# and native .so modules (iOS requires native modules to be separately signed
# frameworks). There is intentionally no pip or dynamic download path.
stdlib_source="$extract_dir/Python.xcframework/ios-arm64/lib/python3.13"
stdlib_target="FloeApp/Resources/python/lib/python3.13"
mkdir -p "$stdlib_target"
rsync -a --delete \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude 'lib-dynload/' \
    --exclude 'site-packages/' \
    --exclude 'ensurepip/' \
    --exclude 'idlelib/' \
    --exclude 'test/' \
    --exclude 'tkinter/' \
    --exclude 'turtledemo/' \
    --exclude 'venv/' \
    "$stdlib_source/" "$stdlib_target/"

# project.yml embeds `python` as a folder reference, preserving CPython's
# canonical PYTHONHOME layout without flattening duplicate __init__.py files.
# Keep the pure-Python tree unpacked because iOS getpath initialization uses
# lib/python3.13 as its standard-library landmark.
rm -f "FloeApp/Resources/python/lib/python313.zip"

echo "Installed CPython 3.13-b10 runtime in Vendor/ and FloeApp/Resources/python"
