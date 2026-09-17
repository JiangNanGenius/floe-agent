#!/usr/bin/env bash
# resolve_xcode_dependencies.sh - bounded, evidence-preserving xcodebuild
# package resolution for the release workflows.
#
# Why this exists
# ---------------
# xcodebuild performs its own SwiftPM package-graph resolution, independent of
# `swift package resolve`, and it uses the `-packageCachePath` given on the
# build command. In the build 182 SDK 27 release job (105296416221) that
# resolution hit a `curl 56` clone timeout and then a GitHub DNS failure; the
# job aborted and reported only the downstream
# "binary target 'LlamaFramework' could not be mapped to an artifact" error.
#
# This helper runs that network-only phase as a separate step so it can be
# retried deliberately:
#   * at most `--max-attempts` attempts (1..3, default 3);
#   * a retry happens only when the raw attempt log contains an explicit
#     network signature (DNS / timeout / connection / truncated transfer)
#     AND does not contain a strong deterministic error (checksum / manifest /
#     authentication). A deterministic error wins even if a network error
#     appears earlier in the same log;
#   * every raw attempt log is written under `--log-dir` unchanged;
#   * the tracked host `Package.resolved` is never rewritten: the original is
#     backed up and restored before failing if xcodebuild changes it, and the
#     changed bytes are kept as evidence;
#   * the *actual* Xcode lock (`project.xcworkspace/xcshareddata/swiftpm/
#     Package.resolved`) is what xcodebuild really reads and writes. When
#     `--xcode-lock` is given it is seeded from the committed HEAD lock on
#     first use and verified read-only against that lock (plus app-only pins
#     from `--project-yml`) with scripts/resolved_pins.py. An existing lock
#     that disagrees with the committed pins is never overwritten. Xcode may
#     legitimately rewrite its own lock while resolving - originHash metadata,
#     a v1/v3 schema transcription or pure formatting - so a byte change is
#     re-checked by *normalized pins*: it passes when every identity's
#     version/revision/location is unchanged (before/after copies are kept),
#     and fails only on real dependency drift, a missing pin or deletion (drift
#     bytes kept as evidence, the committed lock restored);
#   * compile, manifest, checksum and artifact-mapping failures are not
#     retried on their own - they fail immediately.
#
# The command mirrors the real build invocation (same project, scheme,
# configuration, destination, `-packageCachePath` and `-derivedDataPath`) so
# the warmed cache and the checked-out graph are exactly what the following
# build reuses. Callers are expected to add
# `-onlyUsePackageVersionsFromResolvedFile` to the build so package versions
# are taken from the resolved file instead of being re-selected.
# That flag does not make the build offline: materializing a checkout or binary
# artifact that is still missing from the warmed cache can still contact the
# network.
#
# Exit status:
#   0  resolution succeeded and every protected lock file is byte-identical
#   1  bad usage, pre-flight failure (mkdir/backup/hash), non-network failure,
#      exhausted network retries, or a lock-file mutation (the original lock is
#      restored before exiting and the changed bytes are kept in `--log-dir`)

set -u
set -o pipefail

# Only these signatures justify a retry. Generic git phrases such as
# "RPC failed" or a bare "SSL_ERROR" are deliberately absent: they also occur
# alongside deterministic failures (bad credentials, a corrupt artifact) and
# must not make the helper retry those. The specific transport symptoms below
# are what the build 182 log actually contained.
NETWORK_REGEX='Could not resolve host'
NETWORK_REGEX+='|Temporary failure in name resolution'
NETWORK_REGEX+='|nodename nor servname provided'
NETWORK_REGEX+='|Recv failure'
NETWORK_REGEX+='|Send failure'
NETWORK_REGEX+='|Operation timed out'
NETWORK_REGEX+='|Connection timed out'
NETWORK_REGEX+='|Connection reset by peer'
NETWORK_REGEX+='|Failed to connect to'
NETWORK_REGEX+='|Network is unreachable'
NETWORK_REGEX+='|No route to host'
NETWORK_REGEX+='|early EOF'
NETWORK_REGEX+='|fetch-pack: invalid index-pack output'
NETWORK_REGEX+='|the remote end hung up'
NETWORK_REGEX+='|TLS handshake'
NETWORK_REGEX+='|LibreSSL SSL_connect'
NETWORK_REGEX+='|HTTP 5[0-9][0-9]'

