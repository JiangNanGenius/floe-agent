#!/usr/bin/env bash
# venv_seed_recipe_check.sh — static + behavioral checks for the Python venv
# seed recipe (FloeAgent/LinuxGuest/image/python-venv-seed.sh) and its verifier.
#
# No rootfs and no riscv64 execution are needed: the verifier is driven against
# a synthetic seed tree whose manifest is generated exactly the way the recipe
# records it (same fields, same hashing). The checks cover:
#   * the recipe contract: default seed path, absolute refusal of /floe paths,
#     `--system-site-packages` creation, manifest + verify invocation;
#   * the verifier round trip: a faithful seed passes; a modified file, an
#     extra file, a seed under /floe, a version mismatch and a bad schema fail;
#   * the optional interpreter execution path with a stub python.
#
# Usage: bash FloeAgent/LinuxGuest/tests/venv_seed_recipe_check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_dir="$(cd "$here/../image" && pwd)"
recipe="$image_dir/python-venv-seed.sh"
verifier="$image_dir/python-venv-seed-verify.py"

failures=0
note() { printf '%s\n' "$*"; }
check() { # $1 = condition-command description, $2 = ok?
    if [ "$2" = 0 ]; then
        note "ok: $1"
    else
        note "FAIL: $1"
        failures=$((failures + 1))
    fi
}

[ -f "$recipe" ] || { note "missing $recipe"; exit 2; }
[ -f "$verifier" ] || { note "missing $verifier"; exit 2; }

# ---- recipe contract ---------------------------------------------------
grep -q 'SEED_PATH="${2:-/usr/lib/floe/python/venv-seed}"' "$recipe"
check "recipe default seed path is /usr/lib/floe/python/venv-seed" $?
grep -q 'refusing: the seed must not live under /floe' "$recipe"
check "recipe refuses a seed under /floe" $?
grep -q 'python3 -m venv --system-site-packages "\$SEED_DIR"' "$recipe"
check "recipe creates the seed with --system-site-packages" $?
grep -q 'python-venv-seed-verify.py' "$recipe"
check "recipe verifies the seed it just built" $?

tmp="$(mktemp -d "${TMPDIR:-/tmp}/floe-seed-check.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

make_seed() { # $1 = root, $2 = version
    root="$1"; version="$2"
    seed="$root/usr/lib/floe/python/venv-seed"
    mkdir -p "$seed/bin" "$seed/lib/python3.13/site-packages/pip"
    printf 'home = /usr/bin\ninclude-system-site-packages = true\nversion = %s\nexecutable = /usr/bin/python3.13\n' \
        "$version" > "$seed/pyvenv.cfg"
    cat > "$seed/bin/python3" <<'EOF'
#!/bin/sh
case "$2" in
    *sys.version*) echo 3.13.5;;
esac
exit 0
EOF
    chmod 755 "$seed/bin/python3"
    ln -s python3 "$seed/bin/python"
    : > "$seed/lib/python3.13/site-packages/pip/__init__.py"
    python3 - "$root" "$version" <<'PY'
import hashlib, json, os, sys
root, version = sys.argv[1], sys.argv[2]
seed_path = "/usr/lib/floe/python/venv-seed"
seed = os.path.join(root, seed_path.lstrip("/"))
files = {}
for base, _dirs, names in os.walk(seed):
    for name in names:
        full = os.path.join(base, name)
        rel = os.path.relpath(full, seed)
        if os.path.islink(full):
            files[rel] = {"link": os.readlink(full)}
            continue
        digest = hashlib.sha256()
        with open(full, "rb") as handle:
            digest.update(handle.read())
        files[rel] = {"sha256": digest.hexdigest(), "bytes": os.path.getsize(full)}
