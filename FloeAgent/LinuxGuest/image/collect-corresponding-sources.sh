#!/usr/bin/env bash
# collect-corresponding-sources.sh — assemble the complete corresponding-source
# bundle for one Floe Linux guest image candidate.
#
# Four parts, because the licenses differ:
#   1. kernel + boot loader: exact riscv-linux/riscv-pk revisions + the demo's
#      diffs + kernel config (GPL-2.0 / BSD-3-Clause);
#   2. runner relink material: the static riscv64 Floe runner object, its exact
#      link command, the cross-toolchain versions and (below) glibc source, so
#      the LGPL-2.1 §6 relink obligation for the statically linked glibc is
#      satisfiable (runner itself is MPL-2.0);
#   3. cross-toolchain source packages from the distribution archive
#      (Ubuntu for the CI build; recorded, best effort, never silently skipped);
#   4. Debian userland: binary package -> source package -> .dsc/orig/debian
#      file mapping for the exact installed set, with SHA-256 verification.
#
# It does not publish anything. Its outputs are component artifacts + digests
# a reviewer (or the final distribution step) can re-check.
#
# Usage (Linux; root is recommended so the Ubuntu deb-src step can run):
#   bash collect-corresponding-sources.sh --out DIR --packages guest-packages.tsv \
#        --image-evidence DIR_WITH_RUNNER_EVIDENCE [--repo DIR] [--pins FILE]
#        [--skip-upstream] [--skip-debian] [--rebuild-kernel]
set -euo pipefail

die() {
    printf 'collect-corresponding-sources: ERROR: %s\n' "$*" >&2
    exit 1
}
log() { printf 'collect-corresponding-sources: %s\n' "$*"; }

out=""
repo=""
pins=""
packages=""
image_evidence=""
run_url=""
skip_upstream=0
skip_debian=0
rebuild_kernel=0
shard_bytes=$((1200 * 1024 * 1024))

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --pins) pins="${2:-}"; shift 2 ;;
        --packages) packages="${2:-}"; shift 2 ;;
        --image-evidence) image_evidence="${2:-}"; shift 2 ;;
        --run-url) run_url="${2:-}"; shift 2 ;;
        --shard-bytes) shard_bytes="${2:-}"; shift 2 ;;
        --skip-upstream) skip_upstream=1; shift ;;
        --skip-debian) skip_debian=1; shift ;;
        --rebuild-kernel) rebuild_kernel=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$out" ] || die "--out is required"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${repo:-$(cd "$script_dir/../../.." && pwd)}"
pins="${pins:-$repo/FloeAgent/ThirdParty/TinyEMU/guest-image/pinned-inputs.json}"
mkdir -p "$out"
for tool in python3 curl sha256sum sha512sum tar; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

summary="$out/SOURCES-MANIFEST.md"
: >"$summary"
{
    printf '# Corresponding-source bundle — Floe Linux guest image candidate\n\n'
    printf 'Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'This bundle is component-CI material, not a public source offer. It is the\n'
    printf 'material a distribution step needs before an image may be offered to users.\n\n'
    if [ -n "$run_url" ]; then
        printf 'Image build run: %s\n\n' "$run_url"
    fi
} >>"$summary"

# ---------------------------------------------------------------------------
# 1. kernel + boot loader
# ---------------------------------------------------------------------------
if [ "$skip_upstream" = 0 ]; then
    log "upstream sources (kernel + bbl)"
    upstream_args=(--out "$out/upstream" --repo "$repo" --pins "$pins")
    [ "$rebuild_kernel" = 1 ] && upstream_args+=(--rebuild)
    bash "$repo/FloeAgent/ThirdParty/TinyEMU/guest-image/build-kernel-bbl.sh" "${upstream_args[@]}"
    {
        printf '## 1. Kernel and boot loader\n\n'
        printf 'See `upstream/SOURCE-MANIFEST.md` for revisions, patches, build recipe and\n'
        printf 'digests. Kernel: GPL-2.0. Boot loader: BSD-3-Clause.\n\n'
        printf '```\n'
        cat "$out/upstream/SOURCE-MANIFEST.md"
        printf '```\n\n'
    } >>"$summary"
