# SPDX-License-Identifier: Apache-2.0
# Shared shell policy for the Floe guest BLAS provider.
#
# This file is sourced by floe-blas-run and the sourceable activation
# fragment.  It only checks fixed guest paths and never runs on the macOS
# host.  The C runner helper (floe_blas_activate.c) uses the same constants
# and the same per-environment config field.

FLOE_BLAS_LIBRARY_PATH=/usr/local/lib/floe-acceleration/libfloe_blas.so
FLOE_BLAS_ICD_PATH=/usr/share/vulkan/icd.d/virtio_icd.json
FLOE_BLAS_RENDER_NODE=/dev/dri/renderD128
FLOE_BLAS_LIBRARY_VERSION=0.1.0

floe_blas_is_guest() {
    [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -r /proc/self/status ]
}

floe_blas_config_path() {
    if [ -n "${XDG_CONFIG_HOME:-}" ] && [ "${XDG_CONFIG_HOME#/}" != "$XDG_CONFIG_HOME" ]; then
        printf '%s/floe-acceleration/blas.conf\n' "${XDG_CONFIG_HOME%/}"
    elif [ -n "${HOME:-}" ] && [ "${HOME#/}" != "$HOME" ]; then
        printf '%s/.config/floe-acceleration/blas.conf\n' "${HOME%/}"
    else
        return 1
    fi
}

floe_blas_trusted_file() {
    # $1 path, $2 required uid (0 for image assets, current uid for user config)
    _path=$1
    _uid=$2
    [ -f "$_path" ] || return 1
    _stat=$(stat -c '%u %a' "$_path" 2>/dev/null) || return 1
    [ -n "$_stat" ] || return 1
    set -- $_stat
    [ $# -eq 2 ] || return 1
    [ "$1" = "$_uid" ] || return 1
    [ $((0$2 & 022)) -eq 0 ] || return 1
    return 0
}

floe_blas_config_mode() {
    _path=$1
    [ -f "$_path" ] || return 1
    floe_blas_is_guest || return 1
    floe_blas_trusted_file "$_path" "$(id -u)" || return 1
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            mode=auto|mode=on|mode=off)
                printf '%s\n' "${_line#mode=}"
                return 0
                ;;
        esac
    done < "$_path"
    return 1
}

floe_blas_resolve_mode() {
    if [ -n "${FLOE_BLAS_MODE:-}" ]; then
        case "$FLOE_BLAS_MODE" in
            auto|on|off)
                FLOE_BLAS_RESOLVED_MODE=$FLOE_BLAS_MODE
                FLOE_BLAS_MODE_SOURCE=environment
                return 0
                ;;
            *)
                FLOE_BLAS_RESOLVED_MODE=auto
                FLOE_BLAS_MODE_SOURCE=environment-invalid
                return 0
                ;;
        esac
    fi
    FLOE_BLAS_CONFIG_PATH=$(floe_blas_config_path 2>/dev/null || true)
    if [ -n "$FLOE_BLAS_CONFIG_PATH" ]; then
        _config_mode=$(floe_blas_config_mode "$FLOE_BLAS_CONFIG_PATH" 2>/dev/null || true)
        case "$_config_mode" in
            auto|on|off)
                FLOE_BLAS_RESOLVED_MODE=$_config_mode
                FLOE_BLAS_MODE_SOURCE=config
                return 0
                ;;
        esac
    fi
    FLOE_BLAS_RESOLVED_MODE=auto
    FLOE_BLAS_MODE_SOURCE=default
    return 0
}

floe_blas_preload_contains() {
    case ":${LD_PRELOAD:-}:" in
        *":$FLOE_BLAS_LIBRARY_PATH:"*) return 0 ;;
    esac
    return 1
}

floe_blas_activation_state() {
    # Sets FLOE_BLAS_ACTIVATION_RESULT and FLOE_BLAS_ACTIVATION_DETAIL.
    floe_blas_resolve_mode
    FLOE_BLAS_ACTIVATION_RESULT=unavailable
    FLOE_BLAS_ACTIVATION_DETAIL=unknown
    if [ "$FLOE_BLAS_RESOLVED_MODE" = off ]; then
        FLOE_BLAS_ACTIVATION_RESULT=off
        FLOE_BLAS_ACTIVATION_DETAIL=policy-off
        return 0
    fi
    if ! floe_blas_is_guest; then
        FLOE_BLAS_ACTIVATION_DETAIL=nativehost
        return 0
    fi
    if [ "${FLOE_BLAS_DISABLE_ACTIVATION:-0}" = 1 ]; then
        FLOE_BLAS_ACTIVATION_DETAIL=disabled
        return 0
    fi
    if [ ! -f "$FLOE_BLAS_LIBRARY_PATH" ]; then
        FLOE_BLAS_ACTIVATION_DETAIL=library-missing
        return 0
    fi
    if ! floe_blas_trusted_file "$FLOE_BLAS_LIBRARY_PATH" 0; then
        FLOE_BLAS_ACTIVATION_DETAIL=library-untrusted
        return 0
    fi
    if [ ! -c "$FLOE_BLAS_RENDER_NODE" ]; then
        FLOE_BLAS_ACTIVATION_DETAIL=gpu-node-missing
        return 0
    fi
    if ! floe_blas_trusted_file "$FLOE_BLAS_ICD_PATH" 0; then
        FLOE_BLAS_ACTIVATION_DETAIL=icd-missing
        return 0
    fi
    FLOE_BLAS_ACTIVATION_RESULT=active
    FLOE_BLAS_ACTIVATION_DETAIL=ready
    return 0
}

floe_blas_activate_shell() {
    floe_blas_activation_state
    if [ "$FLOE_BLAS_ACTIVATION_RESULT" != active ]; then
        return 0
    fi
    if ! floe_blas_preload_contains; then
        if [ -n "${LD_PRELOAD:-}" ]; then
            LD_PRELOAD="$FLOE_BLAS_LIBRARY_PATH:$LD_PRELOAD"
        else
            LD_PRELOAD="$FLOE_BLAS_LIBRARY_PATH"
        fi
        export LD_PRELOAD
    fi
    FLOE_BLAS_ACTIVE=1
    FLOE_BLAS_MODE=$FLOE_BLAS_RESOLVED_MODE
    export FLOE_BLAS_ACTIVE FLOE_BLAS_MODE
    return 0
}

floe_blas_json_safe() {
    # A raw JSON string is emitted only for printable ASCII without quote or
    # backslash.  Any control/newline/UTF-8 byte is explicitly unsupported
    # instead of being interpolated into malformed JSON.
    case "$1" in
        *'"'*|*\\*) return 1 ;;
    esac
    _json_bytes=$(printf '%s' "$1" | od -An -tu1 -v 2>/dev/null) || return 1
    for _json_byte in $_json_bytes; do
        if [ "$_json_byte" -lt 32 ] || [ "$_json_byte" -eq 127 ] ||
           [ "$_json_byte" -gt 126 ]; then
            return 1
        fi
    done
    return 0
}