manifest = {
    "schema": "floe-python-venv-seed/v1",
    "seed_path": seed_path,
    "materialize_target": "/floe/env/python/venv",
    "created_by": "test",
    "recipe_sha256": "0" * 64,
    "command": "python3 -m venv --system-site-packages " + seed_path,
    "python": {"version": version, "platform": "linux-riscv64",
               "base_executable": "/usr/bin/python3.13",
               "include_system_site_packages": True},
    "file_count": len(files),
    "total_bytes": sum(v.get("bytes", 0) for v in files.values()),
    "files": files,
}
with open(os.path.join(root, "usr/lib/floe/python/venv-seed.manifest.json"), "w") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
PY
}

# ---- passing round trip ------------------------------------------------
root_pass="$tmp/pass"
make_seed "$root_pass" 3.13.5
python3 "$verifier" --root "$root_pass" >"$tmp/pass.log" 2>&1
check "faithful synthetic seed passes verification" $?
grep -q "seed verify ok" "$tmp/pass.log"
check "verifier reports ok" $?
python3 "$verifier" --root "$root_pass" --run >"$tmp/pass-run.log" 2>&1
check "stub interpreter --run path passes" $?
grep -q "ran=True" "$tmp/pass-run.log"
check "verifier reports it executed the seed" $?

# ---- failure modes -----------------------------------------------------
root_mod="$tmp/modified"
make_seed "$root_mod" 3.13.5
printf 'tampered\n' >> "$root_mod/usr/lib/floe/python/venv-seed/bin/python3"
if python3 "$verifier" --root "$root_mod" >"$tmp/mod.log" 2>&1; then
    check "modified seed file fails verification" 1
else
    check "modified seed file fails verification" 0
    grep -q "sha256" "$tmp/mod.log"
    check "failure names the hash mismatch" $?
fi

root_extra="$tmp/extra"
make_seed "$root_extra" 3.13.5
: > "$root_extra/usr/lib/floe/python/venv-seed/bin/stray"
if python3 "$verifier" --root "$root_extra" >"$tmp/extra.log" 2>&1; then
    check "stray file fails the exact inventory" 1
else
    check "stray file fails the exact inventory" 0
    grep -q "not in the manifest" "$tmp/extra.log"
    check "failure names the stray file" $?
fi

root_floe="$tmp/floe"
make_seed "$root_floe" 3.13.5
python3 - "$root_floe" <<'PY'
import json, sys
path = sys.argv[1] + "/usr/lib/floe/python/venv-seed.manifest.json"
manifest = json.load(open(path))
manifest["seed_path"] = "/floe/env/python/venv-seed"
manifest["materialize_target"] = "/floe/env/python/venv-seed"
json.dump(manifest, open(path, "w"))
PY
if python3 "$verifier" --root "$root_floe" >"$tmp/floe.log" 2>&1; then
    check "seed under /floe fails verification" 1
else
    check "seed under /floe fails verification" 0
    grep -q "per-environment layer" "$tmp/floe.log"
    check "failure names the shadowed path" $?
fi

root_ver="$tmp/version"
make_seed "$root_ver" 3.12.0
if python3 "$verifier" --root "$root_ver" >"$tmp/ver.log" 2>&1; then
    check "pyvenv.cfg version is compared against the manifest (3.12 fixture)" 0
else
    check "pyvenv.cfg version is compared against the manifest (3.12 fixture)" 1
fi

root_schema="$tmp/schema"
make_seed "$root_schema" 3.13.5
python3 - "$root_schema" <<'PY'
import json, sys
path = sys.argv[1] + "/usr/lib/floe/python/venv-seed.manifest.json"
manifest = json.load(open(path))
manifest["schema"] = "other/v9"
json.dump(manifest, open(path, "w"))
PY
if python3 "$verifier" --root "$root_schema" >"$tmp/schema.log" 2>&1; then
    check "bad manifest schema fails verification" 1
else
    check "bad manifest schema fails verification" 0
fi

note "venv seed recipe check: $failures failure(s)"
exit $((failures == 0 ? 0 : 1))