fi

# ---------------------------------------------------------------------------
# 2. runner relink material (LGPL-2.1 §6 for the static glibc)
# ---------------------------------------------------------------------------
relink="$out/runner-relink"
mkdir -p "$relink"
cp "$repo/FloeAgent/LinuxGuest/runner/floe_exec.c" "$relink/"
cp "$repo/FloeAgent/LinuxGuest/runner/floe_clock.h" "$relink/"
cp "$repo/FloeAgent/LinuxGuest/runner/Makefile" "$relink/Makefile"
if [ -n "$image_evidence" ] && [ -d "$image_evidence" ]; then
    cp "$image_evidence/runner-toolchain.txt" "$relink/toolchain.txt" 2>/dev/null || true
    cp "$image_evidence/runner-sha256.txt" "$relink/runner-sha256.txt" 2>/dev/null || true
    if [ -f "$image_evidence/floe-exec-riscv64.o" ]; then
        cp "$image_evidence/floe-exec-riscv64.o" "$relink/floe-exec-riscv64.o"
    fi
    cp "$image_evidence/zip-sha512.txt" "$relink/" 2>/dev/null || true
else
    log "WARNING: no image evidence directory; the relink object may be missing"
fi
cat >"$relink/RELINK.md" <<'MD'
# Relinking the Floe runner against a modified glibc (LGPL-2.1 §6)

`floe-exec-riscv64` is the repository's MPL-2.0 runner statically linked with
the GNU C Library from the CI cross toolchain. glibc is LGPL-2.1; a static
link is a combined work, so the image distribution must let a recipient
relink the runner against a modified glibc.

This directory contains what that needs:

- `floe_exec.c`, `floe_clock.h`, `Makefile` — the exact runner sources;
- `floe-exec-riscv64.o` — the compiled runner object (from the same source,
  same flags as the shipped binary);
- `toolchain.txt` — compiler version, exact cross packages and the link
  command used;
- `runner-sha256.txt` — SHA-256 of the shipped binary (to compare against a
  rebuild);
- the glibc corresponding source is fetched by this script into
  `../toolchain-source/` from the distribution archive (see
  `apt-cache showsrc` output there).

Relink recipe (on an x86-64/arm64 Linux host with `gcc-riscv64-linux-gnu`):

```sh
# 1. build a modified glibc for riscv64 (or unpack the distribution source
#    and apply your changes), install it to /opt/riscv64-glibc
# 2. relink the runner object:
riscv64-linux-gnu-gcc -static -o floe-exec-riscv64-modified \
    floe-exec-riscv64.o \
    /opt/riscv64-glibc/lib/libc.a /opt/riscv64-glibc/lib/libc_nonshared.a \
    -lgcc -lgcc_eh
# 3. the result must run as PID 1 in the guest:
#    console=hvc0 root=/dev/vda rw init=/usr/local/bin/floe-exec floe.epoch=<now>
```

The shipped binary is otherwise unmodified Floe runner code; only glibc and
libgcc are library code inside it.
MD
{
    printf '## 2. Runner relink material (LGPL-2.1)\n\n'
    printf 'The runner is MPL-2.0; it statically links glibc (LGPL-2.1).\n'
    printf '`runner-relink/` carries the object, sources, link command and toolchain\n'
    printf 'record; `runner-relink/RELINK.md` documents the relink recipe.\n\n'
    if [ -f "$relink/toolchain.txt" ]; then
        printf '```\n'
        cat "$relink/toolchain.txt"
        printf '```\n\n'
    fi
} >>"$summary"

