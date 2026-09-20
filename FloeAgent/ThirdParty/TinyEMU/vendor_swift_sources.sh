#!/bin/bash
# vendor_swift_sources.sh — materialize the TinyEMU engine sources compiled
# by the SwiftPM C target `FloeTinyEMU` (declared in FloeAgent/Package.swift).
#
# The iOS app build must be deterministic and offline: Xcode/cloud CI cannot
# fetch bellard.org at build time, so the required subset of the pinned
# pristine TinyEMU 2019-12-21 tree is vendored into
# Sources/FloeTinyEMU/engine/ and committed. Provenance stays verifiable:
#
#   vendor_swift_sources.sh [pristine_dir]   (re)write the vendored tree
#   vendor_swift_sources.sh --check [pristine_dir]
#
# Both modes need the pristine extracted tree (sha256 pinned in
# fetch_source.sh / PROVENANCE.json). When omitted, the script uses
# ./fetch_source.sh to populate Local/Private/tinyemu-vendor/src (git-ignored).
#
# Vendored content rules:
#  - engine/ is byte-identical to the pristine tarball EXCEPT the files
#    carrying documented patches: riscv_machine.c (patches/0001),
#    fs_disk.c (patches/0002) and slirp/bootp.c (patches/0003, an upstream
#    typo that only compiles with DEBUG undefined). --check re-applies the
#    patches to the pristine copies and diffs, so a hand-edited vendored
#    file fails the check.
#  - adapter/floe_vm.{c,h} are symlinked from ../../adapter (single source).
#  - shims/ holds the Apple SDK compatibility headers from adapter/macos
#    (byteswap.h, sys/sysmacros.h, sys/statfs.h); patch 0002 replaced the
#    remaining -include shim. linux/if_tun.h is not needed (temu.c only).
#  - riscv_cpu.c is compiled twice via wrap/riscv_cpu32.c / wrap/riscv_cpu64.c
#    (MAX_XLEN 32/64), matching the qualification Makefile; SwiftPM excludes
#    the engine/ copy.
#
# Never edit hashes or patch verification to make a check pass.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/Sources/FloeTinyEMU"
ENGINE="$TARGET/engine"

MODE=write
if [ "${1:-}" = "--check" ]; then MODE=check; shift; fi
SRC="${1:-}"
if [ -z "$SRC" ]; then
  CACHE="$(cd "$HERE/../../.." && pwd)/Local/Private/tinyemu-vendor/src"
  if [ ! -d "$CACHE/tinyemu-2019-12-21" ]; then
    "$HERE/fetch_source.sh" "$CACHE"
  fi
  SRC="$CACHE/tinyemu-2019-12-21"
fi
[ -f "$SRC/VERSION" ] || { echo "ERROR: $SRC is not the extracted TinyEMU tree" >&2; exit 1; }

CORE="virtio.c pci.c fs.c cutils.c iomem.c simplefb.c json.c machine.c \
fs_disk.c softfp.c riscv_cpu.c riscv_machine.c \
cutils.h list.h virtio.h pci.h fs.h iomem.h machine.h json.h fs_utils.h \
softfp.h softfp_template.h softfp_template_icvt.h \
riscv_cpu.h riscv_cpu_priv.h riscv_cpu_template.h riscv_cpu_fp_template.h"
SLIRP="bootp.c ip_icmp.c mbuf.c slirp.c tcp_output.c cksum.c ip_input.c \
misc.c socket.c tcp_subr.c udp.c if.c ip_output.c sbuf.c tcp_input.c \
tcp_timer.c bootp.h debug.h if.h ip.h ip_icmp.h libslirp.h main.h mbuf.h \
misc.h sbuf.h slirp.h slirp_config.h socket.h tcp.h tcp_timer.h tcp_var.h \
tcpip.h tftp.h udp.h"

# files that differ from pristine by a documented patch: "<file>:<patch>"
PATCHED="riscv_machine.c:0001-htif-poweroff-callback.patch \
fs_disk.c:0002-fs_disk-apple-stat-timestamps.patch \
slirp/bootp.c:0003-slirp-bootp-debug-typo.patch"

