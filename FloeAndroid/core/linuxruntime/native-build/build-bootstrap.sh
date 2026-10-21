#!/usr/bin/env bash
# Reproducible bootstrap producer for the linuxruntime launch transport.
# Canonical maintained helper: the Termux PRoot fork v5.1.107.98
# (https://github.com/termux/proot) + talloc 2.4.2 (static musl aarch64),
# the fork's loader packaged as libproot_loader.so, and the synthetic probe
# helper.
#
# Source inputs are the pinned upstream archives in PINS.md plus the
# reviewed deltas in this directory (compat/queue.h, compat/musl-compat.h,
# config templates, cross/ shims). The ONLY upstream file edit is exactly
# one captured patch, patches/tracee-event-exitkill.patch: it adds
# PTRACE_O_EXITKILL to tracee/event.c's default_ptrace_options so a
# process-group kill at PTY cancellation also reaps interactive/detached
# children that changed process groups. Both PTRACE_SETOPTIONS attempts in
# event.c keep the option, and if a kernel ever rejects it the second
# attempt fails closed (proot exits nonzero) -- no silent fallback drops
# EXITKILL. The patch is part of the complete corresponding source; the
# file keeps its original GPL-2.0-or-later notice untouched.
#
# Lineage: the generic proot-me v5.5.0 producer delivered earlier is
# superseded as the final helper. Device evidence (Main A10-A13,
# Local/Private/android-g03-20261022/r1) showed the generic build installs
# an outer seccomp even with CHECK_FEATURES empty and never intercepts the
# loader open (ENOENT, not an mmap denial), and glibc guests then die on
# inherited Android SIGSYS (set_robust_list; rseq tunables alone do not
# help). The maintained Termux fork handles the Android outer-seccomp
# SIGSYS lineage correctly (A14 proved real Linux guest success on the
# target37/16KiB App-UID cohort with the fork built here).
#
# Binaries are NEVER written into the repository source tree or jniLibs.
# Output goes to a caller-provided artifact directory (Git-ignored private
# scope). Integration of payloads into src/main/jniLibs remains Main's step.
#
# Usage:
#   bash FloeAndroid/core/linuxruntime/native-build/build-bootstrap.sh \
#     [--out DIR] [--cache DIR] [--work DIR] [--jobs N]
#
# Defaults (out/cache are repository-private; work is on the internal SSD):
#   out   = <repo>/Local/Scratch/floe-linuxruntime-bootstrap/out
#   cache = <repo>/Local/Scratch/floe-linuxruntime-bootstrap/dl
#   work  = $FLOE_ANDROID_CACHE_ROOT/floe-linuxruntime-bootstrap/work
#   jobs  = 6
#
# The work tree MUST be whitespace-free: PRoot's GNUmakefile interpolates
# VPATH/SRC-derived paths and env CFLAGS strings into recipes WITHOUT
# quoting (verified failure mode in r1/termux-bootstrap/build-second.log:
# the "IOS AI AGENT" volume path split into `/bin/sh: /Volumes/TECLAST-512/
# IOS: Permission denied` hundreds of times while make still exited 0), so
# the work tree defaults to the no-space cache root. The producer rejects any
# whitespace-containing work path outright -- no /tmp symlink workaround is
# ever created. Destructively reset directories (the work tree and the
# evidence export under OUT) must be fresh/empty or carry this producer's
# ownership marker; nonempty unmarked contents are never auto-adopted.
# Binaries and relink/reproducibility evidence are exported
# into the repository-owned OUT directory.
set -euo pipefail

NB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd "$NB_DIR/.." && pwd -P)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd -P)"

# shellcheck source=FloeAndroid/scripts/env.sh
source "$REPO_ROOT/FloeAndroid/scripts/env.sh"
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
BIN="$TOOLCHAIN/bin"

OUT="${FLOE_LINUXRUNTIME_OUT:-$REPO_ROOT/Local/Scratch/floe-linuxruntime-bootstrap/out}"
CACHE="${FLOE_LINUXRUNTIME_CACHE:-$REPO_ROOT/Local/Scratch/floe-linuxruntime-bootstrap/dl}"
WORK="${FLOE_LINUXRUNTIME_WORK:-}"
JOBS="${FLOE_LINUXRUNTIME_JOBS:-6}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --cache) CACHE="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd -P)"
if [[ "$OUT" == *jniLibs* || "$OUT" == "$MODULE_DIR/src" || "$OUT" == "$MODULE_DIR/src/"* \
      || "$OUT" == "$NB_DIR" || "$OUT" == "$NB_DIR/"* ]]; then
  echo "refusing to emit binaries into the module source/native-build tree: $OUT" >&2
  exit 2
fi
mkdir -p "$CACHE"

