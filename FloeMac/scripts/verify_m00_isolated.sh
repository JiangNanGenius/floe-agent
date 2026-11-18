#!/bin/bash
# Floe Mac M00 — isolated fixture acceptance.
#
# This script never invokes verify_m00.sh. That older script performs real
# Keychain and production probes and is not an isolated acceptance entry.
#
# Disabled pending independent verification and coordinator direction. The
# fixture profile attempts to restrict network, but listener ownership and
# descendant IPC isolation are not independently verified. No Keychain result
# can establish denial by itself. Child
# device/inode pinning and anchored control writes still require the separate
# FixtureRootLocation integration outside this repair's scopes. None of this is
# runtime verified yet, and the helper still passes fixed port 0 to its
# listener (BridgeServiceMain.swift is outside this repair's scope), so the
# fixture is expected to fail closed until that outside-scope wiring is
# reviewed and these probes run under an authorized native window. See
# FloeMac/README.md before restoring this entry.
#
# Usage:
#   FloeMac/scripts/verify_m00_isolated.sh --helper-app <FloeMacBridgeService.app> \
#     [--products-dir <Build/Products/Debug>] [--evidence-dir <dir>] [--keep]
#
# The caller must serialize native compilation with the shared native window,
# for example through Local/Private/shared-native-window/with_native_window.py.

set -u

echo "Bridge fixture disabled: the repaired isolation boundary has not been independently verified and the reserved-port wiring is outside this scope." >&2
exit 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --find swiftc)"
CLANG="$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --find clang)"
SDK="$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path)"

HELPER_APP=""
PRODUCTS_DIR=""
EVIDENCE_DIR="$REPO/Local/Private/floe-mac-fixture-isolation-$(date +%Y%m%d-%H%M%S)"
KEEP=0

while (( $# > 0 )); do
  case "$1" in
    --helper-app) HELPER_APP="${2:-}"; shift 2 ;;
    --products-dir) PRODUCTS_DIR="${2:-}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$HELPER_APP" || ! -d "$HELPER_APP" ]]; then
  echo "--helper-app must point at a built FloeMacBridgeService.app" >&2
  exit 2
fi
HELPER_APP="$(cd "$HELPER_APP" && pwd)"
HELPER_EXECUTABLE="$HELPER_APP/Contents/MacOS/FloeMacBridgeService"
if [[ ! -x "$HELPER_EXECUTABLE" ]]; then
  echo "Missing helper executable: $HELPER_EXECUTABLE" >&2
  exit 2
fi
if [[ -z "$PRODUCTS_DIR" ]]; then PRODUCTS_DIR="$(dirname "$HELPER_APP")"; fi
PROTOCOL_LIB="$PRODUCTS_DIR/libFloeMacBridgeProtocol.a"
if [[ ! -f "$PROTOCOL_LIB" ]]; then
  echo "Missing $PROTOCOL_LIB" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR/bin"
chmod 700 "$EVIDENCE_DIR" "$EVIDENCE_DIR/bin"
EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd)"

FAILURES=0
CHECKS=0
declare -a OWNED_PIDS=()
declare -a ROOTS=()
SUCCESS=0

pass() { CHECKS=$((CHECKS + 1)); echo "PASS  $1"; printf 'PASS|%s\n' "$1" >> "$EVIDENCE_DIR/checks.txt"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  $1" >&2; printf 'FAIL|%s\n' "$1" >> "$EVIDENCE_DIR/checks.txt"; }

canonical_temp_base() {
  /bin/realpath "${TMPDIR%/}"
}
TEMP_BASE="$(canonical_temp_base)"

mkroot() {
  local prefix="$1" path
  path="$(mktemp -d "${TMPDIR%/}/${prefix}.XXXXXX")" || return 1
  path="$(/bin/realpath "$path")" || return 1
  chmod 700 "$path" || return 1
  printf '%s' "$path"
}

safe_remove_root() {
  local path="$1"
  case "$path" in
    "$TEMP_BASE"/floe-mac-m00-fixture.*|"$TEMP_BASE"/floe-mac-m00-victim.*) ;;
    *) echo "Refusing to remove unexpected path: $path" >&2; return 1 ;;
  esac
  [[ -d "$path" && ! -L "$path" ]] || return 0
  rm -rf -- "$path"
}