# A strong deterministic error can never be fixed by fetching again, so it
# takes priority over any network text that appeared earlier in the same log.
# Artifact mapping is intentionally NOT listed: the real build 182 log paired
# it with a DNS cascade, and that cascade is worth a bounded retry.
DETERMINISTIC_REGEX='checksum (mismatch|fail|error|invalid|does not match)'
DETERMINISTIC_REGEX+='|manifest (parse|parsing|error|invalid|could not)'
DETERMINISTIC_REGEX+='|authentication failed'
DETERMINISTIC_REGEX+='|permission denied'
DETERMINISTIC_REGEX+='|could not read username'
DETERMINISTIC_REGEX+='|http 40[13]'
DETERMINISTIC_REGEX+='|unsupported package.resolved schema'
DETERMINISTIC_REGEX+='|resolved dependency differs'

usage() {
  cat >&2 <<'USAGE'
Usage: resolve_xcode_dependencies.sh [options]

Required:
  --project PATH              Xcode project, e.g. FloeAgent.xcodeproj
  --scheme NAME               Xcode scheme
  --configuration NAME        Build configuration, e.g. Debug / Release
  --destination DEST          Build destination (same as the real build)
  --package-cache-path PATH   Same -packageCachePath as the real build
  --derived-data-path PATH    Same -derivedDataPath as the real build
  --resolved-file PATH        Tracked host Package.resolved that must not change
  --log-dir PATH              Directory for the raw per-attempt logs

Optional:
  --canonical-lock PATH       Committed HEAD Package.resolved used as the
                              read-only pin baseline (default: --resolved-file)
  --xcode-lock PATH           Actual Xcode workspace lock
                              (PROJECT.xcodeproj/project.xcworkspace/
                              xcshareddata/swiftpm/Package.resolved)
  --project-yml PATH          XcodeGen project.yml supplying app-only pins
  --sdk NAME                  Optional -sdk value (e.g. iphoneos)
  --max-attempts N            Total attempts, 1..3 (default 3)
  --retry-delay SECONDS       Base backoff, default 20 (attempt * base)
  --xcodebuild PATH           xcodebuild executable or wrapper, default xcodebuild
  -h, --help                  Show this help
USAGE
}

die_usage() {
  echo "error: $1" >&2
  usage
  exit 1
}

project=""
scheme=""
configuration=""
destination=""
package_cache_path=""
derived_data_path=""
log_dir=""
resolved_file=""
canonical_file=""
xcode_lock=""
project_yml=""
sdk=""
max_attempts=3
retry_delay=20
xcodebuild_cmd="xcodebuild"

need_value() {
  [ "$#" -ge 1 ] || die_usage "missing value for $opt"
}

while [ "$#" -gt 0 ]; do
  opt="$1"
  shift
  case "$opt" in
    --project) need_value "$@"; project="$1"; shift ;;
    --scheme) need_value "$@"; scheme="$1"; shift ;;
    --configuration) need_value "$@"; configuration="$1"; shift ;;
    --destination) need_value "$@"; destination="$1"; shift ;;
    --package-cache-path) need_value "$@"; package_cache_path="$1"; shift ;;
    --derived-data-path) need_value "$@"; derived_data_path="$1"; shift ;;
    --resolved-file) need_value "$@"; resolved_file="$1"; shift ;;
    --canonical-lock) need_value "$@"; canonical_file="$1"; shift ;;
    --xcode-lock) need_value "$@"; xcode_lock="$1"; shift ;;
    --project-yml) need_value "$@"; project_yml="$1"; shift ;;
    --log-dir) need_value "$@"; log_dir="$1"; shift ;;
    --sdk) need_value "$@"; sdk="$1"; shift ;;
    --max-attempts) need_value "$@"; max_attempts="$1"; shift ;;
    --retry-delay) need_value "$@"; retry_delay="$1"; shift ;;
    --xcodebuild) need_value "$@"; xcodebuild_cmd="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown option: $opt" ;;
  esac
done

for required in project scheme configuration destination package_cache_path \
  derived_data_path log_dir resolved_file; do
  [ -n "${!required}" ] || die_usage "missing required option --${required//_/-}"
done

