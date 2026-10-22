#!/usr/bin/env bash
# Reproducible producer for the guest-side NSS resolver helper
# libnss_floe.so.2 (glibc NSS module, aarch64-linux-gnu — NOT Android bionic).
#
# Consumes ONLY this directory's frozen inputs (PROTOCOL.json, libnss_floe.c,
# nss-floe.map) and the EXISTING pinned toolchain recipe one level up:
#   - Zig 0.14.1 (MIT, build host tool) — same URL+sha256 pins as
#     ../build-bootstrap.sh (kept byte-identical here; no new pins, no
#     global installs). The pinned archive/extracted tree is reused from the
#     canonical linuxruntime download cache when present.
#   - Android NDK 30.0.16248370 llvm tools (ld.lld / llvm-readelf) via
#     FloeAndroid/scripts/env.sh — the same host-binutils precedent
#     build-bootstrap.sh already uses for the loader link.
# The binary itself links against NOTHING at build time: it is compiled
# against the glibc public headers shipped inside the pinned Zig
# distribution and linked with --version-script exports, so the guest
# glibc's already-loaded symbols resolve it at dlopen time. No DT_NEEDED,
# no Android dependency, no glibc version-tagged imports => compatible
# with the pinned Debian bookworm guest (glibc 2.36) and the contract's
# 2.28 symbol floor.
#
# Outputs (all under --out, NEVER into the source tree):
#   $OUT/libnss_floe.so.2            (SONAME libnss_floe.so.2)
#   $OUT/libnss_floe.so.2.sha256     (sha256sum-style sidecar)
#   $OUT/manifest.json               (frozen PROTOCOL.json manifestSchema:
#                                     deterministic; no timestamps, no
#                                     private build paths, no credentials)
#   $OUT/build/                      (compiler/linker logs + the .o;
#                                     failures are preserved, never deleted)
#
# Usage:
#   bash FloeAndroid/core/linuxruntime/native-build/guest-resolver/build-guest-resolver.sh \
#     --out DIR [--cache DIR]
#
# Cache resolution order (first directory containing the pinned Zig):
#   --cache DIR  >  $FLOE_LINUXRUNTIME_CACHE  >
#   $FLOE_ANDROID_CACHE_ROOT/linuxruntime-downloads (verified internal
#   producer cache)  >  $REPO_ROOT/Local/Scratch/floe-linuxruntime-bootstrap/dl
# Only if NO candidate cache has the pinned archive does the producer fetch
# it from the SAME pinned URL with the SAME pinned sha256 (never another
# toolchain, never a global install).
#
# Overwrite safety: $OUT may be reused only when it carries this producer's
# ownership marker or the three deliverables are absent; existing
# deliverables without the marker are refused, never replaced. $OUT/build is
# reset per run under the same marker rule. Failure artifacts are kept.
set -euo pipefail

GR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
NB_DIR="$(cd "$GR_DIR/.." && pwd -P)"
REPO_ROOT="$(cd "$NB_DIR/../../../.." && pwd -P)"

# shellcheck source=FloeAndroid/scripts/env.sh
source "$REPO_ROOT/FloeAndroid/scripts/env.sh"
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
BIN="$TOOLCHAIN/bin"
LLD="$BIN/ld.lld"
READELF="$BIN/llvm-readelf"

OUT="${FLOE_GUEST_RESOLVER_OUT:-$REPO_ROOT/Local/Scratch/floe-guest-resolver/out}"
CACHE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --cache) CACHE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# Pins — copied from ../build-bootstrap.sh (the existing pinned recipe; this
# producer MUST stay in lockstep with it and introduces no new inputs).
# ---------------------------------------------------------------------------
ZIG_URL="https://ziglang.org/download/0.14.1/zig-aarch64-macos-0.14.1.tar.xz"
ZIG_SHA="39f3dc5e79c22088ce878edc821dedb4ca5a1cd9f5ef915e9b3cc3053e8faefa"
ZIG_DIRNAME="zig-aarch64-macos-0.14.1"
ZIG_VERSION="0.14.1"

# Lockstep guard: the pins above must equal the existing bootstrap recipe.
BOOTSTRAP="$NB_DIR/build-bootstrap.sh"
[[ -f "$BOOTSTRAP" ]] || die "pinned recipe ../build-bootstrap.sh missing"
[[ "$(grep -m1 '^ZIG_SHA=' "$BOOTSTRAP")" == "ZIG_SHA=\"$ZIG_SHA\"" ]] \
  || die "ZIG_SHA diverged from ../build-bootstrap.sh; the guest-resolver producer must reuse the existing pin, not invent one"