# ---------------------------------------------------------------------------
# 3. cross-toolchain / glibc source from the distribution archive
# ---------------------------------------------------------------------------
toolchain_src="$out/toolchain-source"
mkdir -p "$toolchain_src"
: >"$toolchain_src/apt-cache-showsrc.txt"
if [ "$skip_upstream" = 0 ]; then
    if command -v apt-get >/dev/null 2>&1 && command -v apt-cache >/dev/null 2>&1; then
        if [ ! -d /etc/apt/sources.list.d ] || [ ! -w /etc/apt/sources.list.d ]; then
            log "WARNING: cannot add deb-src (not root or no sources.list.d); recording package versions only"
        else
            codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")"
            printf 'deb-src http://archive.ubuntu.com/ubuntu %s main universe\n' "$codename" \
                >/etc/apt/sources.list.d/floe-source.list
            if apt-get update -qq >"$toolchain_src/apt-update-src.log" 2>&1; then
                source_names=""
                for binary in gcc-riscv64-linux-gnu libc6-dev-riscv64-cross binutils-riscv64-linux-gnu; do
                    name="$(apt-cache show "$binary" 2>/dev/null | awk -F': ' '/^Source:/{print $2; exit}')"
                    [ -n "$name" ] || name="$binary"
                    source_names="$source_names $name"
                done
                source_names="$(printf '%s\n' $source_names | sort -u | tr '\n' ' ')"
                log "cross-toolchain source packages:$source_names"
                for name in $source_names; do
                    apt-cache showsrc "$name" >>"$toolchain_src/apt-cache-showsrc.txt" 2>&1 || true
                done
                (
                    cd "$toolchain_src"
                    # shellcheck disable=SC2086 # deliberate word list
                    apt-get source --download-only -qq $source_names
                ) >>"$toolchain_src/apt-get-source.log" 2>&1 || log "WARNING: apt-get source failed; see toolchain-source/apt-get-source.log"
            else
                log "WARNING: apt-get update with deb-src failed; see toolchain-source/apt-update-src.log"
            fi
        fi
    fi