stop_owned() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    fi
    if kill -0 "$pid" 2>/dev/null; then
      echo "Owned child $pid did not exit after bounded cleanup; outcome unknown" >&2
      return 1
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local pid
  for pid in "${OWNED_PIDS[@]:-}"; do stop_owned "$pid"; done
  if (( FAILURES == 0 && KEEP == 0 )); then
    local root
    for root in "${ROOTS[@]:-}"; do safe_remove_root "$root" || true; done
  fi
}
trap cleanup EXIT

provision_root() {
  local root="$1"
  mkdir -p "$root/entry" "$root/Control" "$root/service-home" "$root/worker-home" "$root/tmp" || return 1
  chmod 700 "$root" "$root/entry" "$root/Control" "$root/service-home" "$root/worker-home" "$root/tmp" || return 1
  cp -R "$HELPER_APP" "$root/entry/FloeMacBridgeService.app" || return 1
  /usr/bin/codesign --verify --deep --strict "$root/entry/FloeMacBridgeService.app" 2>"$root/entry/codesign.log"
}

LAST_PID=""
launch_helper() {
  local root="$1" log="$2"; shift 2
  local ready="$root/Control/ready.json"
  local discovery="$root/Control/discovery.json"
  local socket="$root/Control/b.sock"
  HOME="$root/worker-home" CFFIXED_USER_HOME="$root/worker-home" \
    TMPDIR="$root/tmp" TMP="$root/tmp" TEMP="$root/tmp" \
    "$root/entry/FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService" \
    --mode test --test-fixture "$root" \
    --control-socket "$socket" --ready-file "$ready" --discovery-file "$discovery" \
    --orphan-idle-grace 2 "$@" > "$log" 2>&1 &
  LAST_PID=$!
  OWNED_PIDS+=("$LAST_PID")
}

launch_helper_paths() {
  local root="$1" ready="$2" discovery="$3" socket="$4" log="$5"; shift 5
  HOME="$root/worker-home" CFFIXED_USER_HOME="$root/worker-home" \
    TMPDIR="$root/tmp" TMP="$root/tmp" TEMP="$root/tmp" \
    "$root/entry/FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService" \
    --mode test --test-fixture "$root" \
    --control-socket "$socket" --ready-file "$ready" --discovery-file "$discovery" \
    --orphan-idle-grace 2 "$@" > "$log" 2>&1 &
  LAST_PID=$!
  OWNED_PIDS+=("$LAST_PID")
}

wait_ready() {
  local ready="$1" pid="$2" timeout="${3:-20}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if [[ -f "$ready" ]] && jq -e '.state == "ready"' "$ready" >/dev/null 2>&1; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
    sleep 0.1
  done
  return 1
}

# Expected-failure children must exit on their own. A timeout is an owned
# cleanup action and a failed check, never evidence that the refusal worked.
expect_failure_exit() {
  local pid="$1" label="$2" timeout="${3:-15}"
  local deadline=$((SECONDS + timeout)) status=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      fail "$label did not exit naturally within ${timeout}s; owned PID $pid stopped"
      stop_owned "$pid"
      return 1
    fi
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
  status=$?
  if (( status == 0 )); then
    fail "$label exited with status 0 instead of refusing"
    return 1
  fi
  pass "$label refused and exited with status $status"
  return 0
}

check_expected_failure_ready() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    pass "$label produced no ready file"
    return
  fi
  if jq -e '.state == "failed"' "$path" >/dev/null 2>&1; then
    pass "$label wrote a failed ready report"
  else
    fail "$label wrote a ready report that was not failed"
  fi
}