[[ "$(grep -m1 '^ZIG_URL=' "$BOOTSTRAP")" == "ZIG_URL=\"$ZIG_URL\"" ]] \
  || die "ZIG_URL diverged from ../build-bootstrap.sh"

# ---------------------------------------------------------------------------
# Output directory guards (binaries never land in the source tree). The
# string-shape refusal runs BEFORE creation so a refused run leaves nothing;
# the post-creation re-check (resolved symlinks) removes the directory only
# when this run created it and it is empty.
# ---------------------------------------------------------------------------
refuse_out() { # reason
  if [[ "${OUT_WAS_CREATED:-0}" == 1 ]]; then rmdir "$OUT_RESOLVED" 2>/dev/null || true; fi
  die "$1: $OUT_RESOLVED"
}
OUT_RESOLVED="$OUT"
[[ -d "$OUT_RESOLVED" ]] || OUT_RESOLVED="$( (cd "$OUT" 2>/dev/null && pwd -P) || printf '%s' "$OUT")"
case "$OUT_RESOLVED" in
  *jniLibs*|*src/main/assets*) refuse_out "refusing to emit into an App source/assets directory (staging signed assets is the facilities/Main step)" ;;
esac
if [[ "$OUT_RESOLVED" == "$GR_DIR" || "$OUT_RESOLVED" == "$GR_DIR/"* ]]; then
  refuse_out "refusing to emit binaries into the guest-resolver source directory"
fi
if [[ "$OUT_RESOLVED" == "$NB_DIR" || "$OUT_RESOLVED" == "$NB_DIR/"* ]]; then
  refuse_out "refusing to emit binaries into the native-build tree"
fi
OUT_WAS_CREATED=0
[[ -d "$OUT" ]] || OUT_WAS_CREATED=1
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
OUT_RESOLVED="$OUT"
case "$OUT" in
  *jniLibs*|*src/main/assets*) refuse_out "refusing to emit into an App source/assets directory (staging signed assets is the facilities/Main step)" ;;
esac
if [[ "$OUT" == "$GR_DIR" || "$OUT" == "$GR_DIR/"* ]]; then
  refuse_out "refusing to emit binaries into the guest-resolver source directory"
fi
if [[ "$OUT" == "$NB_DIR" || "$OUT" == "$NB_DIR/"* ]]; then
  refuse_out "refusing to emit binaries into the native-build tree"
fi

OWN_MARK=".floe-guest-resolver-owned"
DELIVERABLES=("$OUT/libnss_floe.so.2" "$OUT/libnss_floe.so.2.sha256" "$OUT/manifest.json")
deliverables_present=0
for d in "${DELIVERABLES[@]}"; do
  [[ -e "$d" ]] && { deliverables_present=1; break; }
done
if [[ $deliverables_present -eq 1 && ! -f "$OUT/$OWN_MARK" ]]; then
  die "refusing to overwrite existing deliverables in non-owned $OUT; point --out at a fresh directory or a directory previously produced by this script"
fi
printf 'owned by FloeAndroid/core/linuxruntime/native-build/guest-resolver/build-guest-resolver.sh\n' > "$OUT/$OWN_MARK"

BUILD="$OUT/build"
if [[ -d "$BUILD" && -n "$(ls -A "$BUILD" 2>/dev/null)" && ! -f "$BUILD/$OWN_MARK" ]]; then
  die "refusing to reset nonempty unowned build directory: $BUILD"
fi
rm -rf "${BUILD:?}"
mkdir -p "$BUILD"
printf 'owned by build-guest-resolver.sh; recreated on every run\n' > "$BUILD/$OWN_MARK"

# ---------------------------------------------------------------------------
# Zig from the pinned caches (reuse-first; verified before extraction).
# ---------------------------------------------------------------------------
candidates=()
[[ -n "$CACHE" ]] && candidates+=("$CACHE")
[[ -n "${FLOE_LINUXRUNTIME_CACHE:-}" ]] && candidates+=("$FLOE_LINUXRUNTIME_CACHE")
[[ -n "${FLOE_ANDROID_CACHE_ROOT:-}" ]] && candidates+=("$FLOE_ANDROID_CACHE_ROOT/linuxruntime-downloads")
candidates+=("$REPO_ROOT/Local/Scratch/floe-linuxruntime-bootstrap/dl")
[[ -z "$CACHE" || -d "$CACHE" ]] || die "explicit --cache directory missing: $CACHE"

