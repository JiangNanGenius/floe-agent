#!/usr/bin/env bash
# build-kernel-bbl.sh — fetch the exact boot loader and kernel sources that
# built the pinned 2018 demo `bbl64.bin` / `kernel-riscv64.bin`, apply the
# demo's own patches, and package the corresponding source bundle.
#
# The revisions and patch files are pinned in
# FloeAgent/ThirdParty/TinyEMU/guest-image/pinned-inputs.json:
#   riscv-pk    ac2c910b18c3e36cfd85080472e78ad2fe484325  (BSD-3-Clause)
#   riscv-linux a3b1e7acc6a181e04e9a943942084395df4498dd  (GPL-2.0)
# plus riscv-pk.diff / riscv-linux.diff / config_linux_riscv64 from the
# same directory.
#
# Default mode fetches, verifies and patches the sources and writes
# `SOURCE-MANIFEST.md` + SHA-512 digests for the two source tarballs. It does
# NOT build the kernel (a full 4.15 riscv64 build is out of scope for the
# component job); pass --rebuild to run the documented build, which is
# recorded as its own evidence.
#
# Usage:
#   bash build-kernel-bbl.sh --out DIR [--repo DIR] [--pins FILE] [--rebuild] [--jobs N]
set -euo pipefail

die() {
    printf 'build-kernel-bbl: ERROR: %s\n' "$*" >&2
    exit 1
}

log() { printf 'build-kernel-bbl: %s\n' "$*"; }

out=""
repo=""
pins=""
rebuild=0
jobs="$(nproc 2>/dev/null || echo 4)"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --pins) pins="${2:-}"; shift 2 ;;
        --rebuild) rebuild=1; shift ;;
        --jobs) jobs="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$out" ] || die "--out is required"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${repo:-$(cd "$script_dir/../../.." && pwd)}"
pins="${pins:-$script_dir/pinned-inputs.json}"
[ -f "$pins" ] || die "pinned inputs not found: $pins"
for tool in git curl tar sha512sum; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
mkdir -p "$out"

pin() {
    python3 - "$pins" "$1" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
print(eval(sys.argv[2], {"__builtins__": {}}, {"p": data}))  # noqa: S307 - fixed caller expressions
PY
}

fetch_revision() { # fetch_revision <dir> <repository> <revision>
    local dir="$1" url="$2" rev="$3"
    if [ ! -d "$dir/.git" ]; then
        mkdir -p "$dir"
        git -C "$dir" init -q
        git -C "$dir" remote add origin "$url"
    fi
    git -C "$dir" fetch -q --depth 1 origin "$rev"
    git -C "$dir" checkout -q FETCH_HEAD
    local actual
    actual="$(git -C "$dir" rev-parse HEAD)"
    [ "$actual" = "$rev" ] || die "revision mismatch in $dir: $actual != $rev"
}

apply_pinned_diff() { # apply_pinned_diff <dir> <diff file>
    # The demo archive's diffs were generated against exactly these revisions,
    # so `git apply` must work. `patch -p1` is the fallback for context-fuzz
    # (still recorded, never silent) and both paths are verified afterwards.
    local dir="$1" diff_file="$2"
    if git -C "$dir" apply --check "$diff_file" 2>/dev/null; then
        git -C "$dir" apply "$diff_file"
        printf 'applied-with=git-apply file=%s\n' "$(basename "$diff_file")" >>"$out/diff-application.txt"
        log "applied $(basename "$diff_file") to $dir (git apply)"
    elif (cd "$dir" && patch -p1 --dry-run <"$diff_file" >/dev/null 2>&1); then
        (cd "$dir" && patch -p1 <"$diff_file" >>"$out/diff-application.txt" 2>&1)
        printf 'applied-with=patch-p1 file=%s\n' "$(basename "$diff_file")" >>"$out/diff-application.txt"
        log "applied $(basename "$diff_file") to $dir (patch -p1 fallback)"
    else
        die "pinned diff does not apply to the pinned revision: $diff_file"
    fi
    git -C "$dir" diff --stat >>"$out/diff-application.txt" 2>&1 || true
}

manifest="$out/SOURCE-MANIFEST.md"
: >"$manifest"
{
    printf '# Guest kernel and boot loader — exact corresponding source\n\n'
    printf 'Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'These are the sources that built `bbl64.bin` and `kernel-riscv64.bin`\n'
    printf 'shipped in the Floe Linux guest image candidate (the 2018 demo archive\n'
    printf '`diskimage-linux-riscv-2018-09-23.tar.gz`, sha256\n'
    printf '808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14).\n\n'
    printf '| Component | Upstream | Revision | License | Patch | Config |\n'
    printf '| --- | --- | --- | --- | --- | --- |\n'
} >>"$manifest"

