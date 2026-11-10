#!/bin/zsh
# iOS archive trim for the staged libglib-2.0.a (see patches/README.md).
#
# With patch 0002 (FLOE_GLIB_NO_TEST_SUBPROCESS) applied to the SAME glib
# source on all platforms, gtestutils.c.o no longer references g_spawn/fork/
# waitpid — it keeps the real production pieces (g_assertion_message*, test
# framework entry points that merely run in-process). Two members remain in
# the archive that nobody references and that import process-execution:
#   gspawn.c.o         (public g_spawn_* API surface)
#   gspawn-posix.c.o   (its POSIX implementation: fork/execve/posix_spawn)
# libslirp uses neither, and an App Store image must not carry exec imports,
# so they are removed from the DELIVERED archives. gtestutils.c.o's
# g_test_subprocess flag and assertion formatting stay fully functional
# (no fake-success stubs anywhere).
# The macOS host archive is intentionally left untrimmed (host smoke only,
# not shipped to devices).
# Usage: strip-exec-glib.sh <ios-device|ios-sim>
set -eu
. "${0:A:h}/env.sh"
plat="$1"
ST="$STAGE/$plat"
ARCHIVE="$ST/lib/libglib-2.0.a"

for dead in gspawn.c.o gspawn-posix.c.o; do
  ar t "$ARCHIVE" | grep -qx "$dead" || die "expected member $dead missing (upstream changed?)"
  ar -d "$ARCHIVE" "$dead"
  log "removed $dead from $(basename $ARCHIVE)"
done

# fail closed: no remaining member may reference g_spawn/fork/exec/posix_spawn
work=$(mktemp -d /tmp/glibscan.XXXX)
(cd "$work" && ar -x "$ARCHIVE")
refs=$(for o in "$work"/*.o; do nm -u -arch arm64 "$o" 2>/dev/null | { grep -oE "_(g_spawn[a-zA-Z_]*|fork|execve|execvp?|posix_spawn[a-z_]*|popen|dlopen)$" || true; }; done | sort -u)
rm -rf "$work"
if [[ -n "$refs" ]]; then
  die "residual process-execution refs after trim: $refs"
fi
log "trim verification: no member of $(basename $ARCHIVE) imports or references process execution APIs"