ZIG_BIN=""
ZIG_ARCHIVE_SHA=""
for c in "${candidates[@]}"; do
  [[ -d "$c" ]] || continue
  if [[ -x "$c/$ZIG_DIRNAME/zig" ]]; then
    ZIG_BIN="$c/$ZIG_DIRNAME/zig"
    # The extracted tree alone is not proof of the pinned archive; verify the
    # archive beside it when present, otherwise fall through to a pinned
    # archive that exists in any later candidate cache.
    if [[ -f "$c/$ZIG_DIRNAME.tar.xz" ]]; then
      if [[ "$(sha "$c/$ZIG_DIRNAME.tar.xz")" == "$ZIG_SHA" ]]; then
        ZIG_ARCHIVE_SHA="$ZIG_SHA"
      else
        die "zig archive in cache $c does not match the pinned sha256; refusing to use it"
      fi
    fi
    break
  fi
  if [[ -f "$c/$ZIG_DIRNAME.tar.xz" ]]; then
    if [[ "$(sha "$c/$ZIG_DIRNAME.tar.xz")" != "$ZIG_SHA" ]]; then
      die "zig archive in cache $c does not match the pinned sha256; refusing to use it"
    fi
    mkdir -p "$c"
    tar xJf "$c/$ZIG_DIRNAME.tar.xz" -C "$c"
    ZIG_BIN="$c/$ZIG_DIRNAME/zig"
    ZIG_ARCHIVE_SHA="$ZIG_SHA"
    break
  fi
done

if [[ -z "$ZIG_BIN" ]]; then
  # Fetch into the repository-private scratch cache with the SAME pinned
  # URL/sha (this is the existing pin, not a new download dependency).
  FETCHDIR="$REPO_ROOT/Local/Scratch/floe-linuxruntime-bootstrap/dl"
  mkdir -p "$FETCHDIR"
  echo "no pinned Zig found in candidate caches; fetching the pinned archive into $FETCHDIR"
  curl -fL --retry 2 --max-time 600 -o "$FETCHDIR/$ZIG_DIRNAME.tar.xz.part" "$ZIG_URL"
  [[ "$(sha "$FETCHDIR/$ZIG_DIRNAME.tar.xz.part")" == "$ZIG_SHA" ]] \
    || die "fetched Zig archive hash mismatch; preserving failure artifact $FETCHDIR/$ZIG_DIRNAME.tar.xz.part"
  mv "$FETCHDIR/$ZIG_DIRNAME.tar.xz.part" "$FETCHDIR/$ZIG_DIRNAME.tar.xz"
  ZIG_ARCHIVE_SHA="$ZIG_SHA"
  tar xJf "$FETCHDIR/$ZIG_DIRNAME.tar.xz" -C "$FETCHDIR"
  ZIG_BIN="$FETCHDIR/$ZIG_DIRNAME/zig"
fi

"$ZIG_BIN" version | grep -qx "$ZIG_VERSION" || die "zig version mismatch (expected $ZIG_VERSION)"
# If only a pre-extracted tree was present without a verified archive beside
# it, locate the pinned archive in any candidate cache for the manifest hash;
# otherwise the manifest records the pinned archive sha itself (the pin is
# what was verified at fetch time).
for c in "${candidates[@]}"; do
  [[ -f "$c/$ZIG_DIRNAME.tar.xz" ]] || continue
  [[ "$(sha "$c/$ZIG_DIRNAME.tar.xz")" == "$ZIG_SHA" ]] || die "zig archive cache copy in $c mismatched the pin"
  ZIG_ARCHIVE_SHA="$ZIG_SHA"
  break
done
[[ -n "$ZIG_ARCHIVE_SHA" ]] || die "internal: zig archive pin verification missing"

