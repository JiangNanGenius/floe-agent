#!/bin/bash
# SPDX-License-Identifier: MIT
# Fetch and verify the pinned upstream ruby.wasm release module.
#
# This is a cloud/CI dependency fetch, never a local App build, and it is
# compilepending work: it produces an artifact and evidence. It never signs,
# publishes or modifies the capability catalog.
#
# Usage: fetch_runtime.sh <absolute scratch directory>
set -euo pipefail
task_root="${1:?absolute scratch directory required}"
mkdir -p "$task_root"
script_root="$(cd "$(dirname "$0")" && pwd)"
lock="$script_root/runtime.lock.json"

python3 - "$lock" "$task_root" <<'PY'
import hashlib, json, sys, tarfile, urllib.request
from pathlib import Path
lock = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
asset = lock['asset']

request = urllib.request.Request(asset['url'], headers={'User-Agent': 'floe-rubywasl-fetch'})
data = urllib.request.urlopen(request, timeout=900).read()
digest = hashlib.sha256(data).hexdigest()
assert digest == asset['sha256'], f"{asset['url']} sha256 {digest} != pinned {asset['sha256']}"
assert len(data) == asset['sizeBytes'], f"{asset['url']} size {len(data)} != pinned {asset['sizeBytes']}"
archive = root / 'ruby-wasm-release.tar.gz'
archive.write_bytes(data)

member_name = None
with tarfile.open(archive) as tar:
    for member in tar.getmembers():
        if member.name == asset['member'] or member.name.endswith('/' + asset['member']):
            member_name = member.name
            source = tar.extractfile(member)
            if source is None:
                raise SystemExit(f"{asset['member']} is not a regular file")
            module = root / 'ruby.wasm'
            module.write_bytes(source.read())
            break
if member_name is None:
    raise SystemExit(f"{asset['member']} is missing from {asset['url']}")
module = root / 'ruby.wasm'
member_digest = hashlib.sha256(module.read_bytes()).hexdigest()
assert member_digest == asset['memberSha256'], f"member sha256 {member_digest} != pinned {asset['memberSha256']}"
assert module.stat().st_size == asset['memberSizeBytes'], f"member size {module.stat().st_size} != pinned {asset['memberSizeBytes']}"
assert module.read_bytes()[:4] == b'\0asm', 'member is not a WASM module'
print(f"verified {member_name} sha256 {member_digest}")
PY

out="$task_root/evidence"
mkdir -p "$out"
cp "$lock" "$out/"
python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest(), 'ruby.wasm')" "$task_root/ruby.wasm" > "$out/ruby.wasm.sha256"
curl -fsSL https://raw.githubusercontent.com/ruby/ruby.wasm/main/LICENSE -o "$out/ruby.wasm-LICENSE-MIT.txt" || true
curl -fsSL https://www.ruby-lang.org/en/about/license.txt -o "$out/ruby-interpreter-license.txt" || true
printf 'fetched %s\n' "$task_root/ruby.wasm"