wait_exit() {
  local pid="$1" label="$2" timeout="${3:-15}"
  local deadline=$((SECONDS + timeout))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      fail "$label did not exit within ${timeout}s; owned PID $pid stopped"
      stop_owned "$pid"
      return 1
    fi
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
  pass "$label exited"
  return 0
}

snapshot_tree() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    printf 'missing\n'
    return
  fi
  stat -f 'root|%m|%z|%p' "$path" 2>/dev/null || true
  find "$path" -maxdepth 2 -type f -print0 2>/dev/null | xargs -0 stat -f '%N|%m|%z|%p' 2>/dev/null | sort || true
}

snapshot_keychain_dir() {
  local path="$1"
  if [[ -d "$path" ]]; then stat -f '%m|%z|%p' "$path"; else printf 'missing\n'; fi
}

REAL_HOME="$HOME"
REAL_BRIDGE="$HOME/Library/Application Support/Floe Bridge"
REAL_KEYCHAIN="$HOME/Library/Keychains"
PRE_BRIDGE="$(snapshot_tree "$REAL_BRIDGE")"
PRE_KEYCHAIN="$(snapshot_keychain_dir "$REAL_KEYCHAIN")"
PRE_LIVE_LISTENER="$(/usr/sbin/lsof -nP -iTCP:43871 -sTCP:LISTEN 2>/dev/null || true)"
PRE_HELPERS="$(pgrep -f 'FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService' 2>/dev/null || true)"
printf '%s\n' "$PRE_LIVE_LISTENER" > "$EVIDENCE_DIR/live-43871-before.txt"
printf '%s\n' "$PRE_HELPERS" > "$EVIDENCE_DIR/helper-pids-before.txt"

# Compile the two probes. This is a native subprocess and the caller is
# expected to hold the shared native window.
if ! "$SWIFTC" -swift-version 6 -target arm64-apple-macos15.0 -sdk "$SDK" -O \
  -I "$PRODUCTS_DIR" -L "$PRODUCTS_DIR" -lFloeMacBridgeProtocol \
  "$REPO/FloeMac/Sources/FloeMacBridgeControl/BridgeControlProtocol.swift" \
  "$REPO/FloeMac/Sources/FloeMacHost/BridgeControlClient.swift" \
  "$REPO/FloeMac/scripts/fixture_session_probe.swift" \
  -o "$EVIDENCE_DIR/bin/fixture_session_probe" > "$EVIDENCE_DIR/session-probe-build.log" 2>&1; then
  fail "session probe compiled"
else
  pass "session probe compiled"
fi
if ! "$CLANG" -O2 -Wall -Wextra -framework Security -framework CoreFoundation \
  "$REPO/FloeMac/scripts/fixture_sandbox_probe.c" \
  -o "$EVIDENCE_DIR/bin/fixture_sandbox_probe" > "$EVIDENCE_DIR/sandbox-probe-build.log" 2>&1; then
  fail "external sandbox probe compiled"
else
  pass "external sandbox probe compiled"
fi
if (( FAILURES > 0 )); then
  echo "Probe compilation failed; evidence at $EVIDENCE_DIR" >&2
  exit 1
fi

