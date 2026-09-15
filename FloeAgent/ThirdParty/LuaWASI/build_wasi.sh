#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Build the pinned Lua interpreter to wasm32-wasip1 with try_table EH.
# Cloud dependency build, never a full local App build.
set -euo pipefail
task_root="${1:?absolute scratch directory required}"
mkdir -p "$task_root"
script_root="$(cd "$(dirname "$0")" && pwd)"
lock="$script_root/runtime.lock.json"

# Keep every extracted tree on a space-free path: make splits CC at spaces.
work="$task_root/work"
mkdir -p "$work"
python3 - "$lock" "$task_root" "$work" <<'PY'
import hashlib,json,sys,tarfile,urllib.request
from pathlib import Path
lock=json.loads(Path(sys.argv[1]).read_text()); root=Path(sys.argv[2]); work=Path(sys.argv[3])
def fetch(url, sha, dest):
    data=urllib.request.urlopen(url,timeout=600).read()
    assert hashlib.sha256(data).hexdigest()==sha, dest
    dest.write_bytes(data)
    with tarfile.open(dest) as tar: tar.extractall(work, filter='data')
fetch(lock['source'], lock['sha256'], root/'lua.tar.gz')
sdk=lock['wasiSdk']
fetch(sdk['source'], sdk['sha256'], root/'wasi-sdk.tar.gz')
PY

# Local checkouts may live below paths containing spaces; make cannot quote CC.
link_root="$(mktemp -d /tmp/floe-lua-wasi.XXXXXX)"
trap 'rm -rf "$link_root"' EXIT
ln -sfn "$work" "$link_root/work"
ln -sfn "$script_root/lua_wasi_cfg.h" "$link_root/lua_wasi_cfg.h"

lua_src="$link_root/work/lua-5.4.8"
sdk_dir="$(find -L "$link_root/work" -maxdepth 1 -type d -name 'wasi-sdk-*' | head -1)"
test -d "$lua_src" && test -n "$sdk_dir"
clang="$sdk_dir/bin/clang --sysroot=$sdk_dir/share/wasi-sysroot"
# Upstream Lua needs setjmp/longjmp for error recovery. wasi-sdk's SjLj only
# emits the final try_table encoding with this exact flag trio; the engine
# must implement the exception-handling proposal (WasmKit 0.3.1 does).
eh_flags="-fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false"
cfg="$link_root/lua_wasi_cfg.h"
"$sdk_dir/bin/clang" --sysroot="$sdk_dir/share/wasi-sysroot" -Os \
  -D_WASI_EMULATED_PROCESS_CLOCKS -include "$cfg" \
  -c "$script_root/lua_wasi_tmpfile.c" -o "$link_root/lua_wasi_tmpfile.o"
make -C "$lua_src" generic \
  CC="$clang" \
  AR="$sdk_dir/bin/llvm-ar rcu" RANLIB="$sdk_dir/bin/llvm-ranlib" \
  MYCFLAGS="-Os -DLUA_USE_C89 -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS $eh_flags -include $cfg" \
  MYLDFLAGS="-lwasi-emulated-signal -lwasi-emulated-process-clocks -lsetjmp $eh_flags" \
  MYLIBS="$link_root/lua_wasi_tmpfile.o" -j4
out="$task_root/evidence"
mkdir -p "$out"
cp "$lua_src/src/lua" "$task_root/lua.wasm"
cp "$lock" "$out/"
shasum -a 256 "$task_root/lua.wasm" > "$out/lua.wasm.sha256"
curl -fsSL https://www.lua.org/license.html -o "$out/Lua-LICENSE.html"
"$sdk_dir/bin/clang" --version > "$out/toolchain.txt"
printf 'built %s\n' "$task_root/lua.wasm"