# The release contract is a bounded retry: exactly 1..3 total attempts. A
# larger value would let a transient network partition consume the release
# timeout, so it is rejected rather than clamped.
case "$max_attempts" in
  1|2|3) ;;
  ''|*[!0-9]*) die_usage "--max-attempts must be an integer between 1 and 3 (got: $max_attempts)" ;;
  *) die_usage "--max-attempts must be between 1 and 3 (got: $max_attempts)" ;;
esac
case "$retry_delay" in
  ''|*[!0-9]*) die_usage "--retry-delay must be a non-negative integer" ;;
esac

[ -f "$resolved_file" ] || die_usage "resolved file not found: $resolved_file"
[ -n "$xcodebuild_cmd" ] || die_usage "--xcodebuild must not be empty"
canonical_file="${canonical_file:-$resolved_file}"
[ -f "$canonical_file" ] || die_usage "canonical lock not found: $canonical_file"
if [ -n "$project_yml" ]; then
  [ -f "$project_yml" ] || die_usage "project.yml not found: $project_yml"
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"

attempt=1
last_code=0
classification=""

write_summary() {
  {
    echo "attempts=$attempt"
    echo "max_attempts=$max_attempts"
    echo "classification=$classification"
    echo "last_exit=$last_code"
    echo "project=$project"
    echo "scheme=$scheme"
    echo "configuration=$configuration"
    echo "destination=$destination"
    echo "package_cache_path=$package_cache_path"
    echo "derived_data_path=$derived_data_path"
    echo "resolved_file=$resolved_file"
    echo "canonical_file=$canonical_file"
    echo "xcode_lock=$xcode_lock"
    echo "xcode_lock_status=$xcode_lock_status"
    echo "xcode_lock_bytes=$xcode_lock_bytes"
    echo "project_yml=$project_yml"
    echo "log_dir=$log_dir"
    echo -n "logs="
    ls "$log_dir"/resolve-attempt-*.log 2>/dev/null |
      while IFS= read -r line; do printf '%s ' "${line##*/}"; done
    echo
  } > "$log_dir/resolve-summary.txt"
}

# verify_lock LABEL LOCK MODE
#   MODE=canonical  the resolved pins must be a subset of the committed lock
#                   (a host lock may legitimately omit app-only pins)
#   MODE=xcode      additionally every committed and app-only pin must be
#                   present in the actual Xcode lock
# Uses the shared schema normalization / verify_resolution so v1 and v2/v3
# locks compare identically and app-only WhisperKit is not dropped.
verify_lock() {
  FLOE_SCRIPTS_DIR="$script_dir" \
  FLOE_VERIFY_LABEL="$1" \
  FLOE_VERIFY_LOCK="$2" \
  FLOE_VERIFY_MODE="$3" \
  FLOE_VERIFY_CANONICAL="$canonical_file" \
  FLOE_VERIFY_PROJECT_YML="$project_yml" \
  python3 - <<'PY'
import json
import os
import sys

sys.path.insert(0, os.environ["FLOE_SCRIPTS_DIR"])
from resolved_pins import application_pins, resolved_pins, verify_resolution

label = os.environ["FLOE_VERIFY_LABEL"]
mode = os.environ["FLOE_VERIFY_MODE"]
try:
    with open(os.environ["FLOE_VERIFY_CANONICAL"], encoding="utf-8") as handle:
        canonical = resolved_pins(json.load(handle))
    app = []
    project_yml = os.environ.get("FLOE_VERIFY_PROJECT_YML", "")
    if project_yml:
        with open(project_yml, encoding="utf-8") as handle:
            app = application_pins(handle.read())
    with open(os.environ["FLOE_VERIFY_LOCK"], encoding="utf-8") as handle:
        current = resolved_pins(json.load(handle))
    combined = verify_resolution(current, canonical, app)
    if mode == "xcode":
        present = {pin["identity"] for pin in current}
        missing = [pin["identity"] for pin in combined if pin["identity"] not in present]
        if missing:
            raise ValueError(
                "actual Xcode lock is missing pinned dependencies: " + ", ".join(missing))
except (ValueError, OSError, json.JSONDecodeError) as exc:
    print(f"error: {label}: {exc}", file=sys.stderr)
    sys.exit(1)
appendix = f" (+{len(app)} app-only)" if app else ""
print(f"{label}: {len(current)} pins verified against committed lock{appendix}")
PY
}

