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
#   bash build-kernel-bbl.sh --out DIR [--repo DIR] [--pins FILE] [--rebuild] [--jobs N] [--smp]
#
# --smp merges config_linux_riscv64_smp.fragment before olddefconfig and
# requires --rebuild: it produces the dual-hart qualification boot pair
# (SMP=y, NR_CPUS=2) consumed by build-guest-image.sh --boot-dir. It is a
# separate artifact, never a replacement for the pinned 2018 pair.
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
smp=0
jobs="$(nproc 2>/dev/null || echo 4)"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --pins) pins="${2:-}"; shift 2 ;;
        --rebuild) rebuild=1; shift ;;
        --smp) smp=1; shift ;;
        --jobs) jobs="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$out" ] || die "--out is required"
[ "$smp" = 1 ] && [ "$rebuild" = 0 ] && die "--smp requires --rebuild (it produces a boot pair)"
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
    printf 'cd riscv-pk-src\nmkdir -p build && cd build\n../configure --host=riscv64-linux-gnu --with-arch=rv64gc\nmake\n'
    printf '# (out-of-tree: the source tree already contains a pk/ directory, so\n'
    printf '#  an in-tree link cannot create the pk program output)\n'
    printf '# -> build/bbl (ELF link output; the pinned bbl64.bin is its RAW\n'
    printf '#    objcopy -O binary image, produced below and in $out/boot/bbl64.bin)\n```\n\n'
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
    for tool in riscv64-linux-gnu-gcc riscv64-linux-gnu-objcopy \
                riscv64-linux-gnu-readelf; do
        command -v "$tool" >/dev/null 2>&1 || die "--rebuild needs $tool"
    done
    # The pinned 2018 riscv-pk predates the diagnostics current GCC releases
    # promote to errors (implicit function declarations and friends became
    # errors by default in GCC 14), but a GCC release that does not know a
    # -Wno-error= name rejects it with a hard cc1 error, so probe every
    # candidate against the actual cross compiler and keep only the accepted
    # ones. Warnings stay warnings; the whole log is kept as evidence.
    probe_cflag() {
        printf 'int main(void){return 0;}\n' >"$out/.cflag-probe.c"
        riscv64-linux-gnu-gcc $1 -c "$out/.cflag-probe.c" \
            -o "$out/.cflag-probe.o" >/dev/null 2>&1
    }
    # Ubuntu's cross toolchain compiles with the distribution hardening
    # defaults (-fstack-protector-strong, -D_FORTIFY_SOURCE=3); riscv-pk is
    # bare metal and links -nostdlib, so those references (__stack_chk_fail,
    # __stack_chk_guard, __*_chk) have no implementation. Ubuntu already broke
    # the link this way once; disable them explicitly for this build only.
    # riscv-pk's configure.ac overwrites CFLAGS with its own set, so these
    # flags must go through make (the Makefile appends $(CFLAGS) after its
    # own -Werror). -fno-stack-protector / -D_FORTIFY_SOURCE=0 are needed
    # because Ubuntu's cross toolchain compiles with -fstack-protector-strong
    # and -D_FORTIFY_SOURCE=3 by default while the firmware links -nostdlib
    # (the third cloud run failed on __stack_chk_guard/__stack_chk_fail).
    bbl_cflags="-fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
    for flag in -Wno-error=implicit-function-declaration \
                -Wno-error=int-conversion \
                -Wno-error=incompatible-pointer-types \
                -Wno-error=return-mismatch \
                -Wno-error=declaration-missing-parameter-type; do
        if probe_cflag "$flag"; then
            bbl_cflags="$bbl_cflags $flag"
        else
            log "cross compiler rejects $flag; not passing it"
        fi
    done
    rm -f "$out/.cflag-probe.c" "$out/.cflag-probe.o"
    # The ABI option only exists in later riscv-pk revisions; the demo patch
    # hardcodes -mabi=lp64d in Makefile.in, so pass it only if configure
    # advertises it (an unknown option is a warning, but the log should not
    # carry noise that looks like a misconfiguration).
    extra_configure=""
    if (cd "$out/riscv-pk-src" && ./configure --help 2>/dev/null | grep -q -- '--with-abi'); then
        extra_configure="--with-abi=lp64d"
    fi
    (
        # Out-of-tree build (upstream's documented way): an in-tree build
        # cannot link the `pk` program because the source directory already
        # contains `pk/`, and the linker refuses to write a file named like
        # an existing directory. The build directory has no such collision,
        # so both `pk` and `bbl` link.
        rm -rf "$out/riscv-pk-src/build"
        mkdir -p "$out/riscv-pk-src/build"
        cd "$out/riscv-pk-src/build"
        # LDFLAGS=-nostdlib keeps configure's compiler check from needing the
        # cross libc: riscv-pk is bare-metal and links with -nostdlib anyway.
        ../configure --host=riscv64-linux-gnu --with-arch=rv64gc \
            $extra_configure LDFLAGS="-nostdlib"
        # CFLAGS must come from the environment, not the make command line:
        # a command-line CFLAGS would override the makefile's own assignment
        # and with it -DBBL_LOGO_FILE/-DBBL_PAYLOAD/-march, which made
        # raw_logo.S assemble without its logo string (retained failure).
        CFLAGS="$bbl_cflags" make -j"$jobs"
    ) >"$out/rebuild-riscv-pk.log" 2>&1 || {
        printf 'build-kernel-bbl: riscv-pk rebuild failed; last lines:\n' >&2
        tail -c 4000 "$out/rebuild-riscv-pk.log" >&2 || true
        die "riscv-pk rebuild failed (see rebuild-riscv-pk.log)"
    }

    # ------------------------------------------------------------------
    # The pinned boot loader file is a RAW binary, not the ELF the riscv-pk
    # link step leaves in bbl/bbl: TinyEMU's copy_bios() memcpy()s the BIOS
    # at 0x80000000 and has no ELF loader, so handing it bbl/bbl would
    # execute the ELF header instead of the reset vector. Produce and
    # verify the raw image here, once, and let consumers copy
    # $out/boot/bbl64.bin (never bbl/bbl).
    # ------------------------------------------------------------------
    rpk="$out/riscv-pk-src"
    bbl_raw="$out/boot/bbl64.bin"
    kernel_raw="$out/boot/kernel-riscv64.bin"
    mkdir -p "$out/boot"
    # the boot loader ELF: out-of-tree builds put it in build/, older/in-tree
    # layouts in bbl/; accept only a file that really is an ELF
    bbl_elf=""
    for cand in "$rpk/build/bbl" "$rpk/bbl/bbl"; do
        if [ -f "$cand" ] && \
           [ "$(dd if="$cand" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
            bbl_elf="$cand"
            break
        fi
    done
    [ -n "$bbl_elf" ] || die "riscv-pk produced no ELF boot loader (looked in build/bbl and bbl/bbl)"
    log "boot loader ELF: $bbl_elf"
    # readelf pads addresses to the ELF class width (0x0000000080000000), so
    # compare numerically instead of as strings (the string compare rejected
    # a correct build once)
    norm_hex() { printf '0x%x' "$1" 2>/dev/null || printf '%s' "$1"; }
    bbl_entry="$(norm_hex "$(riscv64-linux-gnu-readelf -h "$bbl_elf" | awk '/Entry point address/{print $NF}')")"
    # lowest LOAD segment address = where a raw copy must be loaded
    bbl_load="$(norm_hex "$(riscv64-linux-gnu-readelf -l "$bbl_elf" | awk '$1=="LOAD"{print $3}' | sort | head -1)")"
    [ "$bbl_entry" = "0x80000000" ] || die "bbl entry $bbl_entry != 0x80000000 (reset address)"
    [ "$bbl_load" = "0x80000000" ] || die "bbl lowest LOAD addr $bbl_load != 0x80000000"
    riscv64-linux-gnu-objcopy -O binary "$bbl_elf" "$bbl_raw"
    if [ "$(dd if="$bbl_raw" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
        die "objcopy produced an ELF file"
    fi
    bbl_raw_bytes="$(stat -c %s "$bbl_raw")"
    [ "$bbl_raw_bytes" -gt 4096 ] || die "raw bbl is suspiciously small: $bbl_raw_bytes bytes"
    [ "$bbl_raw_bytes" -lt $((16 * 1024 * 1024)) ] || die "raw bbl is too big: $bbl_raw_bytes bytes"
    # firmware multi-hart evidence: the MAX_HARTS > 1 branch of
    # machine/mentry.S is the only thing that references disabled_hart_mask
    # from mentry.o, so its relocation proves the multi-hart IPI startup
    # path was compiled in (--with-arch=rv64gc => __riscv_atomic => MAX_HARTS 8)
    mentry_obj="$(find "$rpk" -name mentry.o -not -path '*/.git/*' 2>/dev/null | head -1)"
    if [ -n "$mentry_obj" ] && \
       riscv64-linux-gnu-readelf -r "$mentry_obj" 2>/dev/null | grep -q disabled_hart_mask; then
        fw_multi_hart="mentry.o relocates disabled_hart_mask (MAX_HARTS>1 IPI path present)"
    else
        fw_multi_hart="MISSING: no mentry.o disabled_hart_mask relocation (MAX_HARTS==1)"
    fi
    if [ -n "$mentry_obj" ] && \
       riscv64-linux-gnu-readelf -A "$mentry_obj" 2>/dev/null | grep -qi "atomic"; then
        fw_atomic="riscv-pk built with the A extension (__riscv_atomic)"
    else
        fw_atomic="riscv-pk A-extension attribute not reported"
    fi
    log "raw boot loader: $bbl_raw ($bbl_raw_bytes bytes, entry $bbl_entry); $fw_multi_hart"
    (
        cd "$out/riscv-linux-src"
        cp config_linux_riscv64 .config
        if [ "$smp" = 1 ]; then
            frag="$script_dir/config_linux_riscv64_smp.fragment"
            [ -f "$frag" ] || die "--smp fragment missing: $frag"
            # append, then let olddefconfig resolve dependencies/ordering
            cat "$frag" >> .config
        fi
        # HOSTCC and KCFLAGS get -fcommon: the pinned 4.15 tree has tentative
        # definitions (dtc's yylloc in the host tools, and similar patterns in
        # target code) that GCC 10+ rejects because it defaults to -fno-common.
        # Both must be make command-line variables: the kernel's Makefile
        # assigns HOSTCC itself, so an environment value would be discarded
        # (that mistake is retained in the eighth cloud build log).
        # The pinned 4.15 arch/riscv/Makefile builds -march from
        # KBUILD_ARCH_A/KBUILD_ARCH_C only, i.e. "rv64ac" (no 'i', no
        # zicsr): current binutils rejects csrs/csrc from that string
        # ("extension zicsr required", retained failure). Overriding those
        # two flag-only variables (they feed nothing else) produces the
        # canonical rv64imac_zicsr_zifencei / rv64imafdc_zicsr_zifencei,
        # which keeps the same instruction set and satisfies binutils.
        make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- \
            HOSTCC="${HOSTCC:-gcc} -fcommon" KCFLAGS=-fcommon \
            KBUILD_ARCH_A=ima KBUILD_ARCH_C=c_zicsr_zifencei olddefconfig
        # never hand out a boot pair that claims SMP but was configured
        # single-hart (the whole point of --smp)
        if [ "$smp" = 1 ]; then
            grep -q '^CONFIG_SMP=y$' .config || die "--smp build did not produce CONFIG_SMP=y"
            grep -q '^CONFIG_NR_CPUS=2$' .config || die "--smp build did not produce CONFIG_NR_CPUS=2"
        fi
        make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- \
            HOSTCC="${HOSTCC:-gcc} -fcommon" KCFLAGS=-fcommon \
            KBUILD_ARCH_A=ima KBUILD_ARCH_C=c_zicsr_zifencei -j"$jobs"
    ) >"$out/rebuild-riscv-linux.log" 2>&1 || {
        printf 'build-kernel-bbl: kernel rebuild failed; last lines:\n' >&2
        tail -c 4000 "$out/rebuild-riscv-linux.log" >&2 || true
        die "kernel rebuild failed (see rebuild-riscv-linux.log)"
    }
    # raw kernel image: TinyEMU loads the -kernel file as-is and bbl jumps
    # to the address the FDT records (riscv,kernel-start); an ELF kernel
    # would be executed from its header
    linux_img="$out/riscv-linux-src/arch/riscv/boot/Image"
    [ -f "$linux_img" ] || die "kernel build produced no arch/riscv/boot/Image"
    if [ "$(dd if="$linux_img" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
        die "arch/riscv/boot/Image is an ELF file, not the raw kernel image"
    fi
    cp "$linux_img" "$kernel_raw"
    kernel_bytes="$(stat -c %s "$kernel_raw")"
    kernel_ident="$(strings -a "$kernel_raw" | grep -m1 '^Linux version' || true)"
    {
        printf '\n## Rebuild outputs (this run)\n\n'
        printf 'bbl ELF (link output, NOT a boot file):\n'
        sha256sum "$bbl_elf" 2>/dev/null || true
        printf 'bbl RAW boot file (copy this one):\n'
        sha256sum "$bbl_raw" 2>/dev/null || true
        printf 'kernel raw Image (copy this one):\n'
        sha256sum "$kernel_raw" 2>/dev/null || true
        printf 'bbl ELF entry=%s lowest_load=%s\n' "$bbl_entry" "$bbl_load"
        printf 'firmware multi-hart: %s\nfirmware ABI/arch: %s\n' "$fw_multi_hart" "$fw_atomic"
        printf 'kernel version ident: %s\n' "$kernel_ident"
    } >>"$manifest"
    {
        printf 'boot pair built from pinned sources this run\n'
        printf 'bbl64.bin bytes=%s sha256=%s\n' "$bbl_raw_bytes" "$(sha256sum "$bbl_raw" | cut -d' ' -f1)"
        printf 'kernel-riscv64.bin bytes=%s sha256=%s\n' "$kernel_bytes" "$(sha256sum "$kernel_raw" | cut -d' ' -f1)"
        printf 'bbl ELF entry=%s lowest_load=%s\n' "$bbl_entry" "$bbl_load"
        printf 'firmware multi-hart: %s\nfirmware arch: %s\n' "$fw_multi_hart" "$fw_atomic"
        printf 'kernel version ident: %s\n' "$kernel_ident"
        printf 'kernel config sha256=%s\n' "$(sha256sum "$out/riscv-linux-src/.config" | cut -d' ' -f1)"
        grep -E '^CONFIG_(SMP|NR_CPUS|RISCV_INTC|RISCV_PLIC|RISCV_TIMER)=' \
            "$out/riscv-linux-src/.config" || true
    } >"$out/boot/BOOT-PAIR.txt"
    python3 - "$out/boot" "$bbl_entry" "$bbl_load" "$fw_multi_hart" \
              "$kernel_ident" <<'PY'
import hashlib, json, os, sys
root, entry, load, fw, ident = sys.argv[1:6]
def digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()
files = {}
for name in ("bbl64.bin", "kernel-riscv64.bin"):
    path = os.path.join(root, name)
    files[name] = {"bytes": os.path.getsize(path), "sha256": digest(path),
                   "raw_not_elf": open(path, "rb").read(4) != b"\x7fELF"}
json.dump({"files": files, "bbl_elf_entry": entry, "bbl_lowest_load": load,
           "firmware_multi_hart": fw, "kernel_version_ident": ident},
          open(os.path.join(root, "boot-files.json"), "w"), indent=2)
print(json.dumps({"files": files}, indent=2))
PY
    if [ "$smp" = 1 ]; then
        # the pair build-guest-image.sh --boot-dir expects, plus the
        # provenance a reviewer needs: config lines, firmware multi-hart
        # basis (rv64gc defines __riscv_atomic -> MAX_HARTS 8) and usage
        {
            printf '\n## Dual-hart (SMP) boot pair\n\n'
            printf 'kernel config: SMP=y NR_CPUS=2 (fragment config_linux_riscv64_smp.fragment)\n'
            printf 'firmware: riscv-pk --with-arch=rv64gc => __riscv_atomic => MAX_HARTS 8, mentry.S multi-hart IPI path\n'
            printf 'guest serial cross-check: this pair was produced by a cloud build; stdout is not evidence of a two-hart boot\n'
            printf 'multi-hart evidence: %s\n' "$fw_multi_hart"
            case "$fw_multi_hart" in
                MISSING*) die "--smp built a single-hart boot loader ($fw_multi_hart)" ;;
            esac
            grep -E '^CONFIG_(SMP|NR_CPUS|RISCV_INTC|RISCV_PLIC|RISCV_TIMER)=' \
                "$out/riscv-linux-src/.config" || true
            printf '\ninstall into a --boot-dir as: bbl64.bin and kernel-riscv64.bin from %s/boot\n' "$out"
            sha256sum "$bbl_raw" "$kernel_raw" 2>/dev/null || true
        } >"$out/SMP-BUILD.txt"
        log "wrote $out/SMP-BUILD.txt (dual-hart boot pair; use build-guest-image.sh --boot-dir $out/boot)"
    fi
fi

sha512sum "$manifest" >"$manifest.sha512"
log "wrote $manifest"
