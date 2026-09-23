#!/bin/sh
# guest-stage1-install.sh — first image-build boot, executed INSIDE the Debian
# 13 guest through the Floe runner as one FLOE-EXEC frame.
#
# What it proves / does (all output is framed by the runner, so a marker only
# appears when the guest really executed something):
#   1. the runner set CLOCK_REALTIME from the host-injected `floe.epoch=`
#      cmdline parameter (no `date -s` workaround anywhere in this flow);
#   2. the guest reaches the slirp network;
#   3. apt talks real HTTPS to the image's default sources with normal
#      signature verification (`apt-get update`);
#   4. it installs the packages the image ships: the selected runtime-template
#      recipe's `packages` (or the historical hardcoded list when the host
#      did not place /floe/template-recipe.json) plus the recipe's pinned
#      PyPI wheels, downloaded, sha256-verified, installed with
#      `pip --break-system-packages` and import-checked;
#   5. it exports the installed-package inventory used later to build the
#      corresponding-source mapping, and in template mode the real install
#      facts (`/floe/template-install.json`) for the image manifest.
#
# POSIX sh only (Debian /bin/sh is dash). Never exits non-zero after a
# partially-successful install without saying so: the host gate greps the
# FLOE_STAGE1_ markers and the final FLOE-END exit code.
set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

LOG=/floe/stage1-install.log
: >"$LOG"

note() {
    printf '%s\n' "$*" >>"$LOG"
    printf '%s\n' "$*"
}
mark() {
    printf 'FLOE_STAGE1_%s\n' "$1"
}

# ca-certificates is the CA store the host's shared Python/Node paths and the
# guest's own HTTPS checks rely on; it is normally part of the cloud image but
# is named explicitly so the image contract does not depend on that.
PACKAGES="procps util-linux coreutils bash zsh zip unzip p7zip-full xz-utils \
bzip2 sqlite3 openssh-client python3 python3-pip python3-venv python3-numpy \
nodejs npm ca-certificates"

# Runtime-template mode. When the host validated a recipe and copied it to
# the share, the apt list and the pinned PyPI wheels come from that recipe;
# with no recipe file the historical hardcoded list is used unchanged. The
# Python parsing/verification below is stdlib-only and runs on the base
# image's preinstalled python3 (the recipe's python3 requirement is only
# about the interpreter version, never about availability here).
TEMPLATE_RECIPE=/floe/template-recipe.json
template_mode=0
template_name=""
template_facts_rc=0

note "stage1 start utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "kernel cmdline: $(cat /proc/cmdline 2>/dev/null)"
note "runner: $(ls -l /usr/local/bin/floe-exec 2>/dev/null)"

# 1. Clock -------------------------------------------------------------------
# The runner read floe.epoch= from /proc/cmdline as PID 1 and set the clock
# before accepting this frame; the host wrote the same value to the share.
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
# floe-exec has already written the working resolver list on boot. Do not
# replace its public fallbacks with the slirp alias alone: the latter is not
# reachable on every cloud runner. Keep a fallback only for older runners.
if [ ! -s /etc/resolv.conf ]; then
    printf 'nameserver 10.0.2.3\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf
fi
if ping -c1 -W3 10.0.2.2 >>"$LOG" 2>&1; then
    mark PING_OK
else
    mark PING_FAIL
fi

# 2b. Runtime-template recipe -------------------------------------------------
# Re-read the recipe the host validated and turn it into the apt list and the
# PyPI wheel table. A recipe that cannot be parsed is a hard failure: silently
# falling back to the hardcoded list would build an image that does not match
# the recipe the manifest records.
if [ -f "$TEMPLATE_RECIPE" ]; then
    parse_rc=0
    python3 - /floe "$TEMPLATE_RECIPE" >>"$LOG" 2>&1 <<'FLOE_TEMPLATE_PARSE_PY' || parse_rc=$?
import json
import os
import re
import sys

share = sys.argv[1]
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    recipe = json.load(handle)
if not isinstance(recipe, dict) or recipe.get("schema") != 1:
    raise SystemExit("recipe is not a schema-1 object")
