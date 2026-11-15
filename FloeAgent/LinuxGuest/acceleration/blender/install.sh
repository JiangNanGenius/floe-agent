#!/bin/sh
# install.sh — install the Floe Linux Blender workbench entry points.
#
# SPDX-License-Identifier: MPL-2.0
#
# This script installs only the wrapper/helper files.  It never installs a
# Blender package, downloads anything, starts Blender, or touches the host.
# The image owner supplies Blender (normally the Debian "blender" package,
# or an explicitly mounted runtime root selected with FLOE_BLENDER_ROOT).
#
# Usage:
#   ./install.sh [--prefix /usr/local] [--check]
#   ./install.sh --stage /owned/image/root [--check]
#
# --check is read-only and only validates the source files and reports the
# detected Blender dependency.  A non-Linux host is refused for a live
# install; host-side offline image staging must use --stage with an owned
# image root and is labeled as staging, not a live Linux installation.

set -eu

prefix=/usr/local
check=0
staging=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || { echo "install.sh: --prefix needs a path" >&2; exit 2; }
            prefix=$2
            shift 2
            ;;
        --stage)
            [ "$#" -ge 2 ] || { echo "install.sh: --stage needs a path" >&2; exit 2; }
            prefix=$2
            staging=1
            shift 2
            ;;
        --check)
            check=1
            shift
            ;;
        -h|--help)
            sed -n '1,20p' "$0"
            exit 0
            ;;
        *)
            echo "install.sh: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

host=$(uname -s 2>/dev/null || echo unknown)
if [ "$check" -eq 1 ]; then
    echo "install.sh: host=$host; read-only source check only"
elif [ "$host" != "Linux" ] && [ "$staging" -eq 0 ]; then
    echo "install.sh: refusing a live install on non-Linux host ($host)." >&2
    echo "install.sh: use --stage <owned image staging prefix> for offline image staging." >&2
    exit 3
elif [ "$host" != "Linux" ]; then
    case "$prefix" in
        /usr|/usr/local|/usr/*|/bin|/sbin|/opt|/Library|/System*)
            echo "install.sh: staging prefix must be an owned image root, not a host system prefix: $prefix" >&2
            exit 3
            ;;
    esac
fi

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
launcher="$here/floe-blender"
cli="$here/floe_blender.py"
ops="$here/blender_ops.py"

for file in "$launcher" "$cli" "$ops"; do
    [ -f "$file" ] || { echo "install.sh: missing source file: $file" >&2; exit 2; }
done

sh -n "$launcher" || { echo "install.sh: shell syntax check failed" >&2; exit 2; }

python=""
for candidate in python3 /usr/bin/python3 /usr/local/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
        python=$(command -v "$candidate")
        break
    fi
done
if [ -n "$python" ]; then
    "$python" -I - "$cli" "$ops" <<'PY'
import sys

for path in sys.argv[1:]:
    with open(path, "r", encoding="utf-8") as stream:
        compile(stream.read(), path, "exec")
PY
else
    echo "install.sh: warning: python3 not found; cannot compile-check the CLI" >&2
fi

blender=""
if command -v blender >/dev/null 2>&1; then
    blender=$(command -v blender)
elif [ -n "${FLOE_BLENDER_ROOT:-}" ] && [ -x "$FLOE_BLENDER_ROOT/usr/bin/blender" ]; then
    blender="$FLOE_BLENDER_ROOT/usr/bin/blender"
elif [ -x /usr/bin/blender ]; then
    blender=/usr/bin/blender
elif [ -x /floe/cache/usr/bin/blender ]; then
    blender=/floe/cache/usr/bin/blender
fi

if [ "$check" -eq 1 ]; then
    echo "floe-blender source check: ok"
    if [ -n "$blender" ]; then
        echo "Blender: $blender (dependency report only; not executed)"
    else
        echo "Blender: not installed yet (install the guest blender package or set FLOE_BLENDER_ROOT)"
    fi
    exit 0
fi

dest="$prefix/lib/floe/blender"
bindir="$prefix/bin"
install -d "$dest" "$bindir" || {
    echo "install.sh: cannot create $bindir and $dest (run as the image build user/root)" >&2
    exit 1
}
install -m 0755 "$launcher" "$bindir/floe-blender"
install -m 0644 "$cli" "$dest/floe_blender.py"
install -m 0644 "$ops" "$dest/blender_ops.py"

if [ "$staging" -eq 1 ]; then
    echo "Staged into an offline image root (not a live Linux installation): $prefix"
else
    echo "Installed into the live Linux guest:"
fi
echo "  $bindir/floe-blender"
echo "  $dest/floe_blender.py"
echo "  $dest/blender_ops.py"
if [ -n "$blender" ]; then
    echo "Detected Blender: $blender"
else
    echo "Blender is not installed yet; install the guest blender package or set FLOE_BLENDER_ROOT." >&2
fi
echo "Optional diagnostics: mesa-utils (glxinfo) and vulkan-tools (vulkaninfo)."