# ---------------------------------------------------------------------------
# Pre-flight. Every failure here stops before xcodebuild is invoked, so a
# missing log directory, an unreadable backup or an unusable hash never risks
# touching the package graph.
# ---------------------------------------------------------------------------
mkdir -p "$log_dir" || {
  echo "error: cannot create log directory: $log_dir" >&2
  exit 1
}

original_backup="$log_dir/Package.resolved.original"
cp "$resolved_file" "$original_backup" || {
  echo "error: cannot back up tracked lock: $resolved_file" >&2
  exit 1
}
original_hash="$(shasum -a 256 "$resolved_file" | cut -d' ' -f1)" || {
  echo "error: cannot hash tracked lock: $resolved_file" >&2
  exit 1
}
[ -n "$original_hash" ] || {
  echo "error: empty hash for tracked lock: $resolved_file" >&2
  exit 1
}

xcode_lock_status="not-configured"
xcode_lock_bytes="not-configured"
xcode_lock_backup=""
xcode_lock_hash=""
xcode_lock_restore=""
if [ -n "$xcode_lock" ]; then
  xcode_lock_dir="$(dirname "$xcode_lock")"
  mkdir -p "$xcode_lock_dir" || {
    echo "error: cannot create Xcode lock directory: $xcode_lock_dir" >&2
    exit 1
  }
  if [ -f "$xcode_lock" ]; then
    # Never clobber an existing lock that disagrees with the committed pins.
    if ! verify_lock "existing xcode lock" "$xcode_lock" xcode; then
      xcode_lock_status="existing-mismatch"
      classification="xcode-lock-mismatch"
      write_summary
      echo "error: existing $xcode_lock disagrees with the committed lock; not overwriting and not resolving" >&2
      exit 1
    fi
    xcode_lock_status="existing-verified"
  else
    # First generation for this checkout: seed the actual Xcode lock from the
    # committed HEAD lock (which already carries app-only WhisperKit) instead
    # of letting xcodebuild pick versions from the network.
    cp "$canonical_file" "$xcode_lock" || {
      echo "error: cannot initialize Xcode lock from committed lock: $canonical_file" >&2
      exit 1
    }
    if ! verify_lock "initialized xcode lock" "$xcode_lock" xcode; then
      xcode_lock_status="initialization-invalid"
      classification="xcode-lock-invalid"
      write_summary
      echo "error: committed lock failed Xcode-lock verification; not resolving" >&2
      exit 1
    fi
    xcode_lock_status="initialized-from-committed"
  fi
  xcode_lock_backup="$log_dir/Package.resolved.xcode.original"
  cp "$xcode_lock" "$xcode_lock_backup" || {
    echo "error: cannot back up Xcode lock: $xcode_lock" >&2
    exit 1
  }
  xcode_lock_hash="$(shasum -a 256 "$xcode_lock" | cut -d' ' -f1)" || {
    echo "error: cannot hash Xcode lock: $xcode_lock" >&2
    exit 1
  }
  [ -n "$xcode_lock_hash" ] || {
    echo "error: empty hash for Xcode lock: $xcode_lock" >&2
    exit 1
  }
  xcode_lock_restore="$xcode_lock_backup"
  xcode_lock_bytes="identical"
fi

build_args=(
  -resolvePackageDependencies
  -project "$project"
  -scheme "$scheme"
  -configuration "$configuration"
  -destination "$destination"
  -packageCachePath "$package_cache_path"
  -derivedDataPath "$derived_data_path"
  -skipPackagePluginValidation
  -skipMacroValidation
)
if [ -n "$sdk" ]; then
  build_args+=(-sdk "$sdk")
fi

