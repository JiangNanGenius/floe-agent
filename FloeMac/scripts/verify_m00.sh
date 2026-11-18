#!/bin/bash
# ISOLATED ACCEPTANCE WARNING: this script performs real Keychain and production
# probes. Do not use it for fixture isolation acceptance. Use
# verify_m00_isolated.sh instead.
# Floe Mac M00 — local verification of the assembled one-app package.
#
# Read-only with respect to the user's standalone Floe Bridge. Every service
# probe uses an isolated home and refuses to run if 127.0.0.1:43871 is already
# owned by another process. No install, notarization or upload is performed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TOOLCHAIN_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEVELOPER_DIR/../Info.plist")"
CHECKOUT_ID="$(printf '%s' "$REPO" | shasum -a 256 | cut -c1-12)"
CACHE_ROOT="${FLOE_MAC_M00_CACHE:-$HOME/Library/Caches/CodexBuild/floe-mac-m00/$CHECKOUT_ID/$TOOLCHAIN_ID}"
APP="${FLOE_MAC_M00_APP:-$CACHE_ROOT/package/Floe.app}"
SANDBOX="${FLOE_MAC_M00_VERIFY_ROOT:-$CACHE_ROOT/verify-$(date +%Y%m%d-%H%M%S)}"
RESULTS="$SANDBOX/results"
HOST="$APP/Contents/MacOS/Floe"
BRIDGE_HELPER="$APP/Contents/Helpers/FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService"
CATALYST_APP="$APP/Contents/Helpers/FloeMacAgentUI.app"
PORT=43871

FAILURES=0
CHECKS=0
CHECK_ROWS=()

pass() {
  CHECKS=$((CHECKS + 1)); CHECK_ROWS+=("PASS|$1"); echo "PASS  $1"
  printf 'PASS|%s\n' "$1" >> "$RESULTS/checks.txt"
}
fail() {
  CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); CHECK_ROWS+=("FAIL|$1"); echo "FAIL  $1" >&2
  printf 'FAIL|%s\n' "$1" >> "$RESULTS/checks.txt"
}

need() { [[ -e "$1" ]] || { echo "Missing required path: $1" >&2; exit 2; }; }
need "$APP"
need "$HOST"
need "$BRIDGE_HELPER"
need "$CATALYST_APP"
mkdir -p "$SANDBOX" "$RESULTS"

free_gib="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
if (( free_gib < 5 )); then
  echo "Only ${free_gib} GiB free on the internal SSD; verification needs a small bounded amount." >&2
  exit 2
fi

port_listeners() { /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true; }
bridge_processes() { /usr/bin/pgrep -f "FloeMacBridgeService.app/Contents/MacOS/FloeMacBridgeService" 2>/dev/null || true; }
host_processes() { /usr/bin/pgrep -f "$APP/Contents/MacOS/Floe" 2>/dev/null || true; }

snapshot_user_bridge() {
  local root="$HOME/Library/Application Support/Floe Bridge"
  if [[ ! -d "$root" ]]; then
    printf 'missing\n'
    return
  fi
  local root_m time_m count
  root_m="$(stat -f %m "$root" 2>/dev/null || echo 0)"
  time_m="$(stat -f %m "$root/State" 2>/dev/null || echo 0)"
  count="$(find "$root/State" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s|%s|%s\n' "$root_m" "$time_m" "$count"
}

if [[ -n "$(port_listeners)" ]]; then
  echo "127.0.0.1:$PORT already has a listener. Refusing to start or stop any Bridge." >&2
  echo "$(port_listeners)" >&2
  exit 3
fi
if [[ -n "$(bridge_processes)" ]]; then
  echo "A FloeMacBridgeService process is already running. Refusing to touch it." >&2
  exit 3
fi
BEFORE_USER_BRIDGE="$(snapshot_user_bridge)"