name = recipe.get("name")
packages = recipe.get("packages")
if (not isinstance(name, str) or not name.strip() or name != name.strip()
        or not isinstance(packages, dict) or not packages):
    raise SystemExit("recipe has no usable name or packages")
package_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
for package in packages:
    if not isinstance(package, str) or not package_re.match(package):
        raise SystemExit("invalid apt package name: %r" % (package,))
pypi = recipe.get("pypi") or {}
if not isinstance(pypi, dict):
    raise SystemExit("recipe pypi is not an object")
sha_re = re.compile(r"^[0-9a-f]{64}$")
module_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")
rows = []
for distribution in sorted(pypi):
    entry = pypi[distribution]
    if not isinstance(entry, dict):
        raise SystemExit("pypi entry %s is not an object" % distribution)
    version = entry.get("version")
    wheel = entry.get("wheel")
    url = entry.get("url")
    sha = entry.get("sha256")
    module = entry.get("import") or distribution.replace("-", "_")
    if (not isinstance(version, str) or not version.strip()
            or not isinstance(wheel, str) or not wheel
            or os.path.basename(wheel) != wheel or not wheel.endswith(".whl")
            or not isinstance(url, str) or not url.startswith("https://")
            or not isinstance(sha, str) or not sha_re.match(sha)
            or not isinstance(module, str) or not module_re.match(module)):
        raise SystemExit("pypi entry %s is not a valid pinned wheel" % distribution)
    rows.append("\t".join([distribution, version, wheel, url, sha, module]))
with open(os.path.join(share, "template-name.txt"), "w", encoding="utf-8") as handle:
    handle.write(name + "\n")
with open(os.path.join(share, "template-apt-list.txt"), "w", encoding="utf-8") as handle:
    handle.write("\n".join(sorted(packages)) + "\n")