# slirp declares its own BSD structs (ipovly/tcpcb/sbuf/udphdr/arphdr/icmp)
# whose tags collide with Darwin SDK umbrella-module headers when compiled
# with Clang modules (SwiftPM always enables them; the -fmodules-less
# qualification Makefile does not see this). The PCM is rebuilt with the
# consumer's flags, so -D renames cannot help; the vendored slirp sources
# therefore carry a mechanical token rename. The public slirp API
# (slirp_init/input/select_*/...) is untouched and the qualification build
# keeps compiling the same renamed tree. #include lines are never rewritten.
RENAMED_TAGS="ipovly tcpcb sbuf udphdr arphdr icmp tcpiphdr ipq ipasfrag udpiphdr ip mbuf tcphdr"

rename_slirp_tags() { # $1 = engine dir containing slirp/
  local d="$1/slirp" f t
  for f in "$d"/*.c "$d"/*.h; do
    for t in $RENAMED_TAGS; do
      perl -pi -e 's/\b'"$t"'\b/floe_slirp_'"$t"'/g unless /^\s*#\s*include/' "$f"
    done
  done
}

verify_slirp_tags() { # $1 = engine dir; fails if any unreplaced tag remains
  local bad="" t
  for t in $RENAMED_TAGS; do
    bad="$bad$(grep -rlnw -e "$t" "$1/slirp" 2>/dev/null | while read -r f; do
      grep -nw -e "$t" "$f" | grep -v '#include' | head -1 | sed "s|^|$f: |"
    done)"
  done
  if [ -n "$bad" ]; then echo "check FAIL: unreplaced slirp tags:"; echo "$bad"; return 1; fi
  return 0
}

sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else sha256sum "$1" | awk '{print $1}'; fi
}

is_patched() { case " $PATCHED " in (*" $1:"*) return 0;; (*) return 1;; esac; }

# SDK compatibility shims copied into the target (see header comment).
SHIMS="byteswap.h sys/statfs.h sys/sysmacros.h"

write_wrap_32() { # $1 = destination (default: SwiftPM target)
  local dest="${1:-$TARGET/wrap/riscv_cpu32.c}"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<'EOF'
/* SwiftPM compiles each source file exactly once, but upstream builds
 * riscv_cpu.c twice with -DMAX_XLEN=32/64 (see adapter/Makefile). These
 * wrappers reproduce that: the engine copy is excluded from the target and
 * included here with the width define set. Pristine source is unmodified. */
#define MAX_XLEN 32
#include "../engine/riscv_cpu.c"
EOF
}

write_wrap_64() { # $1 = destination (default: SwiftPM target)
  local dest="${1:-$TARGET/wrap/riscv_cpu64.c}"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<'EOF'
/* See riscv_cpu32.c. */
#define MAX_XLEN 64
#include "../engine/riscv_cpu.c"
EOF
}

materialize_scaffold() { # layout beside engine/: shims, wrap wrappers, adapter symlinks
  mkdir -p "$TARGET/shims/sys" "$TARGET/wrap" "$TARGET/adapter" "$TARGET/include"
  local f
  for f in $SHIMS; do cp "$HERE/adapter/macos/$f" "$TARGET/shims/$f"; done
  write_wrap_32
  write_wrap_64
  ln -sfn ../../../adapter/floe_vm.c "$TARGET/adapter/floe_vm.c"
  ln -sfn ../../../adapter/floe_vm.h "$TARGET/include/floe_vm.h"
}