# Capture pre-existing app-domain artifacts so only files created by this
# verification are considered task-owned.
ARTIFACT_GLOBS=(
  "$HOME/Library/Containers/org.floeagent.mac.agentui"
  "$HOME/Library/Containers/org.floeagent.mac"
  "$HOME/Library/Application Support/org.floeagent.mac.agentui"
  "$HOME/Library/Application Support/org.floeagent.mac"
  "$HOME/Library/Application Support/Floe Mac/BridgeControl"
  "$HOME/Library/Caches/org.floeagent.mac.agentui"
  "$HOME/Library/Caches/org.floeagent.mac"
  "$HOME/Library/Preferences/org.floeagent.mac.agentui.plist"
  "$HOME/Library/Preferences/org.floeagent.mac.plist"
  "$HOME/Library/Saved Application State/org.floeagent.mac.agentui.savedState"
  "$HOME/Library/Saved Application State/org.floeagent.mac.savedState"
)
declare -a PREEXISTING_ARTIFACTS=()
for path in "${ARTIFACT_GLOBS[@]}"; do
  if [[ -e "$path" ]]; then PREEXISTING_ARTIFACTS+=("$path"); fi
done

MODE_ROOT="$SANDBOX/mode"
"$HOST" --print-mode --preference-root "$MODE_ROOT" > "$RESULTS/mode-first.json"
if jq -e '.mode=="agent" and .source=="firstRunDefault" and .isFirstRun==true and .preferenceExists==false' "$RESULTS/mode-first.json" >/dev/null; then
  pass "first run defaults to Agent without creating a preference"
else
  fail "first-run mode record is incorrect"
fi

"$HOST" --set-mode bridge --preference-root "$MODE_ROOT" > "$RESULTS/mode-set.json"
if jq -e '.saved==true and .mode=="bridge" and .source=="savedPreference" and .isFirstRun==false and .preferencePermissionsOctal=="600"' "$RESULTS/mode-set.json" >/dev/null; then
  pass "Bridge mode is saved atomically with 0600 permissions"
else
  fail "mode save record is incorrect"
fi

"$HOST" --print-mode --preference-root "$MODE_ROOT" > "$RESULTS/mode-reload.json"
if jq -e '.mode=="bridge" and .source=="savedPreference" and .isFirstRun==false' "$RESULTS/mode-reload.json" >/dev/null; then
  pass "saved mode is restored without Agent or Bridge initialization"
else
  fail "saved mode was not restored"
fi

CORRUPT_ROOT="$SANDBOX/corrupt-mode"
mkdir -p "$CORRUPT_ROOT"
printf '{not-valid-json' > "$CORRUPT_ROOT/mode-preference.json"
"$HOST" --print-mode --preference-root "$CORRUPT_ROOT" > "$RESULTS/mode-corrupt.json"
if jq -e '.source=="firstRunDefault" and .isFirstRun==true' "$RESULTS/mode-corrupt.json" >/dev/null; then
  pass "a malformed mode preference fails open to first run, not a crash or backend switch"
else
  fail "malformed mode preference handling is incorrect"
fi

"$HOST" --self-test --mode agent --preference-root "$MODE_ROOT" > "$RESULTS/role-agent.json"
if jq -e '.windowTitle=="Floe Agent" and .expectedTitle=="Floe Agent" and .windowVisible==true and .iconLoaded==true and .applicationIconSet==true' "$RESULTS/role-agent.json" >/dev/null; then
  pass "Agent role window title and application icon are applied at runtime"
else
  fail "Agent role presentation is incomplete"
fi

"$HOST" --self-test --mode bridge --preference-root "$MODE_ROOT" > "$RESULTS/role-bridge.json"
if jq -e '.windowTitle=="Floe Bridge" and .expectedTitle=="Floe Bridge" and .windowVisible==true and .iconLoaded==true and .applicationIconSet==true' "$RESULTS/role-bridge.json" >/dev/null; then
  pass "Bridge role window title and application icon are applied at runtime"
else
  fail "Bridge role presentation is incomplete"
fi

"$HOST" --print-auto-approval > "$RESULTS/auto-approval.json"
if jq -e '
  .owner=="Floe" and .agentCore=="Floe" and .integrated==false and
  .status=="reserved" and .configuredInM00==false and .bridgeUsesPolicy==false and
  (.scopeOptions|index("currentTask")) != null and (.riskClasses|index("irreversible")) != null
' "$RESULTS/auto-approval.json" >/dev/null; then
  pass "auto-approval seam is Floe-owned and reserved in M00, independent of Bridge"
else
  fail "auto-approval integration seam record is incorrect"
  jq . "$RESULTS/auto-approval.json" >&2 || true
fi

