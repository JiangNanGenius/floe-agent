#!/bin/sh
# guest-stage2-verify.sh — second image-build boot, executed INSIDE the Debian
# 13 guest through the Floe runner as one FLOE-EXEC frame.
#
# This is the capability check of the *final* image bytes (stage 1 has already
# installed the packages into the same disk file):
#   - the runner set the wall clock from a fresh `floe.epoch=` bootstrap value;
#   - signed HTTPS APT still works with that clock (no date workaround);
#   - Python's default CA verification gets HTTP 200 over HTTPS;
#   - the 13 commands from the user feedback report really run: ps setsid
#     nohup bash zsh zip unzip 7z xz bzip2 sqlite3 ssh scp;
#   - when the host placed /floe/template-recipe.json, every apt requirement
#     is re-checked against the live dpkg database (with dpkg's own version
#     comparison) and every pinned PyPI wheel is re-imported at its pinned
#     version — independently of /floe/template-install.json;
#   - the FENCE/instruction probe that the APT SIGILL investigation needed is
#     re-run with the fixed harness (diagnostic evidence, not a product gate);
#   - package versions of everything used are recorded for the source mapping.
#
# Markers are assembled at runtime by printf, so the literal marker string is
# never present in any line the console could echo back.
# POSIX sh only (Debian /bin/sh is dash).
set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND
TERM=dumb
export TERM

LOG=/floe/stage2-verify.log
REPORT=/floe/image-capability-report.txt
: >"$LOG"
: >"$REPORT"
failures=0

note() {
    printf '%s\n' "$*" >>"$LOG"
    printf '%s\n' "$*" >>"$REPORT"
    printf '%s\n' "$*"
}
mark() {
    printf 'FLOE_STAGE2_%s\n' "$1"
}
cmd_result() {
    # cmd_result <command> <OK|FAIL> <detail>
    printf '%s %s %s\n' "$1" "$2" "${3:-}" >>"$REPORT"
    printf 'FLOE_CMD_%s_%s\n' "$1" "$2"
    [ "$2" = "OK" ] || failures=$((failures + 1))
}

note "stage2 start utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "kernel cmdline: $(cat /proc/cmdline 2>/dev/null)"

# 1. Clock -------------------------------------------------------------------
host_epoch="$(cat /floe/host-epoch.txt 2>/dev/null || true)"
now="$(date +%s)"
if [ -z "$host_epoch" ]; then
    mark CLOCK_NO_HOST_EPOCH
    note "clock: no /floe/host-epoch.txt from the host"
    failures=$((failures + 1))
elif [ "$now" -lt 1000000000 ] 2>/dev/null; then
    mark CLOCK_EPOCH_NOT_SET
    note "clock: guest epoch $now is still 1970 (runner did not consume floe.epoch=)"
    failures=$((failures + 1))
else
    delta=$((now - host_epoch))
    [ "$delta" -lt 0 ] && delta=$((0 - delta))
    note "clock: guest=$now host=$host_epoch delta=${delta}s utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$delta" -le 120 ]; then
        mark CLOCK_OK
    else
        mark CLOCK_BAD
        failures=$((failures + 1))
    fi
fi

# 2. slirp network -----------------------------------------------------------
ip link set eth0 up >>"$LOG" 2>&1 || true
ip addr add 10.0.2.15/24 dev eth0 >>"$LOG" 2>&1 || true
ip route add default via 10.0.2.2 >>"$LOG" 2>&1 || true
rm -f /etc/resolv.conf
printf 'nameserver 10.0.2.3\n' >/etc/resolv.conf
if ping -c1 -W3 10.0.2.2 >>"$LOG" 2>&1; then
    mark PING_OK
else
    mark PING_FAIL
fi

# 3. Signed HTTPS APT on the final image -------------------------------------
apt-get update >>"$LOG" 2>&1
update_rc=$?
note "stage2 apt-get update rc=$update_rc"
if [ "$update_rc" = "0" ]; then
    mark APT_UPDATE_RC_0
else
    mark "APT_UPDATE_RC_$update_rc"
fi

# 4. Python HTTPS with default certificate verification ----------------------
python3 /floe/guest-https-check.py >/floe/stage2-https.out 2>&1
https_rc=$?
cat /floe/stage2-https.out >>"$REPORT"
cat /floe/stage2-https.out
if [ "$https_rc" = "0" ] && grep -q 'FLOE_STAGE2_PY_HTTPS_200' /floe/stage2-https.out 2>/dev/null; then
    mark PY_HTTPS_RC_0
