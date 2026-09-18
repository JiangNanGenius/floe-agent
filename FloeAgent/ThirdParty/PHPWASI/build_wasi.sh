#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Build the pinned PHP 8.2.33 CGI/CLI interpreter to wasm32-wasi.
#
# PHP 8.2 is in security support until 2026-12-31; 8.2.33 is the current
# security release. The vendored patch series is the VMware Labs 8.2.6 WASI
# port replayed onto 8.2.33 (see patches/ and runtime.lock.json).
#
# This is a cloud/CI dependency build, never a local App build, and it is
# compilepending work: it produces an artifact and evidence. It never signs,
# publishes or modifies the capability catalog.
#
# Prerequisites (ubuntu runners): build-essential autoconf automake libtool
# bison re2c pkg-config curl git patch; optional: binaryen (wasm-opt).
# The script downloads the pinned wasi-sdk 20.0 asset and verifies its SHA-256
# before use; every vendored patch is digest-checked before application.
set -euo pipefail
task_root="${1:?absolute scratch directory required}"
mkdir -p "$task_root"
script_root="$(cd "$(dirname "$0")" && pwd)"
lock="$script_root/runtime.lock.json"

work="$task_root/work"
mkdir -p "$work"
python3 - "$lock" "$task_root" "$work" <<'PY'
import hashlib, json, sys, tarfile, urllib.request
from pathlib import Path
lock = json.loads(Path(sys.argv[1]).read_text())
root, work = Path(sys.argv[2]), Path(sys.argv[3])

def fetch(url, sha, destination):
    request = urllib.request.Request(url, headers={'User-Agent': 'floe-phpwasi-build'})
    data = urllib.request.urlopen(request, timeout=900).read()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == sha, f'{url} sha256 {digest} != pinned {sha}'
    destination.write_bytes(data)

fetch(lock['source']['url'], lock['source']['sha256'], root / 'php-src.tar.gz')
fetch(lock['wasiSdk']['url'], lock['wasiSdk']['sha256'], root / 'wasi-sdk.tar.gz')
for archive, target in ((root / 'php-src.tar.gz', work), (root / 'wasi-sdk.tar.gz', work)):
    with tarfile.open(archive) as tar:
        tar.extractall(target, filter='data')
print('verified php-src and wasi-sdk 20.0 pins')
PY

sdk_dir="$(find -L "$work" -maxdepth 1 -type d -name 'wasi-sdk-*' | head -1)"
src_dir="$(find -L "$work" -maxdepth 1 -type d -name 'php-8.2.*' | head -1)"
test -d "$sdk_dir" && test -d "$src_dir" && echo "sdk=$sdk_dir source=$src_dir"

# Apply the pinned patch series in filename order and verify each patch digest.
(cd "$src_dir"
 if command -v git >/dev/null && [ ! -d .git ]; then git init -q; fi
 for patch in "$script_root"/patches/*.patch; do
   name="$(basename "$patch")"
   expected="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['patches']['files'][sys.argv[2]])" "$lock" "$name")"
   actual="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$patch")"
   [ "$actual" = "$expected" ] || { echo "patch digest mismatch: $name" >&2; exit 1; }
   if git apply --check "$patch" 2>/dev/null; then git apply "$patch"
   else patch -p1 --batch --forward < "$patch"; fi
 done
 echo "applied $(ls "$script_root"/patches/*.patch | wc -l | tr -d ' ') pinned patches")

export WASI_SYSROOT="$sdk_dir/share/wasi-sysroot"
export CC="$sdk_dir/bin/clang --sysroot=$WASI_SYSROOT"
export CFLAGS="-O2 --sysroot=${WASI_SYSROOT} -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_POSIX_SOURCE=1 -D_GNU_SOURCE=1 -DHAVE_FORK=0 -DWASM_WASI"
export LDFLAGS="--sysroot=${WASI_SYSROOT} -lwasi-emulated-getpid -lwasi-emulated-signal -lwasi-emulated-process-clocks -Wno-unused-command-line-argument"

cd "$src_dir"
./buildconf --force
./configure \
  --host=wasm32-wasi host_alias=wasm32-musl-wasi \
  --target=wasm32-wasi target_alias=wasm32-musl-wasi \
  --without-iconv --without-openssl --without-pear \
  --disable-phar --disable-opcache --disable-zend-signals \
  --without-pcre-jit --disable-fiber-asm
# The CLI SAPI is the preferred interpreter (CGI stdin requires request
# environment variables). Build CGI as a fallback and keep whatever the
# toolchain accepts; at least one artifact must exist.
make -j"${FLOE_BUILD_JOBS:-4}" cli || true
make -j"${FLOE_BUILD_JOBS:-4}" cgi || true

out="$task_root/evidence"
mkdir -p "$out"
wasm_opt="$(command -v wasm-opt || true)"
prepare() {
  local source_binary="$1" destination="$2"
  if [ -n "$wasm_opt" ]; then wasm-opt -O3 -o "$destination" "$source_binary"
  else cp "$source_binary" "$destination"; fi
}
if [ -x sapi/cli/php ]; then prepare sapi/cli/php "$task_root/php.wasm"; fi
if [ -x sapi/cgi/php-cgi ]; then prepare sapi/cgi/php-cgi "$task_root/php-cgi.wasm"; fi
test -f "$task_root/php.wasm" -o -f "$task_root/php-cgi.wasm" || { echo 'no PHP wasm artifact was produced' >&2; exit 1; }

cp "$lock" "$out/"
(cd "$task_root" && for artifact in php.wasm php-cgi.wasm; do
  [ -f "$artifact" ] && python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest(), sys.argv[1])" "$artifact"
done > "$out/php.wasm.sha256")
cp "$script_root"/patches/*.patch "$out/"
"$sdk_dir/bin/clang" --version > "$out/toolchain.txt"
printf '%s\n' "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['wasiSdk']['version'])" "$lock")" > "$out/wasi-sdk-version.txt"
curl -fsSL https://www.php.net/license/3_01.txt -o "$out/PHP-LICENSE-3.01.txt" || true
printf 'built %s\n' "$task_root"/php*.wasm