# The helper's own signed process checks Keychain readability, code-signing
# identity and current system permissions. Access being unavailable is a real
# result, not a pass/fail assumption.
"$HOST" --probe-identity --bridge-service "$BRIDGE_HELPER" > "$RESULTS/identity-probe.json" 2>&1 || true
if jq -e '
  .passed==true and .exitStatus==0 and
  .report.keychainService=="org.floeagent.bridge.server" and
  .report.keychainItemStatus!=null and
  .report.signingIdentifier!=null and
  .report.screenCaptureAllowed!=null and
  .report.accessibilityAllowed!=null and
  .userBridgeStateUnchanged==true
' "$RESULTS/identity-probe.json" >/dev/null; then
  pass "helper reports real Keychain access, signing identity and current screen/accessibility permission state"
  jq '{keychainItemStatus:.report.keychainItemStatus,keychainAccessible:.report.keychainAccessible,keychainOSStatus:.report.keychainOSStatus,signingAdHoc:.report.signingAdHoc,screenCaptureAllowed:.report.screenCaptureAllowed,accessibilityAllowed:.report.accessibilityAllowed}' "$RESULTS/identity-probe.json" >> "$RESULTS/identity-summary.json" 2>/dev/null || true
else
  fail "helper identity/permission probe failed"
  jq . "$RESULTS/identity-probe.json" >&2 || true
fi

# A pre-existing listener must be inspected, never replaced, bound over or
# signaled. Use a disposable nc listener as the foreign owner.
/usr/bin/nc -k -l 127.0.0.1 "$PORT" > "$RESULTS/dummy-listener.log" 2>&1 &
DUMMY_PID=$!
LISTENER_READY=0
for _ in $(seq 1 50); do
  if port_listeners | grep -q "127.0.0.1:$PORT"; then LISTENER_READY=1; break; fi
  sleep 0.1
done
if (( LISTENER_READY == 1 )); then
  "$HOST" --probe-conflict > "$RESULTS/conflict-probe.json" 2>&1 || true
  if jq -e '.passed==true and .listening==true and .stillListeningAfterInspection==true' "$RESULTS/conflict-probe.json" >/dev/null \
     && kill -0 "$DUMMY_PID" 2>/dev/null; then
    pass "an existing 43871 listener is inspected read-only and left running"
  else
    fail "conflict inspection did not leave the existing listener untouched"
    jq . "$RESULTS/conflict-probe.json" >&2 || true
  fi
else
  fail "could not start the disposable conflict listener"
fi
kill -TERM "$DUMMY_PID" 2>/dev/null || true
wait "$DUMMY_PID" 2>/dev/null || true

BRIDGE_ROOT="$SANDBOX/bridge-probe"
"$HOST" --probe-bridge --preference-root "$MODE_ROOT" --data-root "$BRIDGE_ROOT" > "$RESULTS/bridge-probe.json" 2>&1 || true
if jq -e '
  .passed==true and
  .enteredFrom=="agent" and
  .signedPingOK==true and
  .sameServicePIDAcrossEntries==true and
  .helperParentMatches==true and
  .originAfterAgentStart=="agent" and
  .originAfterBridgeEntry=="agent" and
  .originAfterAgentEntry=="agent" and
  .httpRejectedNonRPC==true and
  .listenerScope=="127.0.0.1" and
  .identitySource=="test-fixture-persistent" and
  .pinnedIdentity==identityFingerprint and
  .identityFingerprint!="none" and
  .workerHomeSeparateFromServiceStorage==true and
  .taskActiveDuringRun==true and
  .stopBlockedDuringRun==true and
  .helperAliveDuringRun==true and
  .taskCompleted==true and
  .taskError=="none" and
  (.taskOutput|contains("DONE")) and
  .taskUsesWorkerHome==true and
  .taskUsesServiceRoot==true and
  .fileReadOK==true and
  .consentPassed==true and
  .consentFlow.pairedAfterApproval==true and
  .consentFlow.listedAfterApproval==true and
  .consentFlow.removedAfterRevoke==true and
  .consentFlow.declinedAfterReject==true and
  .consentFlow.declineNotListed==true and
  (.activeTasksAfterTask|length)==0 and
  (.unknownTasksAfterTask|length)==0 and
  .rapidCycles==2 and
  .rapidFinalIdle==true and
  .rapidFailure=="none" and
  .portClosedAfterStop==true and
  .helperProcessesAfterStop==0 and
  .servicePIDAliveAfterStop==false and
  .isolatedFromUserBridge==true and
  .userBridgeStateUnchanged==true and
  .helperInsideHostBundle==true