# ---------------------------------------------------------------------------
# 1. Compile (glibc NSS module, never an Android bionic target).
#    -std=gnu11 -O2: deterministic; -Werror: the source must stay warning-clean.
#    -ffile-prefix-map: no absolute private build path enters the object.
# ---------------------------------------------------------------------------
CC_LOG="$BUILD/compile.log"
PREFIX_MAP="-ffile-prefix-map=$GR_DIR=/floe-guest-resolver"
ZIG_ROOT="$(cd "$(dirname "$ZIG_BIN")" && pwd -P)"
"$ZIG_BIN" cc \
  --target=aarch64-linux-gnu.2.28 \
  -std=gnu11 -O2 -g \
  -Wall -Wextra -Werror \
  -fPIC \
  "$PREFIX_MAP" \
  "-ffile-prefix-map=$ZIG_ROOT=/floe-toolchains/zig" \
  -fdebug-compilation-dir=/floe-guest-resolver \
  -fno-ident \
  -c "$GR_DIR/libnss_floe.c" \
  -o "$BUILD/libnss_floe.o" >"$CC_LOG" 2>&1 \
  || { tail -n 40 "$CC_LOG" >&2; die "compile failed (log preserved at $CC_LOG)"; }

# ---------------------------------------------------------------------------
# 2. Link shared object with the pinned NDK's lld (host-binutils precedent).
#    -z max-page-size/common-page-size 16384: guest loads under a 16 KiB
#    page kernel (target37/Android17 cohort requirement; PROTOCOL.json
#    pageAlignmentMin).
#    --version-script: export exactly the four contract entry points.
# ---------------------------------------------------------------------------
LD_LOG="$BUILD/link.log"
"$LLD" \
  -shared \
  --soname libnss_floe.so.2 \
  -z max-page-size=16384 -z common-page-size=16384 \
  -z noexecstack \
  --build-id=sha1 \
  --fatal-warnings \
  --version-script="$GR_DIR/nss-floe.map" \
  -o "$OUT/libnss_floe.so.2" \
  "$BUILD/libnss_floe.o" >"$LD_LOG" 2>&1 \
  || { tail -n 40 "$LD_LOG" >&2; die "link failed (log preserved at $LD_LOG)"; }

# ---------------------------------------------------------------------------
# 3. Verification gates (static inspection; device proof stays with Main).
# ---------------------------------------------------------------------------
HDR="$("$READELF" -h "$OUT/libnss_floe.so.2")"
printf '%s\n' "$HDR" | grep -q "AArch64" || die "not AArch64"
printf '%s\n' "$HDR" | grep -q "DYN (Shared object file)" || die "not a shared object (DYN)"

DY="$("$READELF" -d "$OUT/libnss_floe.so.2")"
printf '%s\n' "$DY" | grep -q "Library soname: \[libnss_floe.so.2\]" \
  || die "SONAME is not libnss_floe.so.2"
if printf '%s\n' "$DY" | grep -q "(NEEDED)"; then
  die "unexpected DT_NEEDED entries (module must resolve against the guest's loaded glibc only): $(printf '%s\n' "$DY" | grep '(NEEDED)')"
fi

SEGS="$("$READELF" -lW "$OUT/libnss_floe.so.2")"
LOAD_COUNT="$(printf '%s\n' "$SEGS" | awk '$1 == "LOAD" { n++ } END { print n + 0 }')"
[[ "$LOAD_COUNT" -ge 1 ]] || die "llvm-readelf -lW parsed 0 LOAD segments"
while read -r al; do
  [[ "$al" == 0x* ]] || die "unexpected Align field '$al' in a LOAD row"
  [[ "$((16#${al#0x}))" -ge 16384 ]] || die "LOAD alignment $al < 16KiB"
done < <(printf '%s\n' "$SEGS" | awk '$1 == "LOAD" { print $NF }')

DYN="$("$READELF" --dyn-syms -W "$OUT/libnss_floe.so.2")"
# The contract's four entry points are exported as GLOBAL FUNCs, and they
# are the ONLY defined GLOBALs (version-script locality).
printf '%s\n' "$DYN" | grep -E 'FUNC +GLOBAL DEFAULT' | grep -v ' UND ' >"$BUILD/exports.txt" || true
EXPORT_COUNT="$(grep -c . "$BUILD/exports.txt" || true)"
[[ "$EXPORT_COUNT" == 4 ]] || die "expected exactly 4 exported NSS entry points, got $EXPORT_COUNT:
$(cat "$BUILD/exports.txt")"
for sym in _nss_floe_gethostbyname_r _nss_floe_gethostbyname2_r \
           _nss_floe_gethostbyname3_r _nss_floe_gethostbyname4_r; do
  grep -q " $sym\$" "$BUILD/exports.txt" || die "required export $sym missing"