else
    mark PY_HTTPS_RC_$https_rc
fi

# 5. The 13 user-facing commands ---------------------------------------------
# ps
ps_line="$(ps -o pid=,comm= -p 1 2>/dev/null | sed 's/^ *//')"
case "$ps_line" in
    1\ floe-exec*) cmd_result ps OK "pid1=$ps_line" ;;
    *) cmd_result ps FAIL "ps -p 1 returned '$ps_line'" ;;
esac

# setsid (a new session, exit status propagated with --wait)
setsid --wait sh -c 'exit 7' >/dev/null 2>&1
setsid_rc=$?
if [ "$setsid_rc" = "7" ]; then
    cmd_result setsid OK "setsid --wait propagated exit 7"
else
    setsid sh -c 'exit 7' >/dev/null 2>&1
    setsid_rc2=$?
    if [ "$setsid_rc2" = "0" ] || [ "$setsid_rc2" = "7" ]; then
        cmd_result setsid OK "setsid ran (exit $setsid_rc2; --wait unsupported)"
    else
        cmd_result setsid FAIL "setsid rc=$setsid_rc / $setsid_rc2"
    fi
fi

# nohup
nohup sh -c 'exit 5' >/dev/null 2>&1
nohup_rc=$?
if [ "$nohup_rc" = "5" ]; then
    cmd_result nohup OK "nohup propagated exit 5"
else
    cmd_result nohup FAIL "nohup rc=$nohup_rc"
fi

# bash
bash -c 'exit $((6*7))'
bash_rc=$?
if [ "$bash_rc" = "42" ]; then
    cmd_result bash OK "bash exit 42"
else
    cmd_result bash FAIL "bash rc=$bash_rc"
fi

# zsh
zsh -c 'exit $((7*7))'
zsh_rc=$?
if [ "$zsh_rc" = "49" ]; then
    cmd_result zsh OK "zsh exit 49"
else
    cmd_result zsh FAIL "zsh rc=$zsh_rc"
fi

# zip + unzip round trip
rm -rf /tmp/floe-zip
mkdir -p /tmp/floe-zip
printf 'floe-zip-payload\n' >/tmp/floe-zip/src.txt
(cd /tmp/floe-zip && zip -q floe-check.zip src.txt) >/dev/null 2>&1
zip_rc=$?
(cd /tmp/floe-zip && unzip -q -o floe-check.zip -d out) >/dev/null 2>&1
unzip_rc=$?
zip_content="$(cat /tmp/floe-zip/out/src.txt 2>/dev/null || true)"
if [ "$zip_rc" = "0" ] && [ "$zip_content" = "floe-zip-payload" ]; then
    cmd_result zip OK "archive created (rc=$zip_rc)"
else
    cmd_result zip FAIL "zip rc=$zip_rc"
fi
if [ "$unzip_rc" = "0" ] && [ "$zip_content" = "floe-zip-payload" ]; then
    cmd_result unzip OK "archive extracted byte-identical (rc=$unzip_rc)"
else
    cmd_result unzip FAIL "unzip rc=$unzip_rc content='$zip_content'"
fi

# 7z round trip
rm -rf /tmp/floe-7z
mkdir -p /tmp/floe-7z
printf 'floe-7z-payload\n' >/tmp/floe-7z/src.txt
(cd /tmp/floe-7z && 7z a -bd -y arch.7z src.txt) >/dev/null 2>&1
seven_rc=$?
(cd /tmp/floe-7z && 7z x -bd -y -oout arch.7z) >/dev/null 2>&1
seven_x_rc=$?
seven_content="$(cat /tmp/floe-7z/out/src.txt 2>/dev/null || true)"
if [ "$seven_rc" = "0" ] && [ "$seven_x_rc" = "0" ] && [ "$seven_content" = "floe-7z-payload" ]; then
    cmd_result 7z OK "archive create+extract byte-identical"
else
    cmd_result 7z FAIL "7z rc=$seven_rc/$seven_x_rc content='$seven_content'"
fi

# xz round trip
printf 'floe-xz-payload\n' >/tmp/floe-xz.txt
xz -c /tmp/floe-xz.txt >/tmp/floe-xz.txt.xz 2>/dev/null
xz_rc=$?
xz -dc /tmp/floe-xz.txt.xz >/tmp/floe-xz.out 2>/dev/null
xz_dc_rc=$?
if [ "$xz_rc" = "0" ] && [ "$xz_dc_rc" = "0" ] && [ "$(cat /tmp/floe-xz.out 2>/dev/null)" = "floe-xz-payload" ]; then
    cmd_result xz OK "compress+decompress byte-identical"