' "$RESULTS/bridge-probe.json" >/dev/null; then
  pass "shared Bridge: authenticated fixture identity, real PTY task, live stop refusal, pinned RPC, clean generations"
else
  fail "Bridge shared-service/lifecycle probe failed"
  jq . "$RESULTS/bridge-probe.json" >&2 || true
fi

# Independent Bridge initialization: no mode host, no Agent core and no model.
STANDALONE_FIXTURE="$SANDBOX/standalone-fixture"
mkdir -p "$STANDALONE_FIXTURE/Control" "$STANDALONE_FIXTURE/service-home" "$STANDALONE_FIXTURE/worker-home"
chmod 700 "$STANDALONE_FIXTURE" "$STANDALONE_FIXTURE/Control" "$STANDALONE_FIXTURE/service-home" "$STANDALONE_FIXTURE/worker-home"
STANDALONE_READY="$STANDALONE_FIXTURE/Control/ready.json"
CFFIXED_USER_HOME="$STANDALONE_FIXTURE/worker-home" HOME="$STANDALONE_FIXTURE/worker-home" \
  "$BRIDGE_HELPER" --mode test --test-fixture "$STANDALONE_FIXTURE" \
  --control-socket "$STANDALONE_FIXTURE/Control/b.sock" \
  --ready-file "$STANDALONE_READY" \
  --discovery-file "$STANDALONE_FIXTURE/Control/discovery.json" \
  --orphan-idle-grace 2 > "$SANDBOX/standalone.log" 2>&1 &
STANDALONE_PID=$!
for _ in $(seq 1 100); do
  [[ -f "$STANDALONE_READY" ]] && break
  if ! kill -0 "$STANDALONE_PID" 2>/dev/null; then break; fi
  sleep 0.1
done
if [[ -f "$STANDALONE_READY" ]] && jq -e '.state=="ready" and .listenerScope=="127.0.0.1" and .identitySource=="test-fixture-persistent"' "$STANDALONE_READY" >/dev/null; then
  if port_listeners | grep -q "127.0.0.1:$PORT"; then
    pass "embedded Bridge initializes and listens without the mode host or Agent core"
  else
    fail "standalone Bridge ready file exists but no loopback listener is visible"
  fi
else
  fail "standalone Bridge did not initialize independently"
  cat "$STANDALONE_READY" >&2 2>/dev/null || true
  cat "$SANDBOX/standalone.log" >&2 || true
fi
kill -TERM "$STANDALONE_PID" 2>/dev/null || true
for _ in $(seq 1 60); do
  if ! kill -0 "$STANDALONE_PID" 2>/dev/null; then break; fi
  sleep 0.1
done
kill -KILL "$STANDALONE_PID" 2>/dev/null || true
wait "$STANDALONE_PID" 2>/dev/null || true
if [[ -z "$(port_listeners)" ]] && [[ -z "$(bridge_processes)" ]]; then
  pass "standalone Bridge terminated and released the loopback port"
else
  fail "standalone Bridge left a listener or process behind"
fi

# Crash/restart recovery: a killed test helper leaves an owner record without
# a result; the next service must report it as unconfirmed and preserve it.
"$HOST" --probe-recovery --data-root "$SANDBOX/recovery-probe" --bridge-service "$BRIDGE_HELPER" > "$RESULTS/recovery-probe.json" 2>&1 || true
if jq -e '
  .passed==true and
  .activeBeforeCrash==true and
  (.unknownTaskIDs|length)>0 and
  (.jobID as $j | .unknownTaskIDs | index($j))!=null and
  .ownerRecordPreserved==true and
  .resultRecordPresent==false and
  .taskDirectoryPreservedAfterStop==true and
  (.activeAfterRecovery|length)==0 and
  .portClosedAfterStop==true and
  .userBridgeStateUnchanged==true
' "$RESULTS/recovery-probe.json" >/dev/null; then
  pass "killed test service leaves an unconfirmed task; restart reports and preserves it without rerunning"
else
  fail "Bridge recovery probe failed"
  jq . "$RESULTS/recovery-probe.json" >&2 || true
fi

