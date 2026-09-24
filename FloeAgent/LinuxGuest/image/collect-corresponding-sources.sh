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
#      file mapping for the exact installed set, with SHA-256 verification;
#   5. PyPI wheels pinned by the template recipe: wheel bytes (recipe-pin
#      verified), PyPI sdists (PyPI-digest verified) with a file-level
#      correspondence proof, and — for the pypdfium2 riscv64 wheel — the full
#      source chain of the bundled libpdfium.so (exact pdfium commit via the
#      frozen-branch proof, source archive, DEPS revision table).
#
# It does not publish anything. Its outputs are component artifacts + digests
# a reviewer (or the final distribution step) can re-check.
#
# Usage (Linux; root is recommended so the Ubuntu deb-src step can run):
#   bash collect-corresponding-sources.sh --out DIR --packages guest-packages.tsv \
#        --image-evidence DIR_WITH_RUNNER_EVIDENCE [--repo DIR] [--pins FILE]
#        [--pypi-recipe RECIPE_JSON] [--skip-upstream] [--skip-debian]
#        [--rebuild-kernel]
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
pypi_recipe=""
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
        --pypi-recipe) pypi_recipe="${2:-}"; shift 2 ;;
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
    log "note: no image evidence directory; the relink object is built below if possible"
fi

# The runner object is LGPL-2.1 §6 relink material. Prefer the object the
# image job compiled; otherwise compile it here from the same sources with the
# same flags, so a sources-only retry is still complete.
if [ ! -f "$relink/floe-exec-riscv64.o" ]; then
    if command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then
        log "building runner relink object (image evidence had none)"
        riscv64-linux-gnu-gcc -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE \
            -static -I"$repo/FloeAgent/LinuxGuest/runner" \
            -c -o "$relink/floe-exec-riscv64.o" "$repo/FloeAgent/LinuxGuest/runner/floe_exec.c" \
            >"$relink/object-build.log" 2>&1
        sha256sum "$relink/floe-exec-riscv64.o" >>"$relink/toolchain.txt" 2>/dev/null || true
    else
        log "WARNING: riscv64 cross compiler unavailable and no prebuilt object; RELINK.md still ships the exact source and command"
    fi
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
if [ "$skip_upstream" = 0 ]; then
    log "cross-toolchain corresponding sources (exact installed versions)"
    bash "$script_dir/collect-toolchain-sources.sh" --out "$toolchain_src" \
        || log "WARNING: toolchain source collection reported a problem; see toolchain-source/TOOLCHAIN-GAPS.txt"
fi
{
    printf '## 3. Cross toolchain / glibc source\n\n'
    if [ -f "$toolchain_src/toolchain-sources.md" ]; then
        cat "$toolchain_src/toolchain-sources.md"
        printf '\n'
    else
        printf 'NOT COLLECTED in this run (--skip-upstream or a hard failure).\n\n'
    fi
    if [ -s "$toolchain_src/TOOLCHAIN-GAPS.txt" ]; then
        printf 'Open gaps (must be resolved before public distribution):\n\n```\n'
        cat "$toolchain_src/TOOLCHAIN-GAPS.txt"
        printf '```\n\n'
    fi
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

# ---------------------------------------------------------------------------
# 5. PyPI wheels pinned by the template recipe
# ---------------------------------------------------------------------------
if [ -n "$pypi_recipe" ]; then
    [ -f "$pypi_recipe" ] || die "pypi recipe not found: $pypi_recipe"
    log "PyPI wheel corresponding sources ($pypi_recipe)"
    set +e
    python3 "$script_dir/collect-pypi-sources.py" --recipe "$pypi_recipe" \
        --out "$out/pypi-sources" --github-run "$run_url"
    pypi_rc=$?
    set -e
    if [ "$pypi_rc" = 3 ]; then
        log "WARNING: some pinned wheels have corresponding-source gaps (see pypi-sources/pypi-source-gaps.tsv); recording the gap and continuing"
    elif [ "$pypi_rc" != 0 ]; then
        die "pypi source collection failed with rc=$pypi_rc"
    fi
    {
        printf '## 5. PyPI wheel corresponding sources\n\n'
        if [ -f "$out/pypi-sources/PYPI-SOURCES.md" ]; then
            printf 'Details: `pypi-sources/PYPI-SOURCES.md`; checksums: `pypi-sources/PYPI-SOURCES.sha256`.\n\n'
            printf '```\n'
            printf 'gap_packages=%s\n' "$(grep -cve '^#' "$out/pypi-sources/pypi-source-gaps.tsv" || true)"
            printf '```\n\n'
        else
            printf 'NOT COLLECTED in this run (hard failure).\n\n'
        fi
        if [ "$(grep -cve '^#' "$out/pypi-sources/pypi-source-gaps.tsv" 2>/dev/null || true)" != "0" ]; then
            printf 'The PyPI gap list is a real distribution gap (same rule as the Debian\n'
            printf 'gaps); resolve every row before the image is offered publicly.\n\n'
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
    printf '| Debian userland packages | per package (mostly GPL/LGPL/BSD/MIT) | `debian-sources/` + `guest-copyrights.tar.gz` (image evidence) |\n'
    printf '| PyPI wheels (python-pptx MIT, pdfplumber MIT, pdfminer.six MIT, pypdfium2 Apache-2.0 OR BSD-3-Clause, pdfium BSD-3-Clause) | per project | `pypi-sources/` |\n\n'
    printf 'Distribution is still gated by the primary release decision: this bundle is an\n'
    printf 'artifact, not a published source offer, and `distributionAllowed` stays false in\n'
    printf 'the image manifest until the offer is actually published.\n'
} >>"$summary"

sha512sum "$summary" >"$summary.sha512"
log "wrote $summary"