# ---------------------------------------------------------------------------
# Pins (see PINS.md for origins, licenses and obligations).
# ---------------------------------------------------------------------------
PROOT_URL="https://github.com/termux/proot/archive/v5.1.107.98.zip"
PROOT_SHA="9de61bddd6f5016d065e2755b72ff4747290e5f992562f031785b107b51d02ba"
PROOT_TOPDIR="proot-5.1.107.98"
PROOT_FILENAME="proot-v5.1.107.98.zip"
TALLOC_URL="https://download.samba.org/pub/talloc/talloc-2.4.2.tar.gz"
TALLOC_SHA="85ecf9e465e20f98f9950a52e9a411e14320bc555fa257d87697b7e7a9b1d8a6"
ZIG_URL="https://ziglang.org/download/0.14.1/zig-aarch64-macos-0.14.1.tar.xz"
ZIG_SHA="39f3dc5e79c22088ce878edc821dedb4ca5a1cd9f5ef915e9b3cc3053e8faefa"
ZIG_DIRNAME="zig-aarch64-macos-0.14.1"

QUEUE_ADAPTED_SHA="2f17fe601093b9f3733045442213603973e906a255de87926a0022927a0f79c9"
MUSL_COMPAT_SHA="6e25a7aee80088871397b2672f22edb5cf6dea122169003354dba570ba966e58"
TALLOC_CONFIG_SHA="7b199b5bfcaebc67842e4111d62c7cb2f18eb70524c971aebc31fa5b6aaec85b"
CROSS_ANSWERS_SHA="b63b7f7805f4bc231b1e5ba4465003f26ce954a63bc0e9496c8027fe85ae4b07"
EXITKILL_PATCH_SHA="7e512b801861e520d9449025daab07261e74ea0a002ae545c9fd529e24ca48ca"
EVENT_C_BEFORE_SHA="69041eb86eaf34e3cbc12d3b741fb231ef18be7451ca7ac5bd766cf9cbcc34fa"
EVENT_C_AFTER_SHA="7eea115f58c7fd3ed0b9583cf35d9f6b7d666d21074a9784534d7bac092c0f7b"
# Deterministic rule outputs of the pinned tree on the pinned toolchain.
BUILD_H_SHA="60dd78f83b02c4bbb3525be31f9226151ab508f342ca71346b862483b07984ed"
LOADER_INFO_C_SHA="5870a6f1a1634f9fc5885e92cfd49da7b71e5f9ffbc9d0ec995bf4d95a744a6d"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
die() { echo "ERROR: $*" >&2; exit 1; }
check_sha() { [[ "$(sha "$1")" == "$2" ]] || die "sha256 mismatch for $1 (expected $2)"; }

# Ownership rule for every directory this producer destructively resets:
# fresh/empty directories are adopted (marker created); a nonempty
# directory is only reset when it already carries this producer's marker;
# nonempty unmarked contents are NEVER auto-adopted. The marker is kept
# across the reset.
OWN_MARK=".floe-linuxruntime-owned"
reset_owned_dir() { # dir purpose
  local d="$1" purpose="$2"
  [[ -d "$d" ]] || mkdir -p "$d"
  if [[ -n "$(ls -A "$d" 2>/dev/null)" && ! -f "$d/$OWN_MARK" ]]; then
    die "refusing to reset the nonempty $purpose directory '$d': it does not carry this producer's ownership marker ($OWN_MARK). Point the run at a fresh/empty dedicated directory."
  fi
  rm -rf "${d:?}"
  mkdir -p "$d"
  printf 'owned by FloeAndroid/core/linuxruntime/native-build/build-bootstrap.sh (%s); recreated on every run\n' "$purpose" > "$d/$OWN_MARK"
}

# ---------------------------------------------------------------------------
# 1. Fetch + verify pinned inputs into the task cache (reuse if present).
# ---------------------------------------------------------------------------
fetch() { # name url sha
  local f="$CACHE/$1"
  if [[ -f "$f" ]] && sha "$f" | grep -qx "$3"; then
    echo "cache hit: $f"
    return
  fi
  echo "fetching $2"
  curl -fL --retry 2 --max-time 600 -o "$f.part" "$2"
  check_sha "$f.part" "$3"
  mv "$f.part" "$f"
}
fetch "$PROOT_FILENAME" "$PROOT_URL" "$PROOT_SHA"
fetch talloc-2.4.2.tar.gz "$TALLOC_URL" "$TALLOC_SHA"
fetch zig-aarch64-macos-0.14.1.tar.xz "$ZIG_URL" "$ZIG_SHA"

# ---------------------------------------------------------------------------
# 2. Work tree: whitespace-free, producer-owned, recreated on every run.
#    (See header: PRoot's GNUmakefile word-splits whitespace paths while
#    still exiting 0 -- the build path is a correctness boundary.)
# ---------------------------------------------------------------------------
if [[ -z "$WORK" ]]; then
  [[ -n "${FLOE_ANDROID_CACHE_ROOT:-}" ]] || die "FLOE_ANDROID_CACHE_ROOT is not set (env.sh defines it on the internal SSD); pass --work DIR"
  WORK="$FLOE_ANDROID_CACHE_ROOT/floe-linuxruntime-bootstrap/work"
fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
case "$WORK" in
  *[[:space:]]*)
    die "unsupported work path: '$WORK' contains whitespace, which PRoot's GNUmakefile word-splits into failing recipes (verified in r1/termux-bootstrap/build-second.log). Pass --work DIR (or set FLOE_LINUXRUNTIME_WORK / FLOE_ANDROID_CACHE_ROOT) to a whitespace-free absolute path. No /tmp symlink workaround is created." ;;
  /|"$HOME"|"$REPO_ROOT"|"$MODULE_DIR"|"$NB_DIR"|"$CACHE")
    die "refusing to use '$WORK' as the producer work tree (this directory is recreated on every run); pass --work DIR, a producer-owned build directory." ;;
esac
reset_owned_dir "$WORK" "GNUmake work tree"
mkdir -p "$OUT/lib"
PREFIX_MAP="-ffile-prefix-map=$WORK=/floe-linuxruntime-bootstrap"

unzip -q -o "$CACHE/$PROOT_FILENAME" -d "$WORK"
tar xzf "$CACHE/talloc-2.4.2.tar.gz" -C "$WORK"
PROOT_SRC="$WORK/$PROOT_TOPDIR"
TALLOC_SRC="$WORK/talloc-2.4.2"
[[ -f "$PROOT_SRC/src/GNUmakefile" ]] || die "Termux PRoot tree not extracted at $PROOT_SRC"

# Reviewed deltas: verify vendored inputs byte-exactly before use.
check_sha "$NB_DIR/compat/queue.h" "$QUEUE_ADAPTED_SHA"
check_sha "$NB_DIR/compat/musl-compat.h" "$MUSL_COMPAT_SHA"
check_sha "$NB_DIR/config/talloc-config.h" "$TALLOC_CONFIG_SHA"
check_sha "$NB_DIR/config/talloc-cross-answers.txt" "$CROSS_ANSWERS_SHA"
check_sha "$NB_DIR/patches/tracee-event-exitkill.patch" "$EXITKILL_PATCH_SHA"

# The one pinned upstream edit (recorded in provenance + corresponding source).
check_sha "$PROOT_SRC/src/tracee/event.c" "$EVENT_C_BEFORE_SHA"
( cd "$PROOT_SRC" && patch -p1 --silent -i "$NB_DIR/patches/tracee-event-exitkill.patch" ) \
  || die "EXITKILL patch did not apply cleanly to the pinned tree (event.c before-sha matched, so this is tooling drift, not upstream drift)"
check_sha "$PROOT_SRC/src/tracee/event.c" "$EVENT_C_AFTER_SHA"
cp "$NB_DIR/compat/musl-compat.h" "$WORK/musl-compat.h"

# ---------------------------------------------------------------------------
# 3. Zig toolchain from cache (build host tool only; never installed globally).
# ---------------------------------------------------------------------------
if [[ ! -x "$CACHE/$ZIG_DIRNAME/zig" ]]; then
  tar xJf "$CACHE/zig-aarch64-macos-0.14.1.tar.xz" -C "$CACHE"
fi
ZIG_BIN="$CACHE/$ZIG_DIRNAME/zig"
"$ZIG_BIN" version | grep -qx 0.14.1 || die "zig version mismatch"