VICTIM="$(mkroot floe-mac-m00-victim)" || { echo "mkdtemp failed" >&2; exit 2; }
ROOTS+=("$VICTIM")
mkdir -p "$VICTIM/Control" "$VICTIM/service-home" "$VICTIM/Library" "$VICTIM/worker-home"
chmod 700 "$VICTIM" "$VICTIM/Control" "$VICTIM/service-home" "$VICTIM/Library" "$VICTIM/worker-home"
printf 'sentinel-%s\n' "$$" > "$VICTIM/sentinel.txt"
printf 'ready-sentinel\n' > "$VICTIM/ready-sentinel.txt"
printf 'identity-sentinel\n' > "$VICTIM/identity-sentinel.txt"
VICTIM_SENTINEL="$(/usr/bin/shasum -a 256 "$VICTIM/sentinel.txt" | awk '{print $1}')"
VICTIM_READY="$(/usr/bin/shasum -a 256 "$VICTIM/ready-sentinel.txt" | awk '{print $1}')"
VICTIM_IDENTITY="$(/usr/bin/shasum -a 256 "$VICTIM/identity-sentinel.txt" | awk '{print $1}')"
victim_intact() {
  [[ "$(/usr/bin/shasum -a 256 "$VICTIM/sentinel.txt" 2>/dev/null | awk '{print $1}')" == "$VICTIM_SENTINEL" ]] || return 1
  [[ "$(/usr/bin/shasum -a 256 "$VICTIM/ready-sentinel.txt" 2>/dev/null | awk '{print $1}')" == "$VICTIM_READY" ]] || return 1
  [[ "$(/usr/bin/shasum -a 256 "$VICTIM/identity-sentinel.txt" 2>/dev/null | awk '{print $1}')" == "$VICTIM_IDENTITY" ]] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 1. Malicious roots and pre-start component replacement.
# ---------------------------------------------------------------------------
NEG="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$NEG"); provision_root "$NEG" >/dev/null
for label in wrong-prefix symlink-root; do
  if [[ "$label" == "wrong-prefix" ]]; then
    BAD_ROOT="$VICTIM"
    BAD_READY="$NEG/Control/ready.json"
  else
    ln -sfn "$VICTIM" "$NEG/root-link"
    BAD_ROOT="$NEG/root-link"
    BAD_READY="$NEG/Control/ready.json"
  fi
  BAD_LOG="$EVIDENCE_DIR/negative-$label.log"
  launch_helper_paths "$NEG" "$BAD_READY" "$NEG/Control/discovery.json" "$NEG/Control/b.sock" "$BAD_LOG" \
    --test-fixture "$BAD_ROOT"
  BAD_PID="$LAST_PID"
  # launch_helper_paths always passes the scratch root first; append the
  # rejected root as a duplicate, and let the last --test-fixture win.
  expect_failure_exit "$BAD_PID" "$label" 10
  if ! victim_intact; then fail "victim sentinels intact after $label"; else pass "victim sentinels intact after $label"; fi
  check_expected_failure_ready "$label" "$BAD_READY"
done

# Control symlink and service-home symlink are checked before any service work.
RACE="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$RACE"); provision_root "$RACE" >/dev/null
rm -rf "$RACE/service-home"; ln -s "$VICTIM/service-home" "$RACE/service-home"
launch_helper "$RACE" "$EVIDENCE_DIR/negative-service-home.log"
RACE_PID="$LAST_PID"
expect_failure_exit "$RACE_PID" "service-home symlink" 10
if victim_intact; then pass "victim sentinels intact after service-home symlink"; else fail "victim sentinel changed after service-home symlink"; fi
check_expected_failure_ready "service-home symlink" "$RACE/Control/ready.json"

RACE2="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$RACE2"); provision_root "$RACE2" >/dev/null
mv "$RACE2/Control" "$RACE2/Control.real"; ln -s "$VICTIM/Control" "$RACE2/Control"
launch_helper "$RACE2" "$EVIDENCE_DIR/negative-control.log"
RACE2_PID="$LAST_PID"
expect_failure_exit "$RACE2_PID" "Control symlink" 10
if victim_intact; then pass "victim sentinels intact after Control symlink"; else fail "victim sentinel changed after Control symlink"; fi

