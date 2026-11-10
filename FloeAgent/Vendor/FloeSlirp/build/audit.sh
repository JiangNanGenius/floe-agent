#!/bin/zsh
# Post-build audit for one platform. Layered per coordinator direction:
#   L1 Mach-O identity (arch/platform/minos)
#   L2 FINAL LINKED IMAGE: hard-forbidden scan (process exec, host plugin
#      loading, JIT emitters) + complete imported-symbol inventory with
#      public-API classification (socket/resolver/clock/framework APIs are
#      allowed and documented, not "forbidden by name").
#   L3 ARCHIVES: contents inventory (what exists but is NOT linked into the
#      image stays in the archive and is proven absent from the image).
# Usage: audit.sh <macos|ios-device|ios-sim>
set -eu
. "${0:A:h}/env.sh"
plat="$1"
ST="$STAGE/$plat"
SMOKE="$BUILDS/smoke-$plat/slirp_smoke"
OUT="$DOMAIN/logs/audit-$plat.txt"
: > "$OUT"
say() { echo "$@" | tee -a "$OUT"; }

say "=== audit $plat  $(date -u) ==="
say "--- L1: Mach-O identity ---"
for f in "$ST"/lib/*.a "$SMOKE"; do
  [[ -e "$f" ]] && say "$(basename $f): $(lipo -info "$f" 2>&1)"
done
say "-- build version load command of smoke image --"
vtool -show-build "$SMOKE" >>"$OUT" 2>&1 || otool -l "$SMOKE" | grep -A6 LC_BUILD_VERSION | tee -a "$OUT"
say "-- libslirp.a objects platform tag (sample) --"
otool -l "$ST/lib/libslirp.a" 2>/dev/null | grep -E "platform|minos|sdk " | sort | uniq -c | tee -a "$OUT"

say "--- L2a: hard-forbidden symbols in FINAL IMAGE (must be 0) ---"
for pat in _fork _vfork _execl _execve _execvp _posix_spawn _posix_spawnp _dlopen _dlsym _popen _system _ptrace _g_spawn_async _g_child_watch_source_new pcre2_jit_compile; do
  n=$(nm "$SMOKE" | { grep -cE "(^| )(U |t |T )?${pat}( |$)" || true; })
  say "forbidden[$pat]: $n"
done

say "--- L2b: image-level proof: exec-capable objects absent ---"
say "objects from libglib pulled into image (nm debug arch):"
nm -arch arm64 -m "$SMOKE" 2>/dev/null | grep "libglib-2.0.a" | awk '{print $NF}' | sort -u | head -40 | tee -a "$OUT"
say "gspawn present in image: $(nm "$SMOKE" | grep -c "_g_spawn" || true)"
say "gregex/pcre present in image: $(nm "$SMOKE" | grep -cE "_g_regex_|_pcre2" || true)"

say "--- L2c: public API import surface of the image ---"
say "-- dylibs --"
otool -L "$SMOKE" | sed -n '2,$p' | tee -a "$OUT"
say "-- undefined (imported) symbols, grouped --"
nm -u "$SMOKE" | sed 's/^ *U //;s/^U //' | sort -u > /tmp/undef.$$
say "total imported symbols: $(wc -l < /tmp/undef.$$ | tr -d ' ')"
for grp in "_res_" "_socket$" "_connect$" "_bind$" "_listen$" "_accept" "_send" "_recv" "_poll$" "_clock_gettime" "_gettimeofday" "_objc_" "_NS" "_CF" "_iconv"; do
  say "group[$grp]: $(grep -c "$grp" /tmp/undef.$$ || true) symbols"
done
cp /tmp/undef.$$ "$DOMAIN/logs/imported-symbols-$plat.txt"

say "--- L3: archive inventory (exists but not linked) ---"
for a in "$ST"/lib/libslirp.a "$ST"/lib/libglib-2.0.a "$ST"/lib/libpcre2-8.a; do
  [[ -e "$a" ]] || continue
  say "-- $(basename $a): $(ar t "$a" | wc -l | tr -d ' ') objects"
done
say "libslirp.a exec-undefined refs (expect none — SLIRP_NO_HOST_EXEC):"
nm -u -g "$ST/lib/libslirp.a" | grep -E "_fork|_exec|_posix_spawn|_g_spawn|_dlopen|_popen|_system" | sort | uniq -c | tee -a "$OUT"
n=$(nm -u -g "$ST/lib/libslirp.a" | grep -cE "_fork|_execve|_posix_spawn|_g_spawn|_dlopen|_popen|_system" || true)
say "libslirp.a forbidden-reference count: $n"
say "libglib-2.0.a exec-referencing objects (NOT pulled into image — see L2b):"
ar t "$ST/lib/libglib-2.0.a" | grep -E "gspawn|gprintf" || say "   (gspawn.o may still be in archive; absent from image is the requirement)"
say "pcre2 jit objects in archive (jit=disabled, expect none):"
ar t "$ST/lib/libpcre2-8.a" | grep -c "jit" || say "   0"

say "audit $plat done"