# ---------------------------------------------------------------------------
# 4. Cross shims: copies of the reviewed scripts, wired by environment only.
#    cross/readelf answers the makefile's bare `readelf -s` in the
#    loader-info.c rule (verified lineage: forwards to NDK llvm-readobj;
#    loader-info.awk's field semantics were validated through it).
# ---------------------------------------------------------------------------
CROSS="$WORK/cross-bin"
mkdir -p "$CROSS"
cp "$NB_DIR"/cross/* "$CROSS/"
chmod +x "$CROSS"/*
export FLOE_LINUXRUNTIME_ZIG="$ZIG_BIN"
export FLOE_LINUXRUNTIME_LLD="$BIN/ld.lld"
export FLOE_LINUXRUNTIME_OBJCOPY="$BIN/llvm-objcopy"
export FLOE_LINUXRUNTIME_OBJDUMP="$BIN/llvm-objdump"
export FLOE_LINUXRUNTIME_READOBJ="$BIN/llvm-readobj"

# ---------------------------------------------------------------------------
# 5. talloc 2.4.2 hand-built static (musl cross): two TUs + deterministic
#    archive + staged headers (pure BSD-3 sys/queue.h for <sys/queue.h>).
#    Version defines MAJOR/MINOR/RELEASE=2/4/2 and
#    -D__STDC_WANT_LIB_EXT1__=1 (hard requirement in lib/replace/replace.h)
#    reproduce the verified archive: talloc_magic in the qualification
#    libtalloc.a reads 0xea18ee70 (byte-recovered 2026-10-22).
# ---------------------------------------------------------------------------
PREFIX="$WORK/talloc-install"
mkdir -p "$PREFIX/include/sys" "$PREFIX/lib/pkgconfig"
cp "$NB_DIR/config/talloc-config.h" "$TALLOC_SRC/config.h"
cp "$NB_DIR/compat/queue.h" "$PREFIX/include/sys/queue.h"
cp "$TALLOC_SRC/talloc.h" "$PREFIX/include/talloc.h"
sed "s|@TALLOC_PREFIX@|$PREFIX|g" "$NB_DIR/config/talloc.pc.in" > "$PREFIX/lib/pkgconfig/talloc.pc"
export FLOE_LINUXRUNTIME_TALLOC_PREFIX="$PREFIX"

TALLOC_DEFS=(-D__STDC_WANT_LIB_EXT1__=1 -DTALLOC_BUILD_VERSION_MAJOR=2 -DTALLOC_BUILD_VERSION_MINOR=4 -DTALLOC_BUILD_VERSION_RELEASE=2)
CCMUSL="$CROSS/aarch64-linux-musl-gcc"
(
  cd "$TALLOC_SRC"
  "$CCMUSL" -c -O2 -g -D_GNU_SOURCE "${TALLOC_DEFS[@]}" "${PREFIX_MAP}" -I. -Ilib/replace \
    talloc.c -o "$WORK/talloc.o"
  "$CCMUSL" -c -O2 -g -D_GNU_SOURCE "${TALLOC_DEFS[@]}" "${PREFIX_MAP}" -I. -Ilib/replace \
    lib/replace/replace.c -o "$WORK/replace.o"
)
( cd "$WORK" && "$BIN/llvm-ar" rcSD "$PREFIX/lib/libtalloc.a" talloc.o replace.o )
"$BIN/llvm-ar" -t "$PREFIX/lib/libtalloc.a" > "$WORK/libtalloc.members.txt"

# ---------------------------------------------------------------------------
# 6. Termux PRoot fork via its own GNUmakefile. Recipe deltas vs a native
#    build (all captured from the verified qualification run,
#    r1/termux-bootstrap build logs + internal work tree, 2026-10-22):
#   - CROSS_COMPILE -> our zig-based musl shims in $CROSS
#   - HAS_LOADER_32BIT= : ARM64-only. The arch probe otherwise auto-enables
#     the m32 loader blob; the verified payload links with
#     _binary_loader_m32_exe_* as weak-UNDEFINED symbols (no m32 blob), so
#     forcing empty is what reproduces it.
#   - CHECK_FEATURES="" : feature probes cannot RUN under cross, and the
#     makefile's `.check_%.res` rule marks a capability when the probe
#     binary merely EXISTS (compiled), which silently "detects"
#     HAVE_PROCESS_VM/HAVE_SECCOMP_FILTER from a non-runnable cross binary.
#     An empty list makes build.h carry no defines; capabilities are instead
#     declared explicitly below.
#   - env CFLAGS += :
#       * -D_LARGEFILE64_SOURCE  (musl exposes struct rlimit64/statfs64 +
#         prlimit64/statfs64 aliases only under it; the fork's own CPPFLAGS
#         only sets _GNU_SOURCE -- this was the real run-3 failure)
#       * -DHAVE_SECCOMP_FILTER -DHAVE_PROCESS_VM (cross feature
#         capabilities: Android min28 kernels support both; explicit
#         instead of the broken probe; build.h stays define-free so there
#         is no redefinition)
#       * -include $WORK/musl-compat.h (musl lacks glibc's
#         TEMP_FAILURE_RETRY; MSG_COPY guarded here for sysvipc TUs)
#       * -I$PREFIX/include (talloc.h + staged BSD sys/queue.h; the fork
#         makefile has NO pkg-config query -- unlike proot-me v5.5.0 --
#         so the include path must come from here)
#       * -ffile-prefix-map (determinism)
#   - env LDFLAGS += -L$PREFIX/lib (fork links plain -ltalloc)
#   - flags travel via the ENVIRONMENT, never on the make command line:
#     command-line variables override the makefile's own `CPPFLAGS +=` /
#     `CFLAGS +=`, which would silently drop -D_GNU_SOURCE and expose
#     exactly the incomplete-type errors seen in run 3.
#   - PATH gets $CROSS prepended so the loader-info.c rule finds readelf.
#   - CC is passed on the make command line: the fork makefile uses
#     `CC ?= $(CROSS_COMPILE)gcc`, and GNU make's `?=` never replaces the
#     built-in default `CC=cc` (origin "default" is not "undefined").
#     Without an explicit CC every TU silently compiles with the host
#     macOS cc, which has no <linux/*> headers -- observed during this
#     repair round (producer run 3): make still exited 0 thanks to
#     .IGNORE, and only the artifact gates below caught it. The verified
#     qualification build passed its compiler explicitly. LD = $(CC)
#     follows the shim; STRIP/OBJCOPY/OBJDUMP have no make defaults, so
#     CROSS_COMPILE alone resolves them.
#   - ARG_MAX needs no define: 131072 comes from the pinned linux/limits.h.
#   - WITHOUT_PYTHON/CHECK_VERSION are proot-me v5.5.0 knobs; this fork
#     makefile has neither a Python branch nor a git version override knob.
# ---------------------------------------------------------------------------
MAKE_LOG="$WORK/proot-make.log"
(
  cd "$PROOT_SRC/src"
  env CFLAGS="$PREFIX_MAP -D_LARGEFILE64_SOURCE -DHAVE_SECCOMP_FILTER -DHAVE_PROCESS_VM -include $WORK/musl-compat.h -I$PREFIX/include" \
      LDFLAGS="-L$PREFIX/lib" \
      PATH="$CROSS:$PATH" \
      make -f "$PROOT_SRC/src/GNUmakefile" \
        CC="$CROSS/aarch64-linux-musl-gcc" \
        CROSS_COMPILE="$CROSS/aarch64-linux-musl-" \
        HAS_LOADER_32BIT= \
        CHECK_FEATURES="" \
        -j"$JOBS"
) >"$MAKE_LOG" 2>&1 || { tail -n 40 "$MAKE_LOG" >&2; die "proot make exited nonzero (see $MAKE_LOG)"; }

# The fork GNUmakefile routes error-prone rules through `.IGNORE` scopes and
# the verified space-path failure run proved make can exit 0 while compiles
# failed. Trust artifacts, never just the exit code:
if grep -nE "error:|Error [0-9]|Permission denied|command not found|No such file|fatal error" "$MAKE_LOG" >"$WORK/make-error-lines.txt"; then
  cat "$WORK/make-error-lines.txt" >&2
  die "proot build logged failing recipes although make may have exited 0 (see $MAKE_LOG)"
fi

# Exact clean object set: every .o the pinned recipe must produce, and
# nothing stale (the m32 set must be absent with HAS_LOADER_32BIT=).
expected="$(awk '/OBJECTS \+=/,/[^\\]$/' "$PROOT_SRC/src/GNUmakefile" \
  | grep -oE '[A-Za-z0-9_./-]+\.o' | LC_ALL=C grep -v -- '-m32'
  printf 'loader/loader.o\nloader/assembly.o\n')"
expected="$(printf '%s\n' "$expected" | grep -oE '[A-Za-z0-9_./-]+\.o' | LC_ALL=C sort -u)"
actual="$( cd "$PROOT_SRC/src" && find . -name '*.o' | sed 's|^\./||' | LC_ALL=C sort )"
[[ "$expected" == "$actual" ]] || { LC_ALL=C comm -3 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2; die "built object set differs from the pinned recipe expectation (only-in-expected '<', only-in-actual '>')"; }

# Deterministic rule outputs of the verified lineage:
check_sha "$PROOT_SRC/src/build.h" "$BUILD_H_SHA"
check_sha "$PROOT_SRC/src/loader/loader-info.c" "$LOADER_INFO_C_SHA"
[[ -f "$PROOT_SRC/src/loader/loader-wrapped.o" ]] || die "loader-wrapped.o missing: embedded loader step failed"

# ---------------------------------------------------------------------------
# 7. Synthetic probe helper: same pinned NDK command as build-probe.sh, but
#    emitted into OUT only (jniLibs payloads are NOT touched here).
# ---------------------------------------------------------------------------
"$BIN/aarch64-linux-android28-clang" \
  -static -O2 -Wall -Wextra \
  -ffunction-sections -fdata-sections \
  -Wl,--gc-sections \
  -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 \
  -Wl,-z,noexecstack -Wl,--build-id=sha1 \
  -o "$OUT/lib/libfloeprobe.so" \
  "$MODULE_DIR/src/main/cpp/floe_probe.c"

# ---------------------------------------------------------------------------
# 8. Package outputs (static ELF channel: installed APK native lib dir).
#    libproot.so            = Termux-fork PRoot + talloc static musl binary
#                             (EXITKILL-patched tracee/event.c)
#    libproot_loader.so     = standalone fork loader ELF (separate payload
#                             from the copy embedded in libproot.so). Run
#                             the guest with PROOT_LOADER="$NATIVE_LIBRARY
#                             _DIR/libproot_loader.so" when the embedded
#                             copy must be bypassed (see PINS.md).
# ---------------------------------------------------------------------------
cp "$PROOT_SRC/src/proot" "$OUT/lib/libproot.so"
cp "$PROOT_SRC/src/loader/loader" "$OUT/lib/libproot_loader.so"

# ---------------------------------------------------------------------------
# 9. Verification (static inspection; device proof stays with Main).
# ---------------------------------------------------------------------------
verify_elf() { # file label
  local f="$1" label="$2" hdr segs load_count al
  hdr="$("$BIN/llvm-readelf" -h "$f")"
  echo "$hdr" | grep -q "AArch64" || die "$label: not AArch64"
  echo "$hdr" | grep -q "EXEC" || die "$label: not an EXEC (static) ELF"
  # -lW (wide): each program-header row stays on ONE line so the final
  # column is Align. Wrapped `-l` can fold the row and leave p_paddr at
  # the line end, which a naive `awk '/LOAD/{print $NF}'` would then
  # compare against 16KiB. Assert a nonzero parsed LOAD count first: a
  # static EXEC ELF always has LOAD segments, so zero means the parse
  # (or the file) is wrong, never a silent pass.
  segs="$("$BIN/llvm-readelf" -lW "$f")"
  load_count="$(printf '%s\n' "$segs" | awk '$1 == "LOAD" { n++ } END { print n + 0 }')"
  [[ "$load_count" -ge 1 ]] || die "$label: llvm-readelf -lW parsed 0 LOAD segments"
  while read -r al; do
    [[ "$al" == 0x* ]] || die "$label: unexpected Align field '$al' in a LOAD row"
    [[ "$((16#${al#0x}))" -ge 16384 ]] || die "$label: LOAD alignment $al < 16KiB"
  done < <(printf '%s\n' "$segs" | awk '$1 == "LOAD" { print $NF }')
  if "$BIN/llvm-readelf" -d "$f" 2>/dev/null | grep -q "Dynamic section"; then
    die "$label: unexpectedly dynamic (must be fully static)"
  fi
  echo "verify PASS: $label ($f: AArch64 EXEC, static, $load_count LOAD segments, all align >= 16KiB)"
}
verify_elf "$OUT/lib/libproot.so" libproot.so
verify_elf "$OUT/lib/libproot_loader.so" libproot_loader.so
"$BIN/llvm-readelf" -h "$OUT/lib/libfloeprobe.so" | grep -q "AArch64" || die "probe not AArch64"
echo "verify PASS: libfloeprobe.so (static bionic, NDK r30 flags, 16KiB linker default)"

# Link-shape gate: the verified payload embeds the ARM64 loader blob and
# references the m32 blob only as weak-UNDEFINED symbols (proves
# HAS_LOADER_32BIT= was honored), and carries the pokedata constant.
nmsyms="$("$BIN/llvm-nm" "$OUT/lib/libproot.so")"
echo "$nmsyms" | grep -qE ' [DdRrBb] _binary_loader_exe_start$' || die "libproot.so: embedded loader blob symbol missing"
echo "$nmsyms" | grep -qE '^ +w _binary_loader_m32_exe_start$'  || die "libproot.so: _binary_loader_m32_exe_start must be weak-undefined (HAS_LOADER_32BIT= ARM64-only link)"
echo "$nmsyms" | grep -qE ' offset_to_pokedata_workaround$'     || die "libproot.so: loader-info pokedata constant missing"

# No Apple/SDK header may appear among the actual BUILD INPUTS (the
# .patch/prose records may legitimately *describe* the rejected header):
if grep -l "APPLE_OSREFERENCE_LICENSE\|APSL" \
    "$NB_DIR/compat/queue.h" "$NB_DIR/compat/musl-compat.h" \
    "$NB_DIR"/config/* "$NB_DIR"/cross/*; then
  die "Apple-licensed header found in recipe build inputs"
fi
echo "verify PASS: recipe inputs contain no Apple SDK header"

# ---------------------------------------------------------------------------
# 9b. Export relink/reproducibility evidence into the repository-owned OUT
#     (the work tree itself stays in the whitespace-free cache root):
#     talloc objects + deterministic archive + staged prefix prove the
#     LGPL-3.0 static-link relink path; the full .o set, generated files,
#     the patched source and the make log pin "exact clean outputs".
#     (loader.elf/loader.exe is a deleted GNU-make .INTERMEDIATE; the
#     loader-wrapped.o under proot-objects/ carries its embedded bytes.)
# ---------------------------------------------------------------------------
EVID="$OUT/build"
reset_owned_dir "$EVID" "relink/reproducibility evidence export"
mkdir -p "$EVID/proot-objects" "$EVID/generated/loader" "$EVID/patched"
cp "$WORK/talloc.o" "$WORK/replace.o" "$WORK/libtalloc.members.txt" "$EVID/"
cp -a "$PREFIX" "$EVID/talloc-install"
[[ -f "$EVID/talloc-install/lib/libtalloc.a" ]] || die "relink evidence missing: libtalloc.a"
while IFS= read -r o; do
  rel="${o#"$PROOT_SRC/src/"}"
  mkdir -p "$EVID/proot-objects/$(dirname "$rel")"
  cp "$o" "$EVID/proot-objects/$rel"
done < <(find "$PROOT_SRC/src" -name '*.o')
cp "$PROOT_SRC/src/build.h" "$EVID/generated/build.h"
cp "$PROOT_SRC/src/loader/loader-info.c" "$EVID/generated/loader/loader-info.c"
cp "$PROOT_SRC/src/tracee/event.c" "$EVID/patched/event.c"
cp "$MAKE_LOG" "$EVID/proot-make.log"
echo "evidence: exported to $EVID (talloc objects/archive/prefix, $(printf '%s\n' "$actual" | grep -c . ) proot .o files, generated files, patched source, make log)"

# ---------------------------------------------------------------------------
# 10. Deterministic manifest + provenance. Byte-equality with the pre-
#     EXITKILL verification payloads (r1/termux-bootstrap/PAYLOAD_INITIAL
#     .json: libproot.so db8968b9..., libproot_loader.so 3ef215b1...) is
#     NOT promised: libproot.so intentionally differs by the pinned patch
#     and by -ffile-prefix-map path normalization; the loader is expected
#     byte-equal (the patch does not touch loader sources).
# ---------------------------------------------------------------------------
( cd "$OUT" && find lib -type f | LC_ALL=C sort | xargs shasum -a 256 > "$OUT/MANIFEST.sha256" )

RECIPE_SHA="$( cd "$NB_DIR" && find build-bootstrap.sh PINS.md compat config cross patches -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1 )"
ZIG_VER="$("$ZIG_BIN" version)"
NDK_CLANG_VER="$("$BIN/clang" --version | head -1)"
python3 - "$OUT" "$RECIPE_SHA" "$ZIG_VER" "$NDK_CLANG_VER" "$PREFIX_MAP" <<'PY'
import json, sys, datetime
out, recipe_sha, zig_ver, clang_ver, prefix_map = sys.argv[1:6]
manifest = {}
for line in open(f"{out}/MANIFEST.sha256"):
    h, p = line.split()
    manifest[p] = h
prov = {
  "generated_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "producer": "FloeAndroid/core/linuxruntime/native-build/build-bootstrap.sh",
  "recipe_tree_sha256": recipe_sha,
  "canonical_source": "Termux-maintained PRoot fork v5.1.107.98 (supersedes the generic proot-me v5.5.0 baseline; A14 proved fork-based Linux guest success on target37/Android17/16KiB)",
  "toolchain": {"zig": zig_ver, "ndk_clang": clang_ver, "android_ndk": "30.0.16248370"},
  "pins": {
    "proot": {"url": "https://github.com/termux/proot/archive/v5.1.107.98.zip",
              "tarball_sha256": "9de61bddd6f5016d065e2755b72ff4747290e5f992562f031785b107b51d02ba"},
    "talloc": {"url": "https://download.samba.org/pub/talloc/talloc-2.4.2.tar.gz",
               "tarball_sha256": "85ecf9e465e20f98f9950a52e9a411e14320bc555fa257d87697b7e7a9b1d8a6"},
    "zig": {"url": "https://ziglang.org/download/0.14.1/zig-aarch64-macos-0.14.1.tar.xz",
            "tarball_sha256": "39f3dc5e79c22088ce878edc821dedb4ca5a1cd9f5ef915e9b3cc3053e8faefa"},
    "queue_header": {"origin": "Android NDK 30.0.16248370 sysroot /usr/include/sys/queue.h"
                      " (byte-identical to AOSP bionic libc/include/sys/queue.h"
                      " at tag android-16.0.0_r1)",
                     "license": "BSD-3-Clause (Regents), full notice preserved",
                     "original_sha256": "09ee5ac8c68c0498a4f8ce93a5d0e989959f5d43a3fbe28f7b42fa1381828c8f",
                     "adapted_sha256": "2f17fe601093b9f3733045442213603973e906a255de87926a0022927a0f79c9",
                     "adaptation": "one line: #include <sys/cdefs.h> -> #include <stddef.h> (musl has no sys/cdefs.h; header uses no cdefs macros)"},
    "musl_compat_header": {"sha256": "6e25a7aee80088871397b2672f22edb5cf6dea122169003354dba570ba966e58",
                           "role": "Floe-authored build-time compat (-include): musl lacks TEMP_FAILURE_RETRY; MSG_COPY guarded; contents carried verbatim from the verified internal qualification tree plus a __ASSEMBLER__ guard required by a full clean rebuild (loader/assembly.S cannot parse errno.h's C declarations; the verified incremental build only ever -include'd this header into C TUs)"},
    "talloc_config": {"sha256": "7b199b5bfcaebc67842e4111d62c7cb2f18eb70524c971aebc31fa5b6aaec85b"},
    "talloc_cross_answers": {"sha256": "b63b7f7805f4bc231b1e5ba4465003f26ce954a63bc0e9496c8027fe85ae4b07"}
  },
  "patches": {
    "tracee-event-exitkill": {
      "file": "patches/tracee-event-exitkill.patch", "sha256": "7e512b801861e520d9449025daab07261e74ea0a002ae545c9fd529e24ca48ca",
      "target": "src/tracee/event.c",
      "before_sha256": "69041eb86eaf34e3cbc12d3b741fb231ef18be7451ca7ac5bd766cf9cbcc34fa",
      "after_sha256": "7eea115f58c7fd3ed0b9583cf35d9f6b7d666d21074a9784534d7bac092c0f7b",
      "purpose": "add PTRACE_O_EXITKILL to default_ptrace_options so cancellation kills interactive/detached children that changed process groups; both PTRACE_SETOPTIONS attempts retain it and fail closed (exit nonzero) on unsupported kernels",
      "obligations": "original GPL-2.0-or-later file notice preserved; patch included in complete corresponding source"
    }
  },
  "source_deltas": "exactly one pinned patch (tracee-event-exitkill, above); all other upstream trees pristine; deltas are otherwise env/flags + vendored build-time headers/config templates",
  "proot_build_flags": {
    "make_args": {"CC": "<work>/cross-bin/aarch64-linux-musl-gcc (explicit: GNU-make built-in CC=cc would otherwise defeat the makefile's `CC ?=`)", "CROSS_COMPILE": "zig-cc aarch64-linux-musl shims (STRIP/OBJCOPY/OBJDUMP)", "HAS_LOADER_32BIT": "(empty, ARM64-only; verified payload links m32 blob symbols weak-undefined)", "CHECK_FEATURES": "(empty; probe-existence would fake-detect cross capabilities)", "V": "0 (beautified)"},
    "env_CFLAGS": [prefix_map, "-D_LARGEFILE64_SOURCE (musl rlimit64/statfs64 aliases)", "-DHAVE_SECCOMP_FILTER", "-DHAVE_PROCESS_VM", "-include <work>/musl-compat.h", "-I<talloc-prefix>/include"],
    "env_LDFLAGS": ["-L<talloc-prefix>/lib (fork links plain -ltalloc)"],
    "env_PATH_prepend": "<work>/cross-bin (bare `readelf` in the loader-info.c rule -> NDK llvm-readobj facade; reproduces loader-info.c byte-exactly)",
    "ARG_MAX": "131072 resolved from pinned linux/limits.h; no define needed",
    "flags_via_environment": "never on the make command line: command-line CFLAGS/CPPFLAGS would defeat the makefile's own CPPFLAGS += -D_GNU_SOURCE etc."
  },
  "determinism": {"file_prefix_map": prefix_map, "archive": "llvm-ar rcSD (deterministic)", "manifest_order": "LC_ALL=C sorted",
                   "expected_rule_outputs": {"build.h": "60dd78f83b02c4bbb3525be31f9226151ab508f342ca71346b862483b07984ed", "loader-info.c": "5870a6f1a1634f9fc5885e92cfd49da7b71e5f9ffbc9d0ec995bf4d95a744a6d"}},
  "output_verification": ".IGNORE-scoped makefile => exit code trusted never; gated on make-log error scan, exact object set (m32 absent), ELF AArch64/EXEC/static/LOAD>=16KiB via llvm-readelf -lW with nonzero-LOAD assertion, embedded/weak loader-blob symbol shape",
  "lineage": {"pre_patch_verified_payloads": {"libproot.so": "db8968b988c5a6f129c88f0d516e4ec1bcec12da522800460d6c77534c831bc2", "libproot_loader.so": "3ef215b13e37bfd9454a5dfa8125a912177fbd693025753a4e8c1eb1e58ed735"},
              "delta": "libproot.so differs by the pinned EXITKILL patch + prefix-map normalization (measured 2026-10-22); for the loader the .text/.rodata/.data/symtab sections were verified byte-identical to 3ef215b1 (executable equivalence), while .debug_* metadata differs (prefix-map, compat -include into loader.c on clean rebuild, build-path provenance), so the loader file hash intentionally differs"},
  "licenses": {
    "combined_binary": "GPL-3.0-or-later (exercising PRoot's per-file 'or later' option; GPL-2.0-only terms are incompatible with the statically linked LGPL-3.0-or-later talloc)",
    "proot_fork": "per-file GPL-2.0-or-later notices (STMicroelectronics lineage), preserved verbatim; bundled COPYING (GPL-2.0 text) travels with the pinned archive",
    "talloc": "LGPL-3.0-or-later; static link => relink path + objects retained under build/",
    "queue_header": "BSD-3-Clause notice retained verbatim (compat/queue.h)",
    "obligations_doc": "FloeAndroid/core/linuxruntime/THIRD_PARTY.md + native-build/PINS.md"
  },
  "outputs_sha256": manifest,
}
with open(f"{out}/provenance.json", "w") as f:
    json.dump(prov, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"provenance.json written for {len(manifest)} outputs")
PY

echo
echo "bootstrap producer complete (canonical Termux fork, EXITKILL-patched)."
echo "outputs:  $OUT/lib (libproot.so, libproot_loader.so, libfloeprobe.so)"
echo "evidence: $OUT/build (talloc relink set, full proot object set, generated files, patched source, make log)"
echo "manifest: $OUT/MANIFEST.sha256"
echo "prov:     $OUT/provenance.json"
echo "integration into jniLibs/Gradle and device acceptance remain Main's serialized steps."