# Host death with active work. This is a test fixture and never touches the
# user's Bridge data or Keychain.
/usr/bin/python3 "$ROOT/scripts/probe_m00_lifecycle.py" \
  --helper "$BRIDGE_HELPER" --root "$SANDBOX/orphan-probe" \
  > "$RESULTS/orphan-probe.json" 2>&1 || true
if jq -e '
  .passed==true and
  .activeBeforeParentDeath==true and
  .survivedParentDeath==true and
  .taskCompletedAfterParentDeath==true and
  .resultRecordPresent==true and
  .ownerRecordPresent==true and
  .taskDirectoryPreserved==true and
  .orphanMarkerPresent==true and
  .helperExitedAfterIdleGrace==true and
  .idleHelperExitedAfterParentDeath==true
' "$RESULTS/orphan-probe.json" >/dev/null; then
  pass "helper survives host death while a task is active, persists the result, then exits after idle grace"
else
  fail "host-death lifecycle probe failed"
  jq . "$RESULTS/orphan-probe.json" >&2 || true
fi

# Production is attempted only when the existing identity is readable, no
# listener exists and the real data has no unconfirmed task. A skip is explicit
# and leaves all real data untouched.
"$HOST" --probe-production --bridge-service "$BRIDGE_HELPER" > "$RESULTS/production-probe.json" 2>&1 || true
if jq -e '
  .passed==true and
  ((.skipped==true and (.reason|length)>0) or
   (.skipped==false and .started==true and (.identitySource|startswith("keychain:"))))
' "$RESULTS/production-probe.json" >/dev/null; then
  pass "production path either reuses the real Keychain identity/data read-only or records the signed-identity limit explicitly"
else
  fail "production identity/data probe was neither a clean reuse nor an explicit skip"
  jq . "$RESULTS/production-probe.json" >&2 || true
fi
if [[ -n "$(port_listeners)" ]] || [[ -n "$(bridge_processes)" ]]; then
  fail "production probe left a listener or helper process behind"
else
  pass "production probe left no listener or helper process behind"
fi

CATALYST_ROOT="$SANDBOX/catalyst-probe"
"$HOST" --probe-catalyst --data-root "$CATALYST_ROOT" > "$RESULTS/catalyst-probe.json"
if jq -e '
  .passed==true and
  .launched==true and
  .terminated==true and
  .singleDockEntry==true and
  .appInsideHostBundle==true and
  .marker.catalyst==true and
  .marker.floeTheme==true and
  .marker.errorEventView==true
' "$RESULTS/catalyst-probe.json" >/dev/null; then
  pass "nested Mac Catalyst UI renders reused FloeTheme/ErrorEventView and does not add a regular Dock entry"
else
  fail "Catalyst source-reuse launch probe failed"
  jq . "$RESULTS/catalyst-probe.json" >&2 || true
fi

GUI_BRIDGE_FIXTURE="$SANDBOX/gui-bridge-fixture"
GUI_BRIDGE_MODE_ROOT="$SANDBOX/gui-bridge-mode"
open -n -W "$APP" --args \
  --mode bridge \
  --preference-root "$GUI_BRIDGE_MODE_ROOT" \
  --test-bridge-fixture "$GUI_BRIDGE_FIXTURE" \
  --smoke-exit-after 3 \
  --smoke-result "$SANDBOX/gui-bridge.json" || true
for _ in $(seq 1 50); do
  if [[ -z "$(port_listeners)" ]] && [[ -z "$(bridge_processes)" ]]; then break; fi
  sleep 0.1
done
if [[ -f "$SANDBOX/gui-bridge.json" ]] && jq -e '
  .mode=="bridge" and .roleTitle=="Floe Bridge" and .windowVisible==true and
  .bridgeState=="ready" and .bridgePID>0 and .bridgeOrigin=="bridge" and
  .bridgeActiveTasks==0 and .bridgeUnknownTasks==0 and
  .bridgeIdentitySource=="test-fixture-persistent" and
  .bridgeControlConnected==true
' "$SANDBOX/gui-bridge.json" >/dev/null; then
  pass "one packaged app launches in Bridge mode with the authenticated fixture service and live status"
else
  fail "packaged Bridge-mode smoke result is missing or incorrect"
  cat "$SANDBOX/gui-bridge.json" >&2 2>/dev/null || true
fi
if [[ -z "$(port_listeners)" ]] && [[ -z "$(bridge_processes)" ]] && [[ -z "$(host_processes)" ]]; then
  pass "Bridge-mode app quit stopped its own service and left no process"
