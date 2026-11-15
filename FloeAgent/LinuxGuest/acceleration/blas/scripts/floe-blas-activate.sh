# SPDX-License-Identifier: Apache-2.0
# Sourceable guest-only activation fragment for wrapper/shell entry.
#
# Primary's simpler and preferred integration is floe_exec_accelerated():
# it execs `floe-blas-run -- COMMAND ARGS` for new task children.  This
# fragment remains available for an existing shell entry that already sources
# a guest-owned environment file.  It performs lazy activation only when the
# trusted root-owned library, /dev/dri/renderD128 and the Venus ICD exist;
# preserves an existing LD_PRELOAD; and does nothing on the macOS host.
#
# Source with:  . /usr/local/share/floe-acceleration/floe-blas-activate.sh

if [ "${FLOE_BLAS_ACTIVATION_SOURCED:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi
FLOE_BLAS_ACTIVATION_SOURCED=1
FLOE_BLAS_ACTIVATION_RESULT=unavailable
FLOE_BLAS_ACTIVATION_DETAIL=not-run

floe_blas_activation_fragment_main() {
    _activation_library=/usr/local/lib/floe-acceleration/floe-blas-shell.sh
    if [ ! -r "$_activation_library" ]; then
        FLOE_BLAS_ACTIVATION_DETAIL=policy-library-missing
        return 0
    fi
    # shellcheck source=floe-blas-shell.sh
    . "$_activation_library"
    floe_blas_activate_shell
}

floe_blas_activation_fragment_main
unset -f floe_blas_activation_fragment_main