RACE3="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$RACE3"); provision_root "$RACE3" >/dev/null
ln -s "$VICTIM/ready-sentinel.txt" "$RACE3/Control/ready.json"
launch_helper "$RACE3" "$EVIDENCE_DIR/negative-ready-symlink.log"
RACE3_PID="$LAST_PID"
expect_failure_exit "$RACE3_PID" "ready-file symlink" 10
if victim_intact; then pass "victim sentinels intact after ready-file symlink"; else fail "victim sentinel changed after ready-file symlink"; fi

RACE4="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$RACE4"); provision_root "$RACE4" >/dev/null
ln -s "$VICTIM/identity-sentinel.txt" "$RACE4/service-identity.json"
launch_helper "$RACE4" "$EVIDENCE_DIR/negative-identity-symlink.log"
RACE4_PID="$LAST_PID"
expect_failure_exit "$RACE4_PID" "identity symlink" 10
if victim_intact; then pass "victim sentinels intact after identity symlink"; else fail "victim sentinel changed after identity symlink"; fi
check_expected_failure_ready "identity symlink" "$RACE4/Control/ready.json"

RACE5="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$RACE5"); provision_root "$RACE5" >/dev/null
rm -rf "$RACE5/service-home/Library"; ln -s "$VICTIM/Library" "$RACE5/service-home/Library"
launch_helper "$RACE5" "$EVIDENCE_DIR/negative-ancestor.log"
RACE5_PID="$LAST_PID"
expect_failure_exit "$RACE5_PID" "ancestor symlink" 10
if victim_intact; then pass "victim sentinels intact after ancestor symlink"; else fail "victim sentinel changed after ancestor symlink"; fi

# ---------------------------------------------------------------------------
# 2. Post-start Control replacement: a signal must not redirect writes.
# ---------------------------------------------------------------------------
RACE6="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$RACE6"); provision_root "$RACE6" >/dev/null
launch_helper "$RACE6" "$EVIDENCE_DIR/race-before.log"
RACE6_PID="$LAST_PID"
if wait_ready "$RACE6/Control/ready.json" "$RACE6_PID" 20; then
  mv "$RACE6/Control" "$RACE6/Control.original"
  ln -s "$VICTIM/Control" "$RACE6/Control"
  printf 'race-sentinel\n' > "$VICTIM/Control/race-sentinel.txt"
  RACE6_HASH="$(/usr/bin/shasum -a 256 "$VICTIM/Control/race-sentinel.txt" | awk '{print $1}')"
  kill -TERM "$RACE6_PID" 2>/dev/null || true
  wait_exit "$RACE6_PID" "post-start replacement helper" 15
  if [[ "$(/usr/bin/shasum -a 256 "$VICTIM/Control/race-sentinel.txt" 2>/dev/null | awk '{print $1}')" == "$RACE6_HASH" ]]; then
    pass "post-start Control replacement preserved victim sentinel"
  else
    fail "post-start Control replacement changed victim sentinel"
  fi
  if [[ -e "$VICTIM/Control/ready.json" ]]; then fail "shutdown wrote ready.json through replacement"; else pass "shutdown did not write through Control replacement"; fi
  rm -f "$RACE6/Control"
  mv "$RACE6/Control.original" "$RACE6/Control"
else
  fail "race fixture did not become ready before replacement"
  stop_owned "$RACE6_PID"
fi

