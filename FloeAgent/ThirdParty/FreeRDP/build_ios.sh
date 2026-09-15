#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Dedicated cloud dependency build, never a full local App build.
set -euo pipefail
platform="${1:?OS64 or SIMULATORARM64 required}"
case "$platform" in OS64|SIMULATORARM64) ;; *) exit 2 ;; esac
task_root="${2:?absolute scratch directory required}"
mkdir -p "$task_root"
script_root="$(cd "$(dirname "$0")" && pwd)"
python3 - "$script_root/runtime.lock.json" "$task_root" <<'PY'
import hashlib,json,sys,tarfile,urllib.request
from pathlib import Path
lock=json.loads(Path(sys.argv[1]).read_text()); root=Path(sys.argv[2])
data=urllib.request.urlopen(lock['source'],timeout=120).read()
assert hashlib.sha256(data).hexdigest()==lock['sha256']
archive=root/'freerdp.tar.gz';archive.write_bytes(data)
with tarfile.open(archive) as tar:tar.extractall(root,filter='data')
source=root/('freerdp-'+lock['version'])
# Upstream's iOS superbuild creates shared libraries for its standalone App.
# Floe consumes reviewed static dependencies and supplies its own small bridge.
p=source/'client/iOS/cmake/ExternalDeps.cmake';s=p.read_text()
assert s.count('-DBUILD_SHARED_LIBS:BOOL=ON')==1
s=s.replace('-DBUILD_SHARED_LIBS:BOOL=ON','-DBUILD_SHARED_LIBS:BOOL=OFF')
# Upstream enables IPO/LTO whenever the compiler supports it. Apple Clang then
# emits LLVM bitcode archive members, which xcodebuild -create-xcframework
# rejects ("Unknown header: 0xb17c0de"). Propagate a plain Mach-O object build
# to every ExternalProject sub-build.
anchor='    -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD}\n)\n\nset(IOS_CMAKE_CACHE_ARGS)'
assert s.count(anchor)==1
s=s.replace(anchor,'    -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD}\n)\nlist(APPEND IOS_CMAKE_ARGS -DCMAKE_INTERPROCEDURAL_OPTIMIZATION:BOOL=OFF)\n\nset(IOS_CMAKE_CACHE_ARGS)')
p.write_text(s)
p=source/'client/iOS/cmake/ExternalOpenSSL.cmake';s=p.read_text()
assert 'make -j build_sw' in s
s=s.replace('make -j build_sw','make -j2 build_sw')
s=s.replace('COMMAND xcode-select -print-path','COMMAND xcrun --find clang')
# Resolve the requested per-command developer directory; never change the host.
import os
developer=os.environ['DEVELOPER_DIR']
start=s.index('execute_process(COMMAND xcrun --find clang')
end=s.index('\n',start)
s=s[:start]+'set(_xcode_dev "'+developer+'")'+s[end:]
p.write_text(s)
versions=(source/'cmake/DepVersions.cmake').read_text()
assert 'openssl-'+lock['openssl']['version'] in versions
assert lock['openssl']['sha256'] in versions
PY
source_root="$task_root/freerdp-3.31.1"
cmake -S "$source_root/client/iOS" -B "$task_root/build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$source_root/cmake/ios.toolchain.cmake" \
  -DPLATFORM="$platform" -DDEPLOYMENT_TARGET=26.0 -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION:BOOL=OFF \
  -DWITH_FFMPEG=OFF -DWITH_OPENH264=OFF -DWITH_CJSON=OFF -DWITH_OPUS=OFF \
  -DWITH_PNG=OFF -DWITH_WEBP=OFF -DWITH_JPEG=OFF -DWITH_URIPARSER=OFF
cmake --build "$task_root/build" --target freerdp --parallel 2
mkdir -p "$task_root/evidence"
cp "$script_root/runtime.lock.json" "$task_root/evidence/"
cp "$source_root/LICENSE" "$task_root/evidence/FreeRDP-LICENSE"
cp "$task_root/build/external/openssl/LICENSE.txt" "$task_root/evidence/OpenSSL-LICENSE"
find "$task_root/build/deps" -type f -name '*.a' -exec shasum -a 256 '{}' \; > "$task_root/evidence/library-hashes.txt"
xcrun clang --version > "$task_root/evidence/toolchain.txt"
