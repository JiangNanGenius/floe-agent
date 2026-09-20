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
#   4. it installs the packages the image ships (the 13 user-facing commands
#      from the feedback report plus Python/pip/venv/numpy and node/npm);
#   5. it exports the installed-package inventory used later to build the
#      corresponding-source mapping.
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
rm -f /etc/resolv.conf
printf 'nameserver 10.0.2.3\n' >/etc/resolv.conf
if ping -c1 -W3 10.0.2.2 >>"$LOG" 2>&1; then
    mark PING_OK
else
    mark PING_FAIL
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
# shellcheck disable=SC2086 # PACKAGES is a deliberate word list
apt-get install -y --no-install-recommends $PACKAGES >>"$LOG" 2>&1
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

if [ "$update_rc" != "0" ] || [ "$install_rc" != "0" ]; then
    note "stage1 FAILED (apt update rc=$update_rc install rc=$install_rc): refusing to continue"
    mark FAILED
    exit 9
fi
note "stage1 done"
mark DONE
exit 0
