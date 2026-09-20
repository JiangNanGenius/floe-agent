#!/usr/bin/env bash
# collect-toolchain-sources.sh — exact corresponding source for the cross
# toolchain that produced the static riscv64 Floe runner (LGPL-2.1 §6 / GPL
# obligations), pinned to the versions actually installed.
#
# What is deliberately NOT done: fetching only "the latest package with that
# name". The static runner links the cross glibc, so the bundle must name and
# fetch the exact source versions that produced the installed binaries. The
# cross glibc itself is built by `cross-toolchain-base` from the separate
# `glibc` source package (Build-Depends: glibc-source), so both are needed —
# the cross recipe alone does not contain the glibc sources.
#
# Usage (Linux, root so the deb-src pocket can be added):
#   bash collect-toolchain-sources.sh --out DIR
#
# Outputs: the downloaded source packages, `toolchain-sources.md` (what was
# fetched, with versions and the reason for each), `toolchain-sources.sha256`,
# `apt-cache-showsrc.txt`, `toolchain-versions.txt` and any gap notes.
set -euo pipefail

die() {
    printf 'collect-toolchain-sources: ERROR: %s\n' "$*" >&2
    exit 1
}
log() { printf 'collect-toolchain-sources: %s\n' "$*"; }

out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$out" ] || die "--out is required"
mkdir -p "$out"
for tool in dpkg-query apt-get apt-cache sha256sum curl; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

gaps="$out/TOOLCHAIN-GAPS.txt"
: >"$gaps"
notes="$out/toolchain-sources.md"
: >"$notes"

# Resolve the *owning* packages of the actual compiler and the static libs, not
# just the metapackages (gcc-riscv64-linux-gnu points at gcc-defaults).
compiler_binary="$(command -v riscv64-linux-gnu-gcc 2>/dev/null || true)"
compiler_pkg=""
[ -n "$compiler_binary" ] && compiler_pkg="$(dpkg -S "$compiler_binary" 2>/dev/null | cut -d: -f1 | head -1)"
libc_dev_pkg="$(dpkg -S "$(riscv64-linux-gnu-gcc -print-file-name=libc.a 2>/dev/null)" 2>/dev/null | cut -d: -f1 | head -1 || true)"
libgcc_pkg="$(dpkg -S "$(riscv64-linux-gnu-gcc -print-file-name=libgcc.a 2>/dev/null)" 2>/dev/null | cut -d: -f1 | head -1 || true)"
libc_cross_pkg=""
if command -v dpkg-query >/dev/null 2>&1; then
    libc_cross_pkg="$(dpkg-query -W -f='${binary:Package}\n' 'libc6-*-cross' 2>/dev/null \
        | grep -E '^libc6-[^-]+-cross$' | grep -v -- '-dev-' | head -1 || true)"
fi

record_versions() {
    {
        for binary in gcc-riscv64-linux-gnu libc6-dev-riscv64-cross binutils-riscv64-linux-gnu \
                       "$compiler_pkg" "$libc_dev_pkg" "$libgcc_pkg" "$libc_cross_pkg"; do
            [ -n "$binary" ] || continue
            dpkg-query -W -f='binary ${binary:Package} ${Version} source ${source:Package} ${source:Version}\n' "$binary" 2>/dev/null || true
        done
        riscv64-linux-gnu-gcc --version 2>/dev/null | head -1 || true
        printf 'libc.a=%s\n' "$(riscv64-linux-gnu-gcc -print-file-name=libc.a 2>/dev/null || true)"
        printf 'libgcc.a=%s\n' "$(riscv64-linux-gnu-gcc -print-file-name=libgcc.a 2>/dev/null || true)"
    } >"$out/toolchain-versions.txt"
    cat "$out/toolchain-versions.txt" >>"$notes"
}
record_versions

# Each source package that must be fetched, as name=version (exact).
declare -A wanted=()
for binary in gcc-riscv64-linux-gnu libc6-dev-riscv64-cross binutils-riscv64-linux-gnu \
               "$compiler_pkg" "$libc_dev_pkg" "$libgcc_pkg" "$libc_cross_pkg"; do
    [ -n "$binary" ] || continue
    mapfile -t fields < <(dpkg-query -W -f='${source:Package}\n${source:Version}\n' "$binary" 2>/dev/null || true)
    if [ "${#fields[@]}" -lt 2 ] || [ -z "${fields[0]}" ]; then
        printf 'binary=%s reason=no-source-field\n' "$binary" >>"$gaps"
        continue
    fi
    source_name="${fields[0]}"
    source_version="${fields[1]}"
    if [ -z "$source_version" ]; then
        printf 'binary=%s source=%s reason=no-source-version\n' "$binary" "$source_name" >>"$gaps"
        continue
    fi
    wanted["$source_name"]="$source_version"