while [ "$attempt" -le "$max_attempts" ]; do
  log_file="$log_dir/resolve-attempt-$attempt.log"
  echo "== xcodebuild package resolution attempt $attempt/$max_attempts =="
  echo "command: $xcodebuild_cmd ${build_args[*]}"

  # The raw xcodebuild output is written to the log untouched; pipefail makes
  # the pipeline status the xcodebuild status, not tee's.
  "$xcodebuild_cmd" "${build_args[@]}" 2>&1 | tee "$log_file"
  last_code=$?

  if [ ! -f "$resolved_file" ]; then
    cp "$original_backup" "$resolved_file"
    classification="lock-missing"
    write_summary
    echo "error: $resolved_file was removed during resolution; original restored" >&2
    exit 1
  fi

  current_hash="$(shasum -a 256 "$resolved_file" | cut -d' ' -f1)"
  if [ "$current_hash" != "$original_hash" ]; then
    # Keep the rewritten bytes as failure evidence before restoring the
    # committed host lock, so the diff is never lost.
    cp "$resolved_file" "$log_dir/Package.resolved.mutated"
    cp "$original_backup" "$resolved_file"
    classification="lock-mutated"
    write_summary
    echo "error: xcodebuild rewrote $resolved_file; changed copy kept as Package.resolved.mutated and original restored" >&2
    exit 1
  fi

  if [ -n "$xcode_lock" ]; then
    if [ ! -f "$xcode_lock" ]; then
      cp "$xcode_lock_restore" "$xcode_lock"
      classification="xcode-lock-missing"
      xcode_lock_bytes="deleted"
      write_summary
      echo "error: $xcode_lock was removed during resolution; original restored" >&2
      exit 1
    fi
    current_xcode_hash="$(shasum -a 256 "$xcode_lock" | cut -d' ' -f1)"
    if [ "$current_xcode_hash" != "$xcode_lock_hash" ]; then
      # Xcode legitimately rewrites its own lock: originHash metadata, a
      # v1/v3 schema transcription or pure formatting. A byte change is only
      # dependency drift when the normalized pins differ, so compare
      # identities/version/revision/location and allow cosmetic changes.
      if verify_lock "rewritten xcode lock" "$xcode_lock" xcode; then
        cp "$xcode_lock_restore" "$log_dir/Package.resolved.xcode.before"
        cp "$xcode_lock" "$log_dir/Package.resolved.xcode.after"
        cp "$xcode_lock" "$log_dir/Package.resolved.xcode.accepted"
        xcode_lock_restore="$log_dir/Package.resolved.xcode.accepted"
        xcode_lock_hash="$current_xcode_hash"
        xcode_lock_bytes="reformatted"
        xcode_lock_status="format-normalized"
        echo "note: xcodebuild rewrote $xcode_lock with identical normalized pins (originHash/schema/format); before/after copies kept" >&2
      else
        cp "$xcode_lock" "$log_dir/Package.resolved.xcode.mutated"
        cp "$xcode_lock_restore" "$xcode_lock"
        classification="xcode-lock-mutated"
        xcode_lock_bytes="drifted"
        write_summary
        echo "error: xcodebuild changed normalized pins in the actual Xcode lock $xcode_lock; drift copy kept as Package.resolved.xcode.mutated and the committed lock restored" >&2
        exit 1
      fi
    else
      xcode_lock_bytes="identical"
    fi
  fi

  if [ "$last_code" -eq 0 ]; then
    if [ -n "$xcode_lock" ] && ! verify_lock "resolved xcode lock" "$xcode_lock" xcode; then
      classification="xcode-lock-invalid"
      write_summary
      echo "error: $xcode_lock does not match the committed pins; resolution rejected" >&2
      exit 1
    fi
    classification="success"
    write_summary
    echo "xcodebuild package resolution succeeded on attempt $attempt"
    exit 0
  fi

  # Deterministic errors outrank a network signature that appeared earlier in
  # the same log: retrying a checksum/manifest/auth failure cannot help.
  if grep -E -i -q "$DETERMINISTIC_REGEX" "$log_file"; then
    classification="deterministic"
    write_summary
    echo "error: deterministic package resolution failure (exit $last_code); not retried; raw log: $log_file" >&2
    exit "$last_code"
  fi

  if grep -E -i -q "$NETWORK_REGEX" "$log_file"; then
    if [ "$attempt" -lt "$max_attempts" ]; then
      classification="network-retry"
      delay=$((retry_delay * attempt))
      echo "network resolution failure on attempt $attempt (exit $last_code); retrying after ${delay}s" >&2
      [ "$delay" -gt 0 ] && sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi
    classification="network-exhausted"
    write_summary
    echo "error: network resolution failed after $max_attempts attempts; raw logs in $log_dir" >&2
    exit "$last_code"
  fi

  classification="deterministic"
  write_summary
  echo "error: non-network package resolution failure (exit $last_code); not retried; raw log: $log_file" >&2
  exit "$last_code"
done

# Unreachable: every loop path exits.
write_summary
exit 1