else
    cmd_result xz FAIL "xz rc=$xz_rc/$xz_dc_rc"
fi

# bzip2 round trip
printf 'floe-bzip2-payload\n' >/tmp/floe-bz.txt
bzip2 -c /tmp/floe-bz.txt >/tmp/floe-bz.txt.bz2 2>/dev/null
bz_rc=$?
bzip2 -dc /tmp/floe-bz.txt.bz2 >/tmp/floe-bz.out 2>/dev/null
bz_dc_rc=$?
if [ "$bz_rc" = "0" ] && [ "$bz_dc_rc" = "0" ] && [ "$(cat /tmp/floe-bz.out 2>/dev/null)" = "floe-bzip2-payload" ]; then
    cmd_result bzip2 OK "compress+decompress byte-identical"
else
    cmd_result bzip2 FAIL "bzip2 rc=$bz_rc/$bz_dc_rc"
fi

# sqlite3
rm -f /tmp/floe.db
sqlite_out="$(sqlite3 /tmp/floe.db 'CREATE TABLE t(v); INSERT INTO t VALUES(42); SELECT v FROM t;' 2>/dev/null)"
if [ "$sqlite_out" = "42" ]; then
    cmd_result sqlite3 OK "create/insert/select returned 42"
else
    cmd_result sqlite3 FAIL "sqlite3 output='$sqlite_out'"
fi

# ssh: presence/version only. No remote host exists in this build, so no
# connection is made and none is claimed.
ssh_version="$(ssh -V 2>&1)"
case "$ssh_version" in
    OpenSSH*) cmd_result ssh OK "client version only, no connection made: $ssh_version" ;;
    *) cmd_result ssh FAIL "ssh -V output='$ssh_version'" ;;
esac

# scp: OpenSSH scp has no -V, so the client is exercised with a negative
# attempt against localhost:1. There is deliberately no sshd in this image,
# so this proves the client stack starts and fails as a client; it is NOT a
# transfer success and the docs say so. The full output is kept so nothing is
# inferred from a single line.
scp_out="$(scp -o BatchMode=yes -o ConnectTimeout=2 -P 1 /etc/hostname localhost:/tmp/floe-scp-probe 2>&1)"
scp_rc=$?
scp_detail="$(printf '%s' "$scp_out" | tr '\n' ' ' | cut -c1-240)"
case "$scp_out" in
    *"Connection refused"*|*"Connection timed out"*|*"Address family not supported"*|*"ssh: connect"*)
        cmd_result scp OK "client-only negative attempt, no transfer (rc=$scp_rc): $scp_detail" ;;
    *) cmd_result scp FAIL "scp rc=$scp_rc output='$scp_detail'" ;;
esac

# 6b. Runtime-template verification -------------------------------------------
# Independently re-read the live dpkg database (never template-install.json)
# and re-run every recipe requirement with dpkg's own version comparison, plus
# a real import of every pinned PyPI wheel. Template failures are reported as
# markers/JSON but do not abort this stage: the remaining checks still run and
# the host gate decides whether the image may ship.
if [ -f /floe/template-recipe.json ]; then
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n' \
        >/floe/template-dpkg-live.tsv 2>>"$LOG" || true
    template_rc=0
    python3 - /floe /floe/template-recipe.json <<'FLOE_TEMPLATE_VERIFY_PY' || template_rc=$?
import datetime
import importlib
import importlib.metadata
import json
import os
import subprocess
import sys