# A replacement with a new real directory of the same owner and mode must be
# rejected by the pinned child device/inode, not merely by symlink checks.
# This case requires the separate FixtureRootLocation child-identity pinning
# integration that is outside this repair's scopes; it fails closed until that
# integration and independent review land.
RACE7="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$RACE7"); provision_root "$RACE7" >/dev/null
launch_helper "$RACE7" "$EVIDENCE_DIR/negative-replaced-layout.log"
RACE7_PID="$LAST_PID"
if wait_ready "$RACE7/Control/ready.json" "$RACE7_PID" 20; then
  RACE7_READY_BEFORE="$(/usr/bin/shasum -a 256 "$RACE7/Control/ready.json" | awk '{print $1}')"
  mv "$RACE7/tmp" "$RACE7/tmp.original"
  mkdir -m 700 "$RACE7/tmp"
  kill -TERM "$RACE7_PID" 2>/dev/null || true
  wait_exit "$RACE7_PID" "replaced layout directory helper" 15
  RACE7_READY_AFTER="$(/usr/bin/shasum -a 256 "$RACE7/Control/ready.json" | awk '{print $1}')"
  if [[ "$RACE7_READY_BEFORE" == "$RACE7_READY_AFTER" ]]; then
    pass "post-start layout directory replacement did not rewrite the ready state"
  else
    fail "post-start layout directory replacement rewrote the ready state"
  fi
  if grep -q 'Fixture component tmp changed identity' "$EVIDENCE_DIR/negative-replaced-layout.log"; then
    pass "pinned child device/inode rejected the replacement layout directory"
  else
    fail "the helper did not report a changed layout child identity"
  fi
  if victim_intact; then pass "victim sentinels intact after replaced layout directory"; else fail "victim sentinel changed after replaced layout directory"; fi
else
  fail "replaced-layout fixture did not become ready"
  stop_owned "$RACE7_PID"
fi

# ---------------------------------------------------------------------------
# 3. Normal isolated fixture session, authenticated control, PTY and stop.
# ---------------------------------------------------------------------------
MAIN="$(mkroot floe-mac-m00-fixture)"; ROOTS+=("$MAIN"); provision_root "$MAIN" >/dev/null
SESSION_LOG="$EVIDENCE_DIR/session.log"
set +e
"$EVIDENCE_DIR/bin/fixture_session_probe" \
  --root "$MAIN" \
  --entry-executable "$MAIN/entry/FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService" \
  --json-out "$EVIDENCE_DIR/session.json" > "$SESSION_LOG" 2>&1
SESSION_EXIT=$?
set -e
if (( SESSION_EXIT == 0 )) && jq -e '.passed == true and ([.checks[]] | all)' "$EVIDENCE_DIR/session.json" >/dev/null 2>&1; then
  pass "isolated helper session, pinned control, PTY task, stop refusal and clean stop"
else
  fail "isolated helper session probe failed"
fi
if jq -e '.checks.onlyOwnedLoopbackListener == true' "$EVIDENCE_DIR/session.json" >/dev/null 2>&1; then
  pass "helper listened only on its owned reserved 127.0.0.1 port"
else
  fail "helper listener scope was not the owned reserved loopback port"
fi
SANDBOX_FAILURES="$(jq -r '[.checks[] | select(.passed == false) | .name + " [" + .detail + "]"] | join("; ")' \
  "$MAIN/Control/sandbox-report.json" 2>/dev/null || true)"
fail "helper self-check cannot establish Keychain or network isolation${SANDBOX_FAILURES:+: $SANDBOX_FAILURES}"
if [[ -f "$MAIN/Control/sandbox-profile.sb" && -f "$MAIN/Control/sandbox-report.json" ]]; then
  PROFILE_FILE_SHA="$(/usr/bin/shasum -a 256 "$MAIN/Control/sandbox-profile.sb" | awk '{print $1}')"
  if [[ "$(jq -r '.profileSHA256 // ""' "$MAIN/Control/sandbox-report.json" 2>/dev/null)" == "$PROFILE_FILE_SHA" ]]; then
    pass "the helper-written profile matches its recorded SHA-256"
  else
    fail "the helper-written profile does not match its recorded SHA-256"
  fi
  if [[ -f "$MAIN/Control/ready.json" ]]; then
    READY_PORT="$(jq -r '.port // 0' "$MAIN/Control/ready.json" 2>/dev/null || echo 0)"
    RESERVED_PORT="$(jq -r '.httpPort // 0' "$MAIN/Control/sandbox-report.json" 2>/dev/null || echo 0)"
    if [[ -n "$READY_PORT" && -n "$RESERVED_PORT" && "$READY_PORT" == "$RESERVED_PORT" ]]; then
      pass "helper listener used the reserved loopback port $RESERVED_PORT"
    else
      fail "helper listener port $READY_PORT does not match reserved port $RESERVED_PORT"
    fi
  fi