else
  fail "Bridge-mode app left a service, host or listener behind"
fi

GUI_AGENT_MODE_ROOT="$SANDBOX/gui-agent-mode"
open -n -W "$APP" --args \
  --mode agent \
  --preference-root "$GUI_AGENT_MODE_ROOT" \
  --data-root "$SANDBOX/gui-agent-runtime" \
  --smoke-exit-after 2 \
  --smoke-result "$SANDBOX/gui-agent.json" || true
if [[ -f "$SANDBOX/gui-agent.json" ]] && jq -e '
  .mode=="agent" and .roleTitle=="Floe Agent" and .windowVisible==true and
  .bridgeState=="idle" and .bridgePID==0 and .bridgeOrigin=="none"
' "$SANDBOX/gui-agent.json" >/dev/null; then
  pass "one packaged app launches in Agent mode without initializing Bridge or the Agent core"
else
  fail "packaged Agent-mode smoke result is missing or incorrect"
  cat "$SANDBOX/gui-agent.json" >&2 2>/dev/null || true
fi

# Agent-mode GUI interaction (Start Bridge from the shared card, mode switch,
# explicit Stop) is intentionally left to the primary owner's computer-control
# acceptance. The CLI probe above starts from the Agent entry and proves the
# same controller/PID and signed RPC; this script does not drive System Events.

AFTER_USER_BRIDGE="$(snapshot_user_bridge)"
if [[ "$BEFORE_USER_BRIDGE" == "$AFTER_USER_BRIDGE" ]]; then
  pass "user's standalone Bridge state was not modified"
else
  fail "user's standalone Bridge state changed during verification"
fi
if [[ -z "$(port_listeners)" ]] && [[ -z "$(bridge_processes)" ]] && [[ -z "$(host_processes)" ]]; then
  pass "final check: no task-owned Bridge, host process or listener remains"
else
  fail "final check found a leftover process or listener"
fi

# Remove only app-domain artifacts created by this run. Pre-existing artifacts
# are preserved and reported.
declare -a CREATED_ARTIFACTS=()
for path in "${ARTIFACT_GLOBS[@]}"; do
  if [[ -e "$path" ]]; then
    is_preexisting=0
    for prior in "${PREEXISTING_ARTIFACTS[@]}"; do
      if [[ "$prior" == "$path" ]]; then is_preexisting=1; break; fi
    done
    if (( is_preexisting == 0 )); then
      CREATED_ARTIFACTS+=("$path")
      rm -rf "$path"
    fi
  fi
done
if (( ${#CREATED_ARTIFACTS[@]} == 0 )); then
  pass "verification created no persistent app-domain artifacts"
else
  pass "verification-created app-domain artifacts were removed (${#CREATED_ARTIFACTS[@]} path(s))"
fi

python3 - "$RESULTS/summary.json" "$CHECKS" "$FAILURES" "$SANDBOX" "$APP" "$BEFORE_USER_BRIDGE" "$AFTER_USER_BRIDGE" "$RESULTS/checks.txt" <<'PY'
import json, os, sys
output, checks, failures, sandbox, app, before, after, checks_file = sys.argv[1:]
rows = []
try:
    with open(checks_file) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            status, _, name = line.partition("|")
            rows.append({"status": status, "check": name})
except FileNotFoundError:
    pass
payload = {
    "schema": "floe-mac-m00-verify-v1",
    "checks": int(checks),
    "failures": int(failures),
    "passed": int(failures) == 0,
    "sandbox": sandbox,
    "app": app,
    "user_bridge_before": before,
    "user_bridge_after": after,
    "rows": rows,
}
for name in ["identity-probe.json", "production-probe.json", "orphan-probe.json", "recovery-probe.json"]:
    path = os.path.join(os.path.dirname(output), name)
    if os.path.exists(path):
        try:
            payload[name[:-5].replace("-", "_")] = json.load(open(path))
        except Exception:
            payload[name[:-5].replace("-", "_")] = {"unreadable": True}
open(output, "w").write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY

echo
echo "Verification result: $((CHECKS - FAILURES))/$CHECKS checks passed"
echo "Evidence: $RESULTS"
if (( FAILURES > 0 )); then
  echo "FAILED: $FAILURES check(s) failed." >&2
  exit 1
fi
echo "PASS: all M00 checks passed."
