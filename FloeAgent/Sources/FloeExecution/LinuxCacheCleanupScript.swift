// FloeExecution — bundled trusted script for Linux cache cleanup.
//
// This is a compile-time resource: it is never fetched, installed or edited at
// runtime. The native LinuxCacheCleanupService is the only producer of the
// exec.shell payload that carries it, and the script accepts only validated
// active category ids (apt,pip,npm; legacy scratch is retained) through two environment variables. It has
// no path or arbitrary-command argument, so neither the model nor a provider
// can point it at a project, document, installed package, model store or host
// path. Keep the private fixture byte-identical; the static contract checks
// compare them.

import Foundation

public enum LinuxCacheCleanupScript {
    public static let schema = "floe.linux-cache-cleanup.v1"
    public static let source = #"""
#!/bin/sh
# Floe bundled Linux cache cleanup (trusted, no model, no network).
#
# Invoked ONLY by the native LinuxCacheCleanupService through the existing
# exec.shell/background-job route. It takes no path arguments and has no
# arbitrary-command mode:
#   FLOE_CLEANUP_MODE       inspect | clean
#   FLOE_CLEANUP_CATEGORIES comma-separated apt,pip,npm,scratch
#
# Fixed roots only. The App-owned cache locations are LinuxGuestWritablePaths
# (/floe/env/cache/pip, /floe/env/cache/npm). Legacy scratch requests are
# retained: /var/tmp/floe-runtime has no per-item ownership proof. Never sweep
# /tmp, ~/.cache, HOME, workspaces,
# installed packages, toolchains or model stores. apt uses the real package
# manager lock via `apt-get clean`; the script never flocks a dpkg lock.
set -u
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCHEMA=floe.linux-cache-cleanup.v1
MODE=${FLOE_CLEANUP_MODE:-inspect}
REQUESTED=${FLOE_CLEANUP_CATEGORIES:-apt,pip,npm}

APT_ROOT=/var/cache/apt/archives
ENV_ROOT=/floe/env
PIP_ROOT=$ENV_ROOT/cache/pip
NPM_ROOT=$ENV_ROOT/cache/npm
LOCK_ROOT=/var/lock/floe-cache-cleanup.lock.d

CANCELLED=0
FAILED=0
CLEANED_CATEGORIES=0
SKIPPED_CATEGORIES=0
FAILED_CATEGORIES=0
CATEGORIES=
SEEN_CATEGORIES=' '

banner() {
  printf 'FLOE_LINUX_CLEANUP_V1\n'
  printf 'schema=%s\n' "$SCHEMA"
  printf 'mode=%s\n' "$MODE"
}

fail_protocol() {
  banner
  printf 'error=%s\n' "$1"
  exit 64
}

case "$MODE" in
  inspect|clean) ;;
  *) fail_protocol invalid_mode ;;
esac

OLDIFS=$IFS
IFS=,
for raw in $REQUESTED; do
  case "$raw" in
    '') continue ;;
    apt|pip|npm|scratch) ;;
    *) IFS=$OLDIFS; fail_protocol invalid_category ;;
  esac
  case "$SEEN_CATEGORIES" in
    *" $raw "*) continue ;;
  esac
  SEEN_CATEGORIES="$SEEN_CATEGORIES$raw "
  CATEGORIES="${CATEGORIES}${CATEGORIES:+ }$raw"
done
IFS=$OLDIFS
[ -n "$CATEGORIES" ] || fail_protocol no_categories

trap 'CANCELLED=1' HUP INT TERM

df_available_bytes() {
  _path=$1
  [ -e "$_path" ] || _path=/
  _line=$(df -Pk "$_path" 2>/dev/null | tail -n 1)
  [ -n "$_line" ] || { printf 'unknown'; return; }
  set -- $_line
  case "${4:-}" in
    ''|*[!0-9]*) printf 'unknown' ;;
    *) printf '%s' $(( $4 * 1024 )) ;;
  esac
}

du_bytes() {
  _path=$1
  [ -e "$_path" ] || { printf '0'; return; }
  set -- $(du -sk "$_path" 2>/dev/null)
  case "${1:-}" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' $(( $1 * 1024 )) ;;
  esac
}