done

# The cross glibc: cross-toolchain-base builds it from the glibc source; its
# binary version (<glibc version>cross<N>) names the glibc version.
glibc_version=""
if [ -n "${wanted[cross-toolchain-base]:-}" ]; then
    base="${wanted[cross-toolchain-base]}"
    # cross-toolchain-base versions are its own; derive glibc from any
    # libc6-*-cross binary, which follows <glibc>cross<N>.
    if [ -n "$libc_cross_pkg" ]; then
        cross_libc_version="$(dpkg-query -W -f='${Version}\n' "$libc_cross_pkg" 2>/dev/null || true)"
        glibc_version="${cross_libc_version%cross*}"
    fi
    [ -n "$glibc_version" ] || glibc_version="$base"
fi

log "toolchain binaries: compiler=$compiler_pkg libc-dev=$libc_dev_pkg libgcc=$libgcc_pkg libc-cross=$libc_cross_pkg"
{
    printf '# Cross-toolchain corresponding source\n\n'
    printf 'Resolved from the installed packages (exact versions, no guessing):\n\n'
    printf -- '- compiler package: `%s`\n' "${compiler_pkg:-unresolved}"
    printf -- '- libc.a package: `%s`\n' "${libc_dev_pkg:-unresolved}"
    printf -- '- libgcc.a package: `%s`\n' "${libgcc_pkg:-unresolved}"
    printf -- '- cross libc package: `%s`\n' "${libc_cross_pkg:-unresolved}"
    printf -- '- glibc version implied by the cross libc: `%s`\n\n' "${glibc_version:-unknown}"
    printf '## Source packages to fetch (exact name=version)\n\n'
    for name in "${!wanted[@]}"; do
        printf -- '- `%s=%s`\n' "$name" "${wanted[$name]}"
    done
    printf '\n'
} >>"$notes"

# deb-src for every pocket the binaries can come from, plus universe.
if [ -w /etc/apt/sources.list.d ] || [ "$(id -u)" = "0" ]; then
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")"
    : >/etc/apt/sources.list.d/floe-source.list
    for pocket in "" "-updates" "-security"; do
        printf 'deb-src http://archive.ubuntu.com/ubuntu %s%s main universe\n' "$codename" "$pocket" \
            >>/etc/apt/sources.list.d/floe-source.list
    done
    apt-get update -qq >"$out/apt-update-src.log" 2>&1 \
        || die "apt-get update with deb-src failed; see apt-update-src.log"
else
    die "cannot enable deb-src (not root)"
fi

fetch_source() { # fetch_source <name> <version-or-empty> <why>
    local name="$1" version="$2" why="$3"
    local spec="$name"
    [ -n "$version" ] && spec="$name=$version"
    local before
    before="$(ls -1 "$out" | wc -l)"
    if (cd "$out" && apt-get source --download-only -qq "$spec") >>"$out/apt-get-source.log" 2>&1; then
        local after
        after="$(ls -1 "$out" | wc -l)"
        if [ "$after" -gt "$before" ]; then
            printf 'fetched %s via apt (%s)\n' "$spec" "$why" >>"$notes"
            log "fetched $spec"
            return 0
        fi
        printf 'note: %s reported success but downloaded nothing (%s)\n' "$spec" "$why" >>"$gaps"
    fi
    printf 'binary/source=%s version=%s reason=%s\n' "$name" "${version:-any}" "$why" >>"$gaps"
    log "WARNING: could not fetch $spec ($why)"
    return 1
}

for name in "${!wanted[@]}"; do
    fetch_source "$name" "${wanted[$name]}" "exact installed version" || true
done