for component in bios_source kernel_source; do
    project="$(pin "p[\"$component\"][\"project\"]")"
    url="$(pin "p[\"$component\"][\"repository\"]")"
    rev="$(pin "p[\"$component\"][\"revision\"]")"
    license="$(pin "p[\"$component\"][\"license\"]")"
    diff_name="$(pin "p[\"$component\"][\"diff\"]")"
    config_name="$(pin "p[\"$component\"].get(\"config\")")"
    diff_file="$script_dir/$diff_name"
    [ -f "$diff_file" ] || die "pinned diff missing: $diff_file"

    src_dir="$out/$project-src"
    log "fetching $project @ $rev"
    fetch_revision "$src_dir" "$url" "$rev"
    apply_pinned_diff "$src_dir" "$diff_file"

    cp "$diff_file" "$src_dir/$diff_name"
    if [ "$config_name" != "None" ] && [ -n "$config_name" ] && [ -f "$script_dir/$config_name" ]; then
        cp "$script_dir/$config_name" "$src_dir/$config_name"
    fi
    if [ -f "$src_dir/COPYING" ]; then
        cp "$src_dir/COPYING" "$out/$project-COPYING"
    elif [ -f "$src_dir/LICENSE" ]; then
        cp "$src_dir/LICENSE" "$out/$project-LICENSE"
    else
        log "WARNING: no COPYING/LICENSE file found in $src_dir"
    fi

    tarball="$out/$project-$rev-src.tar.gz"
    rm -f "$tarball"
    tar --exclude='.git' -czf "$tarball" -C "$out" "$(basename "$src_dir")"
    sha512sum "$tarball" >"$tarball.sha512"
    log "source tarball: $tarball ($(stat -c %s "$tarball") bytes, $(cut -d' ' -f1 "$tarball.sha512"))"

    config_cell="—"
    if [ "$config_name" != "None" ] && [ -n "$config_name" ] && [ -f "$script_dir/$config_name" ]; then
        config_cell="$(basename "$config_name") (in-tree)"
    fi
    printf '| %s | %s | `%s` | %s | `%s` | %s |\n' \
        "$project" "$url" "$rev" "$license" "$diff_name" "$config_cell" >>"$manifest"
done

{
    printf '\n## Build recipe (not run by default; `--rebuild` runs it)\n\n'
    printf 'Boot loader (riscv-pk):\n\n```sh\n'
    printf 'cd riscv-pk-src\n./configure --host=riscv64-linux-gnu --with-arch=rv64gc --with-abi=lp64d\nmake\n'
    printf '# -> bbl/bbl (the pinned bbl64.bin is the RAW bbl binary; record its sha256)\n```\n\n'
    printf 'Kernel (riscv-linux):\n\n```sh\n'
    printf 'cd riscv-linux-src\ncp config_linux_riscv64 .config\nmake ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig\n'
    printf 'make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)"\n'
    printf '# -> arch/riscv/boot/Image (the pinned kernel-riscv64.bin)\n```\n\n'
    printf 'Pinned binary digests (for comparison after a rebuild):\n\n'
    printf -- '- `bbl64.bin` sha256 `%s` (%s bytes)\n' \
        "$(pin 'p["demo_archive"]["bios"]["sha256"]')" "$(pin 'p["demo_archive"]["bios"]["bytes"]')"
    printf -- '- `kernel-riscv64.bin` sha256 `%s` (%s bytes), version ident `%s`\n' \
        "$(pin 'p["demo_archive"]["kernel"]["sha256"]')" "$(pin 'p["demo_archive"]["kernel"]["bytes"]')" \
        "$(pin 'p["demo_archive"]["kernel"]["version_ident"]')"
    printf '\nA rebuild is not byte-for-byte reproducible across toolchains; the digests above\n'
    printf 'identify the shipped binaries, while this bundle is their corresponding source.\n'
} >>"$manifest"

if [ "$rebuild" = 1 ]; then
    log "rebuilding boot loader and kernel (this is heavy and not required for a source bundle)"
    command -v riscv64-linux-gnu-gcc >/dev/null 2>&1 || die "--rebuild needs gcc-riscv64-linux-gnu"
    (
        cd "$out/riscv-pk-src"
        ./configure --host=riscv64-linux-gnu --with-arch=rv64gc --with-abi=lp64d
        make -j"$jobs"
    ) >"$out/rebuild-riscv-pk.log" 2>&1 || die "riscv-pk rebuild failed (see rebuild-riscv-pk.log)"
    (
        cd "$out/riscv-linux-src"
        cp config_linux_riscv64 .config
        make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
        make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$jobs"
    ) >"$out/rebuild-riscv-linux.log" 2>&1 || die "kernel rebuild failed (see rebuild-riscv-linux.log)"
    {
        printf '\n## Rebuild outputs (this run)\n\n'
        sha256sum "$out/riscv-pk-src/bbl/bbl" 2>/dev/null || true
        sha256sum "$out/riscv-linux-src/arch/riscv/boot/Image" 2>/dev/null || true
    } >>"$manifest"
fi

sha512sum "$manifest" >"$manifest.sha512"
log "wrote $manifest"