path_in_use() {
  _root=$1
  [ -d /proc ] || return 1
  for _proc in /proc/[0-9]*; do
    [ -d "$_proc" ] || continue
    [ "$_proc" = "/proc/$$" ] && continue
    _cwd=$(readlink "$_proc/cwd" 2>/dev/null || true)
    case "$_cwd" in
      "$_root"|"$_root"/*) return 0 ;;
    esac
    for _fd in "$_proc"/fd/*; do
      [ -e "$_fd" ] || continue
      _target=$(readlink "$_fd" 2>/dev/null || true)
      case "$_target" in
        "$_root"|"$_root"/*) return 0 ;;
      esac
    done
  done
  return 1
}

# Prints safe|missing|symlink|unresolved|escaped|unsearchable.
command_running() {
  _needle=$1
  [ -d /proc ] || return 1
  for _proc in /proc/[0-9]*; do
    [ -r "$_proc/cmdline" ] || continue
    _cmdline=$(tr '\000' ' ' < "$_proc/cmdline" 2>/dev/null || true)
    case "$_cmdline" in
      *"$_needle"*) return 0 ;;
    esac
  done
  return 1
}

safe_root() {
  _root=$1
  [ -d "$_root" ] || { printf 'missing'; return; }
  [ ! -L "$_root" ] || { printf 'symlink'; return; }
  _resolved=$(cd -P "$_root" 2>/dev/null && pwd -P) || { printf 'unresolved'; return; }
  [ "$_resolved" = "$_root" ] || { printf 'escaped'; return; }
  command -v find >/dev/null 2>&1 || { printf 'unsearchable'; return; }
  _link=$(find "$_root" -type l -print -quit 2>/dev/null)
  [ -z "$_link" ] || { printf 'symlink'; return; }
  printf 'safe'
}

emit_category() {
  _category=$1
  _status=$2
  _before=${3:-0}
  _after=${4:-0}
  _note=${5:-none}
  printf 'category=%s status=%s bytes_before=%s bytes_after=%s note=%s\n' \
    "$_category" "$_status" "$_before" "$_after" "$_note"
  case "$_status" in
    cleaned|observed) CLEANED_CATEGORIES=$((CLEANED_CATEGORIES + 1)) ;;
    failed|partial) FAILED_CATEGORIES=$((FAILED_CATEGORIES + 1)) ;;
    *) SKIPPED_CATEGORIES=$((SKIPPED_CATEGORIES + 1)) ;;
  esac
}

skip_root_status() {
  case "$1" in
    symlink) printf 'skipped-symlink' ;;
    escaped) printf 'skipped-escaped' ;;
    unresolved) printf 'skipped-unresolved' ;;
    unsearchable) printf 'skipped-unsearchable' ;;
    *) printf 'skipped-unknown' ;;
  esac
}

remove_children() {
  _root=$1
  find "$_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
}

clean_apt() {
  _before=$(du_bytes "$APT_ROOT")
  if [ "$MODE" = inspect ]; then
    emit_category apt observed "$_before" "$_before" observed
    return
  fi
  _safe=$(safe_root "$APT_ROOT")
  case "$_safe" in safe|missing) ;; *) emit_category apt "$(skip_root_status "$_safe")" "$_before" "$_before" unsafe_root; return ;; esac
  if [ "$_safe" = missing ]; then
    emit_category apt skipped-missing 0 0 missing
    return
  fi
  if path_in_use "$APT_ROOT"; then
    emit_category apt skipped-busy "$_before" "$_before" apt_in_use
    return
  fi
  command -v apt-get >/dev/null 2>&1 || {
    emit_category apt skipped-missing "$_before" "$_before" apt_get_missing
    return
  }
  if apt-get clean >/dev/null 2>&1; then
    _after=$(du_bytes "$APT_ROOT")
    emit_category apt cleaned "$_before" "$_after" package_manager_lock_held
  else
    _after=$(du_bytes "$APT_ROOT")
    emit_category apt skipped-busy "$_before" "$_after" package_manager_locked
  fi
}

clean_cache_root() {
  _category=$1
  _root=$2
  _before=$(du_bytes "$_root")
  if [ "$MODE" = inspect ]; then
    emit_category "$_category" observed "$_before" "$_before" observed
    return
  fi
  _safe=$(safe_root "$_root")
  case "$_safe" in
    safe) ;;
    missing) emit_category "$_category" skipped-missing 0 0 missing; return ;;
    *) emit_category "$_category" "$(skip_root_status "$_safe")" "$_before" "$_before" unsafe_root; return ;;
  esac
  if path_in_use "$_root"; then
    emit_category "$_category" skipped-busy "$_before" "$_before" cache_in_use
    return
  fi
  case "$_category" in
    pip)
      if command_running "pip" || command_running "python3 -m pip"; then
        emit_category "$_category" skipped-busy "$_before" "$_before" pip_running
        return
      fi
      ;;
    npm)
      if command_running "npm" || command_running "pnpm" || command_running "yarn"; then
        emit_category "$_category" skipped-busy "$_before" "$_before" npm_running
        return
      fi
      ;;
  esac
  if remove_children "$_root"; then
    _after=$(du_bytes "$_root")
    emit_category "$_category" cleaned "$_before" "$_after" none
  else
    _after=$(du_bytes "$_root")
    emit_category "$_category" partial "$_before" "$_after" delete_failed
  fi
}

clean_scratch() {
  # Legacy raw category compatibility only. Age, prefix and /proc absence
  # cannot prove ownership or that a file is regenerable/non-unique.
  emit_category scratch retained unknown unknown ownership_unverified
}

banner
DF_PATH=$ENV_ROOT
[ -e "$DF_PATH" ] || DF_PATH=/
DF_BEFORE=$(df_available_bytes "$DF_PATH")
printf 'df_path=%s\n' "$DF_PATH"
printf 'df_available_before_bytes=%s\n' "$DF_BEFORE"

if [ "$MODE" = clean ]; then
  if [ ! -d /proc ]; then
    # Never claim a Busy-owner-safe cleanup on a kernel without /proc.
    printf 'error=proc_unavailable\n'
    exit 65
  fi
  _lock_acquired=0
  if mkdir "$LOCK_ROOT" 2>/dev/null; then
    _lock_acquired=1
  else
    # A previous script can leave the lock behind. Recover only when its PID
    # is absent or no longer exists; the mkdir itself remains the atomic gate.
    _holder=$(cat "$LOCK_ROOT/pid" 2>/dev/null || true)
    case "$_holder" in
      ''|*[!0-9]*)
        sleep 1
        _holder=$(cat "$LOCK_ROOT/pid" 2>/dev/null || true)
        ;;
    esac
    case "$_holder" in
      ''|*[!0-9]*) rm -rf "$LOCK_ROOT" 2>/dev/null || true ;;
      *) [ -d "/proc/$_holder" ] || rm -rf "$LOCK_ROOT" 2>/dev/null || true ;;
    esac
    if mkdir "$LOCK_ROOT" 2>/dev/null; then _lock_acquired=1; fi
  fi
  if [ "$_lock_acquired" = 0 ]; then
    if [ ! -e "$LOCK_ROOT" ]; then
      printf 'error=lock_unavailable\n'
      exit 65
    fi
    printf 'category=all status=skipped-busy bytes_before=0 bytes_after=0 note=cleanup_already_running\n'
    printf 'cancelled=0\n'
    printf 'summary cleaned_categories=0 skipped_categories=1 failed_categories=0\n'
    printf 'error=cleanup_already_running\n'
    exit 0
  fi
  printf '%s' "$$" > "$LOCK_ROOT/pid" 2>/dev/null || true
  trap 'CANCELLED=1; rm -rf "$LOCK_ROOT" 2>/dev/null || true' HUP INT TERM
  trap 'rm -rf "$LOCK_ROOT" 2>/dev/null || true' EXIT
fi

for category in $CATEGORIES; do
  [ "$CANCELLED" = 0 ] || break
  case "$category" in
    apt) clean_apt ;;
    pip) clean_cache_root pip "$PIP_ROOT" ;;
    npm) clean_cache_root npm "$NPM_ROOT" ;;
    scratch) clean_scratch ;;
  esac
done

DF_AFTER=$(df_available_bytes "$DF_PATH")
printf 'df_available_after_bytes=%s\n' "$DF_AFTER"
printf 'cancelled=%s\n' "$CANCELLED"
printf 'summary cleaned_categories=%s skipped_categories=%s failed_categories=%s\n' \
  "$CLEANED_CATEGORIES" "$SKIPPED_CATEGORIES" "$FAILED_CATEGORIES"

if [ "$CANCELLED" != 0 ]; then
  printf 'error=cancelled\n'
  exit 0
fi
if [ "$FAILED_CATEGORIES" != 0 ]; then
  printf 'error=partial_failure\n'
  exit 1
fi
exit 0
"""#
}