# Direct pool fetch (Launchpad +files) for an exact version the apt index no
# longer lists, verified against the .dsc's own SHA-256 list.
fetch_dsc_from_launchpad() { # fetch_dsc_from_launchpad <source> <version>
    local source="$1" version="$2"
    local base="https://launchpad.net/ubuntu/+archive/primary/+files"
    local dsc_file="$out/${source}_${version}.dsc"
    if ! curl -fsSL --retry 2 --max-time 300 -o "$dsc_file" "$base/${source}_${version}.dsc"; then
        rm -f "$dsc_file"
        return 1
    fi
    local ok=1 sha size file target got_sha got_size
    while read -r sha size file; do
        [ -n "$sha" ] || continue
        target="$out/$file"
        if [ -f "$target" ] && [ "$(sha256sum "$target" | cut -d' ' -f1)" = "$sha" ]; then
            continue
        fi
        if ! curl -fsSL --retry 2 --max-time 900 -o "$target.part" "$base/$file"; then
            rm -f "$target.part"
            ok=0
            break
        fi
        got_size="$(stat -c %s "$target.part")"
        got_sha="$(sha256sum "$target.part" | cut -d' ' -f1)"
        if [ "$got_size" != "$size" ] || [ "$got_sha" != "$sha" ]; then
            rm -f "$target.part"
            ok=0
            break
        fi
        mv "$target.part" "$target"
        printf 'fetched %s via launchpad (dsc sha256 %s)\n' "$file" "${sha:0:16}" >>"$notes"
    done < <(awk '/^Checksums-Sha256:/{flag=1;next} flag&&/^ /{print $1, $2, $3; next} flag&&!/^ /{flag=0}' "$dsc_file")
    [ "$ok" = 1 ] || return 1
    printf 'fetched %s via launchpad (%s)\n' "${source}_${version}.dsc" "$version" >>"$notes"
    return 0
}

# glibc source: exact version from the cross libc first, then the Launchpad
# pool for that exact version, then the archive's current glibc (recorded as a
# gap, never silently substituted).
glibc_fetched=0
if [ -n "$glibc_version" ]; then
    fetch_source glibc "$glibc_version" "glibc version implied by cross libc" && glibc_fetched=1
fi
if [ "$glibc_fetched" = 0 ] && [ -n "$glibc_version" ]; then
    log "trying the Launchpad pool for glibc=$glibc_version"
    fetch_dsc_from_launchpad glibc "$glibc_version" && glibc_fetched=1
fi
if [ "$glibc_fetched" = 0 ]; then
    fetch_source glibc "" "exact cross glibc version not in the index; fetched current glibc instead" \
        && glibc_fetched=1
    printf 'glibc_exact_missing=%s\n' "${glibc_version:-unknown}" >>"$gaps"
fi

# Prove whether the glibc sources are actually inside the bundle (the cross
# recipe alone is not enough).
glibc_evidence="$(find "$out" -maxdepth 1 \( -name 'glibc_*.orig.tar.*' -o -name 'glibc_*.dsc' -o -name 'glibc-*' \) -print 2>/dev/null | head -5)"
if [ -n "$glibc_evidence" ]; then
    {
        printf '\n## glibc source coverage\n\n'
        printf 'The bundle contains the glibc source files:\n\n```\n%s\n```\n' "$glibc_evidence"
    } >>"$notes"
else
    {
        printf '\n## glibc source coverage\n\n'
        printf 'MISSING: no glibc source file was downloaded. The cross recipe alone\n'
        printf '(cross-toolchain-base) does not contain the glibc sources, so this is a\n'
        printf 'real LGPL gap until the matching glibc source is added.\n'
    } >>"$notes"
    printf 'glibc_source_missing=true\n' >>"$gaps"
fi

for name in "${!wanted[@]}"; do
    apt-cache showsrc "$name" >>"$out/apt-cache-showsrc.txt" 2>&1 || true
done
apt-cache showsrc glibc >>"$out/apt-cache-showsrc.txt" 2>&1 || true

(cd "$out" && sha256sum ./*.dsc ./*.tar.* ./*.diff.* 2>/dev/null >toolchain-sources.sha256) || true
printf '\n## Gap list\n\n' >>"$notes"
if [ -s "$gaps" ]; then
    printf '```\n' >>"$notes"
    cat "$gaps" >>"$notes"
    printf '```\n' >>"$notes"
else
    printf 'none\n' >>"$notes"
fi
log "wrote $notes ($(grep -c . "$gaps" || true) gap lines)"