if [ "$MODE" = "write" ]; then
  rm -rf "$ENGINE"
  mkdir -p "$ENGINE/slirp"
  for f in $CORE; do cp "$SRC/$f" "$ENGINE/$f"; done
  for f in $SLIRP; do cp "$SRC/slirp/$f" "$ENGINE/slirp/$f"; done
  for spec in $PATCHED; do
    f="${spec%%:*}"; p="${spec#*:}"
    patch -p1 -N --no-backup-if-mismatch -d "$ENGINE" < "$HERE/patches/$p" >/dev/null
    echo "patched: $f ($p)"
  done
  rm -f "$ENGINE"/*.orig "$ENGINE"/slirp/*.orig
  rename_slirp_tags "$ENGINE"
  verify_slirp_tags "$ENGINE" || exit 1
  echo "renamed: slirp tags ($RENAMED_TAGS) -> floe_slirp_*"
  materialize_scaffold
  echo "scaffold: shims + wrap/riscv_cpu32,64.c + adapter symlinks"
  # pristine hashes for --check (recorded for every vendored file)
  {
    for f in $CORE; do echo "$(sha "$SRC/$f")  $f"; done
    for f in $SLIRP; do echo "$(sha "$SRC/slirp/$f")  slirp/$f"; done
  } > "$HERE/VENDORED-SHA256SUMS.txt"
  echo "vendored $(echo $CORE $SLIRP | wc -w | tr -d ' ') files into $ENGINE"
  exit 0
fi

# --check: vendored tree == pristine + patches (read-only for the repo)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok=1
check_one() { # $1 relative vendored path, $2 pristine path
  local vendored="$ENGINE/$1" pristine="$SRC/$2"
  if [ ! -f "$vendored" ]; then echo "check FAIL: missing $1"; ok=0; return; fi
  local spec_patch="" t
  for spec in $PATCHED; do
    if [ "${spec%%:*}" = "$2" ] || [ "${spec%%:*}" = "$1" ]; then spec_patch="${spec#*:}"; fi
  done
  mkdir -p "$TMP/checktree/$(dirname "$1")"
  cp "$pristine" "$TMP/checktree/$1"
  if [ -n "$spec_patch" ]; then
    (cd "$TMP/checktree" && patch -p1 -N -r - --no-backup-if-mismatch < "$HERE/patches/$spec_patch") >/dev/null 2>&1 || true
  fi
  if [ "$1" != "${1#slirp/}" ]; then
    # slirp files additionally carry the floe_slirp_ tag rename
    for t in $RENAMED_TAGS; do
      perl -pi -e 's/\b'"$t"'\b/floe_slirp_'"$t"'/g unless /^\s*#\s*include/' "$TMP/checktree/$1"
    done
  fi
  if cmp -s "$TMP/checktree/$1" "$vendored"; then
    if [ -n "$spec_patch" ]; then echo "check ok: $1 (patch $spec_patch + rename)"; fi
  else
    echo "check FAIL: $1 != pristine + patches + rename"; ok=0
  fi
}
for f in $CORE; do check_one "$f" "$f"; done
for f in $SLIRP; do check_one "slirp/$f" "slirp/$f"; done
verify_slirp_tags "$ENGINE" || ok=0
# no stray files in engine/
stray=$(cd "$ENGINE" && find . -type f | sed 's|^\./||' | while read -r f; do
  case " $CORE " in (*" $f "*) continue;; esac
  case " $SLIRP " in (*" ${f#slirp/} "*) continue;; esac
  echo "$f"
done)
if [ -n "$stray" ]; then echo "check FAIL: stray files in engine/: $stray"; ok=0; fi
# scaffold: shims byte-identical to adapter/macos, wrappers exact, symlinks resolve
for f in $SHIMS; do
  if cmp -s "$HERE/adapter/macos/$f" "$TARGET/shims/$f"; then :; else echo "check FAIL: shims/$f != adapter/macos/$f"; ok=0; fi
done
write_wrap_32 "$TMP/wrap-riscv_cpu32.c"
if cmp -s "$TMP/wrap-riscv_cpu32.c" "$TARGET/wrap/riscv_cpu32.c"; then :; else echo "check FAIL: wrap/riscv_cpu32.c is not the generated wrapper"; ok=0; fi
write_wrap_64 "$TMP/wrap-riscv_cpu64.c"
if cmp -s "$TMP/wrap-riscv_cpu64.c" "$TARGET/wrap/riscv_cpu64.c"; then :; else echo "check FAIL: wrap/riscv_cpu64.c is not the generated wrapper"; ok=0; fi
if [ -L "$TARGET/adapter/floe_vm.c" ] && [ "$(readlink "$TARGET/adapter/floe_vm.c")" = "../../../adapter/floe_vm.c" ] && [ -f "$TARGET/adapter/floe_vm.c" ]; then :; else echo "check FAIL: adapter/floe_vm.c symlink"; ok=0; fi
if [ -L "$TARGET/include/floe_vm.h" ] && [ "$(readlink "$TARGET/include/floe_vm.h")" = "../../../adapter/floe_vm.h" ] && [ -f "$TARGET/include/floe_vm.h" ]; then :; else echo "check FAIL: include/floe_vm.h symlink"; ok=0; fi
if [ "$ok" = "1" ]; then echo "check ok: vendored engine matches pristine + documented patches"; fi
exit $((1-ok))