fi
(
    cd "$toolchain_src"
    dpkg-query -W -f='${binary:Package}\t${Version}\n' \
        gcc-riscv64-linux-gnu libc6-dev-riscv64-cross binutils-riscv64-linux-gnu 2>/dev/null || true
    riscv64-linux-gnu-gcc --version 2>/dev/null | head -1 || true
    riscv64-linux-gnu-gcc -print-file-name=libc.a 2>/dev/null || true
) >"$toolchain_src/toolchain-versions.txt" 2>&1 || true
if compgen -G "$toolchain_src/*.dsc" >/dev/null; then
    (cd "$toolchain_src" && sha256sum ./*.dsc ./*.tar.* ./*.diff.* 2>/dev/null >toolchain-sources.sha256) || true
fi
{
    printf '## 3. Cross toolchain / glibc source\n\n'
    if compgen -G "$toolchain_src/*.dsc" >/dev/null; then
        printf 'Distribution source packages downloaded into `toolchain-source/`:\n\n```\n'
        (cd "$toolchain_src" && ls -1 ./*.dsc 2>/dev/null)
        printf '```\n\n'
    else
        printf 'NOT FETCHED in this run: the distribution source download was skipped or\n'
        printf 'failed (no network/deb-src/root). `toolchain-source/toolchain-versions.txt`\n'
        printf 'still records the exact compiler and cross packages; obtain the matching\n'
        printf '`glibc` / `cross-toolchain-base` source package before public distribution.\n\n'
    fi
    printf '```\n'
    cat "$toolchain_src/toolchain-versions.txt" 2>/dev/null || true
    printf '```\n\n'
} >>"$summary"

# ---------------------------------------------------------------------------
# 4. Debian userland: binary -> source mapping + verified source download
# ---------------------------------------------------------------------------
if [ "$skip_debian" = 0 ]; then
    [ -n "$packages" ] || die "--packages is required for the Debian part"
    [ -f "$packages" ] || die "package list not found: $packages"
    index_dir="$out/debian-index"
    map_file="$out/debian-package-source-map.tsv"
    gaps_file="$out/debian-source-gaps.tsv"
    sources_dir="$out/debian-sources"
    log "Debian source indexes"
    python3 "$script_dir/debian-source-map.py" index --out "$index_dir" \
        --suite "trixie=https://deb.debian.org/debian/dists/trixie/main/source/Sources.xz" \
        --suite "trixie-updates=https://deb.debian.org/debian/dists/trixie-updates/main/source/Sources.xz" \
        --suite "trixie-security=https://deb.debian.org/debian-security/dists/trixie-security/main/source/Sources.xz"
    log "mapping $(wc -l <"$packages") installed packages"
    set +e
    python3 "$script_dir/debian-source-map.py" map \
        --packages "$packages" --index-dir "$index_dir" \
        --out "$map_file" --gaps "$gaps_file"
    map_rc=$?
    set -e
    if [ "$map_rc" = 3 ]; then
        log "WARNING: some packages have no matching source version in the indexes (see $(basename "$gaps_file")); recording the gap and continuing"
    elif [ "$map_rc" != 0 ]; then
        die "mapping failed with rc=$map_rc"
    fi
    log "downloading corresponding sources (this is the large step)"
    python3 "$script_dir/debian-source-map.py" fetch \
        --mapping "$map_file" --out "$sources_dir" --checksums "$sources_dir/SOURCES.sha256" \
        --shard-bytes "$shard_bytes"
    {
        printf '## 4. Debian userland corresponding sources\n\n'
        printf 'Mapping: `debian-package-source-map.tsv` (binary -> source -> file -> sha256).\n'
        printf 'Gaps: `%s` (source version not found in the trixie/updates/security indexes).\n' "$(basename "$gaps_file")"
        printf 'Files: `debian-sources/shard-N/` with `SOURCES.sha256` (paths relative to\n'
        printf '`debian-sources/`, so `sha256sum -c SOURCES.sha256` works after downloading\n'
        printf 'every shard into one directory) and `SOURCES.tsv` (source -> files).\n'
        printf 'Index digests: `debian-index/indexes.tsv`.\n\n'
        printf '```\n'
        printf 'mapped_files=%s\n' "$(grep -cve '^#' "$map_file" || true)"
        printf 'gap_packages=%s\n' "$(grep -cve '^#' "$gaps_file" || true)"
        printf 'downloaded_bytes=%s\n' "$(du -sb "$sources_dir" 2>/dev/null | cut -f1 || echo 0)"
        printf 'shards=%s\n' "$(find "$sources_dir" -maxdepth 1 -type d -name 'shard-*' | wc -l)"
        printf '```\n\n'
        if [ "$(grep -cve '^#' "$gaps_file" || true)" != "0" ]; then
            printf 'The gap list is a real distribution gap: every row must be resolved\n'
            printf '(source fetched from the matching archive/snapshot) before the image is\n'
            printf 'offered publicly.\n\n'
        fi
    } >>"$summary"
fi

{
    printf '## License mapping (summary)\n\n'
    printf '| Component | License | Source in this bundle |\n'
    printf '| --- | --- | --- |\n'
    printf '| Linux kernel (pinned 4.15) | GPL-2.0 | `upstream/riscv-linux-*-src.tar.gz` + COPYING |\n'
    printf '| riscv-pk / bbl | BSD-3-Clause | `upstream/riscv-pk-*-src.tar.gz` + LICENSE |\n'
    printf '| Floe runner | MPL-2.0 | `runner-relink/` |\n'
    printf '| glibc (static in runner) | LGPL-2.1 | `toolchain-source/` + `runner-relink/RELINK.md` |\n'
    printf '| Debian userland packages | per package (mostly GPL/LGPL/BSD/MIT) | `debian-sources/` + `guest-copyrights.tar.gz` (image evidence) |\n\n'
    printf 'Distribution is still gated by the primary release decision: this bundle is an\n'
    printf 'artifact, not a published source offer, and `distributionAllowed` stays false in\n'
    printf 'the image manifest until the offer is actually published.\n'
} >>"$summary"

sha512sum "$summary" >"$summary.sha512"
log "wrote $summary"