with open(os.path.join(share, "template-pypi.tsv"), "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(row + "\n")
FLOE_TEMPLATE_PARSE_PY
    if [ "$parse_rc" != "0" ]; then
        note "template recipe unusable (parse rc=$parse_rc): refusing to install from a guess"
        mark TEMPLATE_RECIPE_INVALID
        mark FAILED
        exit 9
    fi
    template_mode=1
    template_name="$(cat /floe/template-name.txt 2>/dev/null || true)"
    if [ -z "$template_name" ] || [ ! -s /floe/template-apt-list.txt ]; then
        note "template recipe parsed but produced no name/package list"
        mark TEMPLATE_RECIPE_INVALID
        mark FAILED
        exit 9
    fi
    note "template '$template_name': $(wc -l </floe/template-apt-list.txt) apt requirement(s), $(wc -l </floe/template-pypi.tsv 2>/dev/null || echo 0) pypi entry(ies)"
    mark "TEMPLATE=$template_name"
fi

# 3. HTTPS apt update (default sources, normal signature verification) -------
apt-get update >>"$LOG" 2>&1
update_rc=$?
note "apt-get update rc=$update_rc"
if [ "$update_rc" = "0" ]; then
    mark APT_UPDATE_RC_0
else
    mark "APT_UPDATE_RC_$update_rc"
fi

# 4. Package install ---------------------------------------------------------
if [ "$template_mode" = "1" ]; then
    install_list="$(tr '\n' ' ' </floe/template-apt-list.txt)"
else
    install_list="$PACKAGES"
fi
# shellcheck disable=SC2086 # install_list is a deliberate word list
apt-get install -y --no-install-recommends $install_list >>"$LOG" 2>&1
install_rc=$?
note "apt-get install rc=$install_rc"
if [ "$install_rc" = "0" ]; then
    mark APT_INSTALL_RC_0
else
    mark "APT_INSTALL_RC_$install_rc"
fi

# 5. Inventory for the corresponding-source mapping --------------------------
dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n' \
    >/floe/guest-packages.tsv 2>/dev/null || true
package_lines="$(wc -l </floe/guest-packages.tsv 2>/dev/null || echo 0)"
note "package inventory: $package_lines records"

cp /var/lib/dpkg/status /floe/guest-dpkg-status.txt 2>/dev/null || true
cp /etc/apt/sources.list /floe/guest-apt-sources.list 2>/dev/null || true
if [ -d /etc/apt/sources.list.d ]; then
    mkdir -p /floe/guest-apt-sources.list.d
    cp -a /etc/apt/sources.list.d/. /floe/guest-apt-sources.list.d/ 2>/dev/null || true
fi

# 5b. Template install facts + pinned PyPI wheels -----------------------------
# Everything written to template-install.json is a real guest fact: dpkg's own
# answer for the apt list, the actual pip exit status, and a real import +
# version check for each wheel. No success is recorded for a skipped step.
if [ "$template_mode" = "1" ]; then
    printf '%s\n' "$install_rc" >/floe/template-install-rc.txt
    # shellcheck disable=SC2046 # package names contain no whitespace
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\t${source:Package}\t${Installed-Size}\n' \
        $(cat /floe/template-apt-list.txt) >/floe/template-apt-facts.tsv 2>>"$LOG" || true

    pip_state=none
    if [ -s /floe/template-pypi.tsv ]; then
        mkdir -p /floe/wheels
        : >/floe/template-pypi-prefail.tsv
        wheel_paths=""
        while IFS="$(printf '\t')" read -r p_name p_version p_wheel p_url p_sha p_module; do
            [ -n "$p_name" ] || continue
            dest="/floe/wheels/$p_wheel"
            note "pypi: downloading $p_name -> $dest"
            if ! curl -L --fail --retry 3 -o "$dest" "$p_url" >>"$LOG" 2>&1; then
                printf '%s\t%s\n' "$p_name" "wheel download failed: $p_url" \
                    >>/floe/template-pypi-prefail.tsv
                continue
            fi
            printf '%s  %s\n' "$p_sha" "$p_wheel" >/floe/wheels/template-verify.sha256
            if ! (cd /floe/wheels && sha256sum --check --strict template-verify.sha256 >>"$LOG" 2>&1); then
                printf '%s\t%s\n' "$p_name" "sha256 mismatch for $p_wheel" \
                    >>/floe/template-pypi-prefail.tsv
                rm -f "$dest"
                continue
            fi
            wheel_paths="$wheel_paths $dest"
        done </floe/template-pypi.tsv
        if [ -n "$wheel_paths" ]; then
            if ! python3 -m pip --version >>"$LOG" 2>&1; then
                pip_state=missing
                note "pypi: python3 -m pip is not available (python3-pip must come from the recipe)"
            else
                pip_rc=0
                # shellcheck disable=SC2086 # wheel_paths is a deliberate path list
                python3 -m pip install --break-system-packages --no-index \
                    --no-input --disable-pip-version-check \
                    --find-links /floe/wheels $wheel_paths >>"$LOG" 2>&1 || pip_rc=$?
                pip_state=$pip_rc
                note "pypi: pip install rc=$pip_rc"
            fi
        fi
    fi
    printf '%s\n' "$pip_state" >/floe/template-pypi-pip-rc.txt

    facts_rc=0
    python3 - /floe "$TEMPLATE_RECIPE" <<'FLOE_TEMPLATE_FACTS_PY' || facts_rc=$?
import importlib
import importlib.metadata
import json
import os
import sys

share = sys.argv[1]
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    recipe = json.load(handle)
template_name = recipe.get("name")
packages = recipe.get("packages") or {}
pypi = recipe.get("pypi") or {}


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return [line.rstrip("\n") for line in handle if line.strip()]
    except OSError:
        return []


def read_text(path, default=""):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return default


requested = sorted(packages)
installed = {}
for line in read_lines(os.path.join(share, "template-apt-facts.tsv")):
    parts = line.split("\t")
    if len(parts) < 5:
        continue
    bare = parts[0].split(":")[0]
    installed[bare] = {
        "name": parts[0],
        "version": parts[1],
        "arch": parts[2],
        "source": parts[3] or bare,
        "installed_kb": int(parts[4]) if parts[4].isdigit() else 0,
    }
missing = [name for name in requested if name not in installed]
apt_packages = [installed[name] for name in requested if name in installed]

prefail = {}
for line in read_lines(os.path.join(share, "template-pypi-prefail.tsv")):
    parts = line.split("\t", 1)
    if parts and parts[0]:
        prefail[parts[0]] = parts[1] if len(parts) > 1 else "wheel verification failed"
pip_state = read_text(os.path.join(share, "template-pypi-pip-rc.txt"), "none") or "none"
try:
    install_rc = int(read_text(os.path.join(share, "template-install-rc.txt"), "0") or "0")
except ValueError:
    install_rc = -1


def import_check(distribution, module, expected):
    try:
        imported = importlib.import_module(module)
    except Exception as exc:  # noqa: BLE001 - any import failure is a failure
        return False, "import %s failed: %s" % (module, exc)
    observed = getattr(imported, "__version__", None)
    where = "module __version__"
    if observed is None:
        try:
            observed = importlib.metadata.version(distribution)
            where = "distribution metadata"
        except Exception:
            return False, ("imported but no observable version is available "
                           "(cannot verify pinned %s)" % expected)
    observed = str(observed).strip()
    if observed != expected:
        return False, "version mismatch: observed %s, pinned %s (%s)" % (observed, expected, where)
    return True, "import ok, version %s (%s)" % (observed, where)


pypi_installed = []
pypi_failures = []
for distribution in sorted(pypi):
    entry = pypi[distribution] or {}
    version = str(entry.get("version", ""))
    module = entry.get("import") or distribution.replace("-", "_")
    reason = None
    if distribution in prefail:
        reason = prefail[distribution]
    elif pip_state == "none":
        reason = "no pip run happened for this wheel (download/verification gap)"
    elif pip_state == "missing":
        reason = "python3 -m pip is not available"
    elif pip_state != "0":
        reason = "pip install failed (rc=%s)" % pip_state
    if reason is not None:
        pypi_failures.append({"name": distribution, "detail": reason})
        continue
    ok, detail = import_check(distribution, module, version)
    pypi_installed.append({"name": distribution, "version": version,
                           "import_ok": ok, "detail": detail})
    if not ok:
        pypi_failures.append({"name": distribution, "detail": detail})

payload = {
    "schema": 1,
    "template": template_name,
    "apt": {
        "requested": requested,
        "install_rc": install_rc,
        "missing": missing,
        "packages": apt_packages,
    },
    "pypi": {
        "requested": sorted(pypi),
        "installed": pypi_installed,
        "failures": pypi_failures,
    },
}
with open(os.path.join(share, "template-install.json"), "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")

for name in missing:
    print("FLOE_STAGE1_TEMPLATE_APT_MISSING %s" % name)
for record in pypi_installed:
    if record["import_ok"]:
        print("FLOE_STAGE1_PYPI_OK %s=%s" % (record["name"], record["version"]))
for failure in pypi_failures:
    print("FLOE_STAGE1_PYPI_FAILED %s %s" % (failure["name"], failure["detail"]))

sys.exit(1 if (missing or pypi_failures) else 0)
FLOE_TEMPLATE_FACTS_PY
    template_facts_rc=$facts_rc
    note "template install facts rc=$template_facts_rc"
fi

# 6. Command presence (the real capability checks run in stage 2) ------------
for c in ps setsid nohup bash zsh zip unzip 7z xz bzip2 sqlite3 ssh scp; do
    if command -v "$c" >/dev/null 2>&1; then
        note "command present: $c -> $(command -v "$c")"
    else
        note "command MISSING: $c"
        mark "MISSING_$c"
    fi
done

# Drop the downloaded .deb cache from the shipped image; the package lists
# stay so the guest can install more interactively later.
apt-get clean >/dev/null 2>&1 || true
rm -rf /var/lib/apt/lists/partial >/dev/null 2>&1 || true

sync

if [ "$update_rc" != "0" ] || [ "$install_rc" != "0" ] || [ "$template_facts_rc" != "0" ]; then
    note "stage1 FAILED (apt update rc=$update_rc install rc=$install_rc template facts rc=$template_facts_rc): refusing to continue"
    mark FAILED
    exit 9
fi
note "stage1 done"
mark DONE
exit 0
