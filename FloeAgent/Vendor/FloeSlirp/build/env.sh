#!/bin/zsh
# Shared environment for the FloeSlirp production rebuild (FloeAgent/Vendor/FloeSlirp).
# Paths and tool overrides for the pinned dependency rebuild.
# All source digests are pinned in ../PROVENANCE.json; nothing here downloads
# implicitly — prepare-sources.sh verifies every archive against pinned SHA-256.
#
# Production adaptation notes (vs the vendor qualification scripts, which are
# retained verbatim in the qualification domain):
#   * DOMAIN is this repository directory instead of a machine-local private
#     path, so logs and inputs stay with the tracked pins.
#   * Tool paths come from PATH and overridable variables instead of fixed
#     Homebrew locations.
#   * CACHE defaults under the user's build cache and is overridable.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export XCROOT=$DEVELOPER_DIR

DOMAIN="$(cd "$(dirname "$0")/.." && pwd)"
export DOMAIN
export CACHE=${FLOE_SLIRP_CACHE:-"$HOME/Library/Caches/CodexBuild/FloeSlirp-rebuild"}
export PKGCACHE="$CACHE/pkgcache"
export SRC="$CACHE/src"
export BUILDS="$CACHE/build"
export STAGE="$CACHE/staging"
export LOGS="$CACHE/logs"
export MESON=${MESON:-$(command -v meson || echo "$CACHE/tools-venv/bin/meson")}
export NINJA=${NINJA:-$(command -v ninja)}
export PKG_CONFIG=${PKG_CONFIG:-$(command -v pkg-config)}
export PYTHON=${PYTHON:-$(command -v python3)}

# Pinned identities (see PROVENANCE.json and ../vendor/SHA256SUMS)
export SLIRP_VER=4.9.7
export SLIRP_COMMIT=ce12dcddf710a71dc0de6450ec95edbadf8e9f66
export GLIB_VER=2.90.1
export MIN_OS_IOS=15.0

export JOBS=${JOBS:-6}

xcrun_sdk_path() { xcrun --sdk "$1" --show-sdk-path; }

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

die() { log "FATAL: $*"; exit 1; }

# run <stage-log-name> <cmd...> : run a command, tee into $LOGS/<name>.log, keep original failure
run() {
  local name="$1"; shift
  mkdir -p "$LOGS"
  local logf="$LOGS/$name.log"
  log "run: $*  (log: logs/$name.log)"
  "$@" 2>&1 | tee "$logf"
  local rc=${pipestatus[1]}
  if (( rc != 0 )); then
    log "FAILED (exit $rc): $*"
    return $rc
  fi
  return 0
}