done
# No glibc version-tagged imports: the module binds at runtime against any
# glibc providing the (all pre-2.28) stable symbols it references.
printf '%s\n' "$DYN" | grep -q 'GLIBC_[0-9]' \
  && die "found version-tagged glibc imports; floor statement would be wrong" || true
# Android/bionic symbols must not appear anywhere in the dynamic symbol table.
printf '%s\n' "$DYN" | grep -qiE '__android|bionic|_JNI_OnLoad' \
  && die "Android/bionic symbol found in the module" || true
# The module must actually reference the guest glibc services it needs.
for sym in socket connect send recv poll close; do
  printf '%s\n' "$DYN" | grep -qE "UND $sym\$|UND $sym " || die "undefined reference to $sym missing (link shape changed?)"
done

BINARY_BYTES="$(wc -c <"$OUT/libnss_floe.so.2" | tr -d ' ')"
[[ "$BINARY_BYTES" -ge 1 && "$BINARY_BYTES" -le 4194304 ]] \
  || die "binary size $BINARY_BYTES outside manifest bound 1..4194304"

BINARY_SHA="$(sha "$OUT/libnss_floe.so.2")"
printf '%s  libnss_floe.so.2\n' "$BINARY_SHA" > "$OUT/libnss_floe.so.2.sha256"

# ---------------------------------------------------------------------------
# 4. manifest.json — the frozen PROTOCOL.json manifestSchema. Deterministic
#    (sorted keys, fixed indent, trailing newline); no timestamps, no private
#    paths, no credentials, no raw logs. sources = the module's build inputs
#    (generated outputs excluded by construction: this script emits only into
#    $OUT).
# ---------------------------------------------------------------------------
python3 - "$GR_DIR" "$OUT" "$ZIG_VERSION" "$ZIG_ARCHIVE_SHA" <<'PY'
import hashlib, json, sys
gr_dir, out, zig_ver, zig_sha = sys.argv[1:5]

SOURCES = [
    "PROTOCOL.json",
    "build-guest-resolver.sh",
    "libnss_floe.c",
    "nss-floe.map",
]

sources = []
for rel in SOURCES:
    data = open(f"{gr_dir}/{rel}", "rb").read()
    sources.append({"path": rel, "sha256": hashlib.sha256(data).hexdigest(),
                    "bytes": len(data)})
sources.sort(key=lambda s: s["path"].encode("utf-8"))
# sourceTreeSha256: SHA256 of the sorted UTF-8 lines "<sha256>  <path>\n"
lines = [f"{s['sha256']}  {s['path']}\n" for s in sources]
source_tree = hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()

binary_bytes = len(open(f"{out}/libnss_floe.so.2", "rb").read())

manifest = {
    "schemaVersion": 1,
    "protocol": "floe-guest-dns-v1",
    "library": "libnss_floe.so.2",
    "target": "aarch64-linux-gnu",
    "glibcFloor": "2.28",
    "soname": "libnss_floe.so.2",
    "sourceTreeSha256": source_tree,
    "sources": sources,
    "toolchain": {"name": "zig", "version": zig_ver, "archiveSha256": zig_sha},
    "binary": {"name": "libnss_floe.so.2",
               "sha256": hashlib.sha256(open(f"{out}/libnss_floe.so.2", "rb").read()).hexdigest(),
               "bytes": binary_bytes},
    "minimumLoadAlignment": 16384,
    "exports": [
        "_nss_floe_gethostbyname2_r",
        "_nss_floe_gethostbyname3_r",
        "_nss_floe_gethostbyname4_r",
        "_nss_floe_gethostbyname_r",
    ],
}
blob = json.dumps(manifest, indent=1, sort_keys=True) + "\n"
assert len(blob.encode("utf-8")) <= 65536, "manifest above the frozen 64 KiB bound"
tmp = f"{out}/manifest.json.part"
with open(tmp, "w") as f:
    f.write(blob)
import os
os.replace(tmp, f"{out}/manifest.json")
print(f"manifest.json written (sourceTreeSha256={source_tree})")
PY

echo
echo "guest-resolver producer complete."
echo "artifact: $OUT/libnss_floe.so.2 ($BINARY_BYTES bytes, sha256 $BINARY_SHA)"
echo "sidecar:  $OUT/libnss_floe.so.2.sha256"
echo "manifest: $OUT/manifest.json"
echo "logs/obj: $OUT/build (preserved on every outcome)"
echo "Asset staging into runtimeapp APK assets, the final combined App build and device acceptance remain Main's serialized steps."