share = sys.argv[1]
recipe_path = sys.argv[2]
checked_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_payload(payload):
    with open(os.path.join(share, "template-verify.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


try:
    with open(recipe_path, "r", encoding="utf-8") as handle:
        recipe = json.load(handle)
except Exception as exc:  # noqa: BLE001 - report, never crash without evidence
    stem = os.path.splitext(os.path.basename(recipe_path))[0]
    write_payload({
        "schema": 1,
        "template": stem,
        "verified": False,
        "missing": [],
        "below_minimum": [],
        "pypi_failures": [],
        "checked_at_utc": checked_at,
        "reason": "recipe unreadable at verification time: %s" % exc,
    })
    print("FLOE_TEMPLATE_UNVERIFIED 1")
    print("FLOE_TEMPLATE_FAIL %s recipe unreadable at verification time: %s" % (stem, exc))
    sys.exit(0)

template_name = recipe.get("name") or os.path.splitext(os.path.basename(recipe_path))[0]
packages = recipe.get("packages") or {}
pypi = recipe.get("pypi") or {}


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return [line.rstrip("\n") for line in handle if line.strip()]
    except OSError:
        return []


live = {}
for line in read_lines(os.path.join(share, "template-dpkg-live.tsv")):
    parts = line.split("\t")
    if len(parts) >= 2:
        live[parts[0].split(":")[0]] = parts[1]

missing = []
below_minimum = []
for name in sorted(packages):
    requirement = packages[name] or {}
    have = live.get(name)
    if not have:
        missing.append(name)
        continue
    minimum = requirement.get("min_version") if isinstance(requirement, dict) else None
    if not minimum:
        continue
    try:
        compare = subprocess.run(["dpkg", "--compare-versions", have, "ge", minimum],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        satisfied = compare.returncode == 0
    except OSError:
        satisfied = False
    if not satisfied:
        below_minimum.append({"name": name, "have": have, "minimum": minimum})

pypi_failures = []
for distribution in sorted(pypi):
    entry = pypi[distribution] or {}
    version = str(entry.get("version", ""))
    module = entry.get("import") or distribution.replace("-", "_")
    try:
        imported = importlib.import_module(module)
    except Exception as exc:  # noqa: BLE001 - any import failure is a failure
        pypi_failures.append({"name": distribution,
                              "detail": "import %s failed: %s" % (module, exc)})
        continue
    observed = getattr(imported, "__version__", None)
    where = "module __version__"
    if observed is None:
        try:
            observed = importlib.metadata.version(distribution)
            where = "distribution metadata"
        except Exception:
            observed = None
    if observed is None:
        pypi_failures.append({
            "name": distribution,
            "detail": "imported but no observable version (cannot verify pinned %s)" % version})
        continue
    observed = str(observed).strip()
    if observed != version:
        pypi_failures.append({
            "name": distribution,
            "detail": "version mismatch: observed %s, pinned %s (%s)" % (observed, version, where)})

verified = not (missing or below_minimum or pypi_failures)
write_payload({
    "schema": 1,
    "template": template_name,
    "verified": verified,
    "missing": missing,
    "below_minimum": below_minimum,
    "pypi_failures": pypi_failures,
    "checked_at_utc": checked_at,
})

if verified:
    print("FLOE_TEMPLATE_VERIFIED %s" % template_name)
else:
    print("FLOE_TEMPLATE_UNVERIFIED %d" % (len(missing) + len(below_minimum) + len(pypi_failures)))
    for name in missing:
        print("FLOE_TEMPLATE_FAIL %s not installed in the live dpkg database" % name)
    for entry in below_minimum:
        print("FLOE_TEMPLATE_FAIL %s below minimum (have %s, need %s)"
              % (entry["name"], entry["have"], entry["minimum"]))
    for entry in pypi_failures:
        print("FLOE_TEMPLATE_FAIL %s %s" % (entry["name"], entry["detail"]))
sys.exit(0)
FLOE_TEMPLATE_VERIFY_PY
    note "template verification rc=$template_rc"
else
    note "no /floe/template-recipe.json on the share; template verification skipped"
fi

# 6. FENCE / instruction probe (diagnostic; harness fixed in 0bf0ffb4) -------
if [ -f /floe/guest-instruction-probe.py ]; then
    python3 /floe/guest-instruction-probe.py >/floe/stage2-insns.out 2>&1
    insn_rc=$?
    cat /floe/stage2-insns.out >>"$REPORT"
    cat /floe/stage2-insns.out
    note "instruction probe rc=$insn_rc lines=$(wc -l </floe/stage2-insns.out 2>/dev/null || echo 0)"
else
    note "instruction probe missing from the share"
fi

# 7. Package versions used by the checks -------------------------------------
dpkg-query -W -f='${binary:Package}\t${Version}\n' procps util-linux coreutils bash zsh \
    zip unzip p7zip-full xz-utils bzip2 sqlite3 openssh-client python3 nodejs npm \
    >/floe/stage2-package-versions.txt 2>/dev/null || true
note "stage2 package versions: $(wc -l </floe/stage2-package-versions.txt 2>/dev/null || echo 0) records"

sync
if [ "$failures" != "0" ]; then
    note "stage2 done with $failures failing check(s)"
    mark FAILED
    exit 10
fi
note "stage2 done: all checks passed"
mark DONE
exit 0
