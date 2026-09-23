#!/bin/sh
# guest-stage1-coherence.sh — first image-build boot after HOST-accelerated
# provisioning (host-provision-image.sh), executed INSIDE the Debian 13 guest
# through the Floe runner as one FLOE-EXEC frame.
#
# The heavy apt/dpkg work ran on the cloud host through a qemu-user riscv64
# chroot against this exact disk; this boot proves the result is real from the
# guest's own perspective, with the real 2018 kernel/bbl + runner PID 1:
#   1. the runner set CLOCK_REALTIME from a fresh `floe.epoch=`;
#   2. the guest reaches the slirp network;
#   3. signed HTTPS apt still works on the provisioned image (apt-get update
#      with normal signature verification, no date workaround);
#   4. every recipe apt requirement is present in the LIVE dpkg database
#      (dpkg's own version comparison for min_version), and every pinned PyPI
#      wheel really imports at its pinned version from the guest interpreter.
#
# Nothing here re-installs anything: the install evidence is the host
# provision log + template-install.json; this boot is the in-Guest coherence
# gate. Markers use the FLOE_STAGE1_ namespace so the existing host gate keeps
# its meaning; the full verification of the final image stays in
# guest-stage2-verify.sh (boot B).
#
# POSIX sh only (Debian /bin/sh is dash).
set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

LOG=/floe/stage1-coherence.log
: >"$LOG"

note() {
    printf '%s\n' "$*" >>"$LOG"
    printf '%s\n' "$*"
}
mark() {
    printf 'FLOE_STAGE1_%s\n' "$1"
}

note "stage1(coherence) start utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "kernel cmdline: $(cat /proc/cmdline 2>/dev/null)"
note "provisioning: host qemu-user chroot (see host evidence/provision-*.txt)"

mkdir -p /var/tmp/floe-image-build
chmod 1777 /var/tmp/floe-image-build
TMPDIR=/var/tmp/floe-image-build
TMP=/var/tmp/floe-image-build
TEMP=/var/tmp/floe-image-build
export TMPDIR TMP TEMP

# 1. Clock -------------------------------------------------------------------
host_epoch="$(cat /floe/host-epoch.txt 2>/dev/null || true)"
now="$(date +%s)"
if [ -z "$host_epoch" ]; then
    mark CLOCK_NO_HOST_EPOCH
    note "clock: no /floe/host-epoch.txt from the host"
elif [ "$now" -lt 1000000000 ] 2>/dev/null; then
    mark CLOCK_EPOCH_NOT_SET
    note "clock: guest epoch $now is still 1970 (runner did not consume floe.epoch=)"
else
    delta=$((now - host_epoch))
    [ "$delta" -lt 0 ] && delta=$((0 - delta))
    note "clock: guest=$now host=$host_epoch delta=${delta}s"
    if [ "$delta" -le 300 ]; then
        mark CLOCK_OK
    else
        mark CLOCK_BAD
    fi
fi

# 2. slirp network -----------------------------------------------------------
ip link set eth0 up >>"$LOG" 2>&1 || note "ip link set eth0 up failed"
ip addr add 10.0.2.15/24 dev eth0 >>"$LOG" 2>&1 || true
ip route add default via 10.0.2.2 >>"$LOG" 2>&1 || true
if [ ! -s /etc/resolv.conf ]; then
    printf 'nameserver 10.0.2.3\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf
fi
if ping -c1 -W3 10.0.2.2 >>"$LOG" 2>&1; then
    mark PING_OK
else
    mark PING_FAIL
fi

# 3. Signed HTTPS apt update on the provisioned image -------------------------
apt-get update >>"$LOG" 2>&1
update_rc=$?
note "apt-get update rc=$update_rc (signed, default sources)"
if [ "$update_rc" = "0" ]; then
    mark APT_UPDATE_RC_0
else
    mark "APT_UPDATE_RC_$update_rc"
fi

# 4. Template coherence against the LIVE dpkg database + real imports ---------
template_rc=0
if [ -f /floe/template-recipe.json ]; then
    template_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' /floe/template-recipe.json 2>/dev/null || true)"
    [ -n "$template_name" ] && mark "TEMPLATE=$template_name"
    dpkg-query -W -f='${binary:Package}\t${Version}\n' >/floe/template-dpkg-live.tsv 2>>"$LOG" || true
    python3 - /floe /floe/template-recipe.json <<'FLOE_TEMPLATE_COHERENCE_PY' || template_rc=$?
import importlib
import importlib.metadata
import json
import os
import subprocess
import sys

share = sys.argv[1]
recipe_path = sys.argv[2]

with open(recipe_path, "r", encoding="utf-8") as handle:
    recipe = json.load(handle)
template_name = recipe.get("name") or "template"
packages = recipe.get("packages") or {}
pypi = recipe.get("pypi") or {}

live = {}
try:
    with open(os.path.join(share, "template-dpkg-live.tsv"), "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                live[parts[0].split(":")[0]] = parts[1]
except OSError:
    pass

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
    compare = subprocess.run(["dpkg", "--compare-versions", have, "ge", minimum],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if compare.returncode != 0:
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
        pypi_failures.append({"name": distribution,
                              "detail": "imported but no observable version (cannot verify pinned %s)" % version})
        continue
    observed = str(observed).strip()
    if observed != version:
        pypi_failures.append({"name": distribution,
                              "detail": "version mismatch: observed %s, pinned %s (%s)" % (observed, version, where)})
    else:
        print("FLOE_STAGE1_PYPI_OK %s=%s" % (distribution, observed))

problems = len(missing) + len(below_minimum) + len(pypi_failures)
with open(os.path.join(share, "template-coherence.json"), "w", encoding="utf-8") as handle:
    json.dump({
        "schema": 1,
        "template": template_name,
        "coherent": problems == 0,
        "missing": missing,
        "below_minimum": below_minimum,
        "pypi_failures": pypi_failures,
    }, handle, indent=2)
    handle.write("\n")

if problems == 0:
    print("FLOE_STAGE1_TEMPLATE_COHERENT %s" % template_name)
else:
    print("FLOE_STAGE1_TEMPLATE_INCOHERENT %d" % problems)
    for name in missing:
        print("FLOE_STAGE1_TEMPLATE_MISSING %s" % name)
    for entry in below_minimum:
        print("FLOE_STAGE1_TEMPLATE_BELOW_MINIMUM %s have=%s need=%s"
              % (entry["name"], entry["have"], entry["minimum"]))
    for entry in pypi_failures:
        print("FLOE_STAGE1_PYPI_FAILED %s %s" % (entry["name"], entry["detail"]))
sys.exit(1 if problems else 0)
FLOE_TEMPLATE_COHERENCE_PY
    note "template coherence rc=$template_rc"
else
    note "no /floe/template-recipe.json on the share; coherence check skipped"
    template_rc=1
fi

sync

if [ "$update_rc" != "0" ] || [ "$template_rc" != "0" ]; then
    note "stage1(coherence) FAILED (apt update rc=$update_rc coherence rc=$template_rc)"
    mark FAILED
    exit 9
fi
note "stage1(coherence) done"
mark DONE
exit 0