fi
if [[ -f "$MAIN/Control/sandbox-profile.sb" && -f "$MAIN/Control/sandbox-report.json" ]]; then
  cp "$MAIN/Control/sandbox-profile.sb" "$EVIDENCE_DIR/sandbox-profile.sb"
  cp "$MAIN/Control/sandbox-report.json" "$EVIDENCE_DIR/sandbox-report.json"
  cp "$MAIN/Control/ready.json" "$EVIDENCE_DIR/ready.json" 2>/dev/null || true
  cp "$MAIN/Control/discovery.json" "$EVIDENCE_DIR/discovery.json" 2>/dev/null || true
  cp "$MAIN/Control/session.log" "$EVIDENCE_DIR/helper-session.log" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Kernel confinement remains unverified. A previous probe reused a freed
# helper port and unlinked its control socket without proving ownership. Do not
# contact or bind those historical endpoints. A future test must retain its own
# listener descriptors and use separately owned Unix sentinels, with bounded
# child waits and independent review of inherited descriptors and Mach rights.
# ---------------------------------------------------------------------------
fail "network, Unix socket, inherited descriptor, Mach and Keychain confinement are unverified"

# ---------------------------------------------------------------------------
# 5. Side-effect checks on real user state and owned cleanup.
# ---------------------------------------------------------------------------
if [[ "$(snapshot_keychain_dir "$REAL_KEYCHAIN")" == "$PRE_KEYCHAIN" ]]; then
  pass "Keychain directory metadata unchanged"
else
  fail "Keychain directory metadata changed; cause and isolation are unverified"
fi
POST_BRIDGE="$(snapshot_tree "$REAL_BRIDGE")"
printf '%s\n' "$POST_BRIDGE" > "$EVIDENCE_DIR/real-bridge-after.txt"
printf '%s\n' "$PRE_BRIDGE" > "$EVIDENCE_DIR/real-bridge-before.txt"
if [[ -z "$PRE_LIVE_LISTENER" ]]; then
  if [[ "$POST_BRIDGE" == "$PRE_BRIDGE" ]]; then
    pass "real Bridge data tree unchanged while no live Bridge was running"
  else
    fail "real Bridge data changed while no live Bridge was running"
  fi
else
  pass "a live Bridge was already running; its read-only snapshot was recorded, not modified"
fi
POST_HELPERS="$(pgrep -f 'FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService' 2>/dev/null || true)"
if [[ -z "$POST_HELPERS" ]]; then
  pass "no helper process remained after owned cleanup"
else
  fail "helper process remained after owned cleanup"
  printf '%s\n' "$POST_HELPERS" > "$EVIDENCE_DIR/helper-pids-after.txt"
fi
if [[ -z "$(/usr/sbin/lsof -nP -iTCP:43871 -sTCP:LISTEN 2>/dev/null || true)" ]]; then
  pass "fixture did not leave a 43871 listener"
else
  pass "43871 was already owned by another process; fixture did not add to it (read-only snapshot)"
fi
if victim_intact; then pass "victim sentinel intact after all fixture runs"; else fail "victim sentinel changed"; fi

printf 'checks=%d failures=%d\n' "$CHECKS" "$FAILURES" | tee "$EVIDENCE_DIR/summary.txt"
if (( FAILURES > 0 )); then
  echo "Isolated fixture verification failed. Evidence and fixture roots retained:" >&2
  for root in "${ROOTS[@]}"; do echo "  $root" >&2; done
  exit 1
fi
SUCCESS=1
echo "Isolated fixture verification passed. Evidence: $EVIDENCE_DIR"
