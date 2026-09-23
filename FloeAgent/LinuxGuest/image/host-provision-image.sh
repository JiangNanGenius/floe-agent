#!/usr/bin/env bash
# host-provision-image.sh — cloud-host accelerated provisioning of the Floe
# Linux guest image (owner job-d56b526d441c4faa, D3).
#
# Why this exists: the dev-document recipe (49 direct apt requirements, ~340
# debs with dependencies) cannot finish unpacking under the on-device TinyEMU
# interpreter within any sane CI budget — cloud run 35913267297 proved even the
# basic template only reached dependency 163/386 after 2700 s. The on-device
# engine stays interpreter/no-JIT; this script accelerates the CLOUD build
# only, and every verification property of the original in-Guest install is
# preserved:
#
#   * Debian signature verification: apt runs the image's own apt against the
#     real Debian archive keyring with its normal signed-by checks over HTTPS
#     (the exact same floe-direct.sources the guest installer writes).
#   * Real package scripts/database: dpkg inside the chroot executes the real
#     riscv64 maintainer scripts (postinst etc. run as riscv64 user processes
#     under qemu-user) against the image's real /var/lib/dpkg database on the
#     real ext4 rootfs — no database synthesis, no file copying shortcuts.
#   * Package scopes: the install list is exactly the validated recipe's
#     packages (or nothing), installed with `apt-get install -y
#     --no-install-recommends`, mirroring guest-stage1-install.sh command for
#     command.
#   * Pinned wheels: each recipe wheel is downloaded from its pinned URL,
#     sha256-verified, installed with `pip --break-system-packages --no-index`,
#     and import-checked at its pinned version by the guest interpreter.
#
# The produced evidence uses the exact same names and JSON schema the
# manifest builder and the templates job consume (guest-packages.tsv,
# guest-dpkg-status.txt, template-install.json, stage1-install.log, ...), so
# downstream tooling cannot tell the difference except through the recorded
# provisioning method.
#
# Usage (Linux, root):
#   sudo bash FloeAgent/LinuxGuest/image/host-provision-image.sh \
#       --image work/image/disk.img --recipe templates/dev-document.json \
#       --share work/share9p --evidence work/evidence
#
# Options:
#   --image FILE       the partitionless ext4 guest image (read-write)
#   --recipe FILE      validated template recipe (schema 1)
#   --share DIR        the 9P share the guest boots will also read
#   --evidence DIR     evidence output directory
#   --apt-update-s N   bound for apt-get update (default 900)
#   --apt-install-s N  bound for apt-get install (default 3600)
#   --wheels-s N       bound for wheel download/pip (default 1200)
set -euo pipefail

die() {
    printf 'host-provision-image: ERROR: %s\n' "$*" >&2
    exit 1
}

image=""
recipe=""
share=""
evidence=""
apt_update_s=900
apt_install_s=3600
wheels_s=1200

while [ $# -gt 0 ]; do
    case "$1" in
        --image) image="${2:-}"; shift 2 ;;
        --recipe) recipe="${2:-}"; shift 2 ;;
        --share) share="${2:-}"; shift 2 ;;
        --evidence) evidence="${2:-}"; shift 2 ;;
        --apt-update-s) apt_update_s="${2:-}"; shift 2 ;;
        --apt-install-s) apt_install_s="${2:-}"; shift 2 ;;
        --wheels-s) wheels_s="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$image" ] || die "--image is required"
[ -n "$recipe" ] || die "--recipe is required"
[ -n "$share" ] || die "--share is required"
[ -n "$evidence" ] || die "--evidence is required"
[ -f "$image" ] || die "guest image not found: $image"
[ -f "$recipe" ] || die "recipe not found: $recipe"
[ -d "$share" ] || die "share directory not found: $share"
[ -d "$evidence" ] || die "evidence directory not found: $evidence"
[ "$(uname -s)" = "Linux" ] || die "this script needs Linux loop mounts"
[ "$(id -u)" = "0" ] || die "run as root (losetup/mount/binfmt are required)"
for tool in losetup mount umount chroot sha256sum curl python3 timeout; do
    command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

phases_file="$evidence/provision-phases.txt"
env_file="$evidence/provision-env.txt"
notes="$share/stage1-install.log"
: >"$phases_file"
: >"$notes"

phase() { # phase <name> -- records elapsed seconds of the just-finished phase
    local name="$1" end
    end="$(date +%s)"
    if [ -n "${phase_start:-}" ]; then
        printf '%s start=%s end=%s elapsed_s=%s\n' "$phase_name" "$phase_start" "$end" "$((end - phase_start))" >>"$phases_file"
    fi
    phase_name="$name"
    phase_start="$end"
}

note() {
    printf '%s\n' "$*" >>"$notes"
    printf '%s\n' "$*"
}

# ---------------------------------------------------------------------------
# 1. qemu-user riscv64 binfmt registration (idempotent, F flag for chroot)
# ---------------------------------------------------------------------------
phase "binfmt-register"
binfmt_dir=/proc/sys/fs/binfmt_misc
if ! mountpoint -q "$binfmt_dir" 2>/dev/null; then
    mount -t binfmt_misc binfmt_misc "$binfmt_dir" 2>/dev/null \
        || die "cannot mount binfmt_misc; the runner kernel lacks CONFIG_BINFMT_MISC"
fi

qemu_bin=""
for candidate in /usr/bin/qemu-riscv64-static /usr/libexec/qemu-binfmt/riscv64-binfmt \
                 /usr/lib/qemu/qemu-riscv64-static; do
    if [ -x "$candidate" ]; then
        qemu_bin="$candidate"
        break
    fi
done
[ -n "$qemu_bin" ] || qemu_bin="$(command -v qemu-riscv64-static || true)"
[ -n "$qemu_bin" ] || die "no qemu-user riscv64 static binary found (install qemu-user-static)"

register_binfmt() {
    # The F flag opens the interpreter at registration time, so binaries
    # executed inside the chroot resolve the interpreter on the host instead
    # of inside the guest rootfs. The magic/mask pair is the canonical
    # qemu-binfmt riscv64 registration (ET_EXEC/ET_DYN, EM_RISCV).
    printf ':qemu-riscv64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:%s:F\n' \
        "$qemu_bin" >"$binfmt_dir/register"
}

if [ ! -e "$binfmt_dir/qemu-riscv64" ]; then
    register_binfmt
fi

{
    printf 'qemu_bin=%s\n' "$qemu_bin"
    qemu-riscv64-static --version 2>/dev/null | head -1 || "$qemu_bin" --version 2>/dev/null | head -1 || true
    printf 'register_record=%s\n' "$(cat "$binfmt_dir/qemu-riscv64" 2>/dev/null | tr '\n' ' ')"
    printf 'host_kernel=%s\n' "$(uname -r)"
    printf 'host_arch=%s\n' "$(uname -m)"
} >"$env_file"

# ---------------------------------------------------------------------------
# 2. mount the image and prepare the chroot
# ---------------------------------------------------------------------------
phase "mount-image"
mnt="$(mktemp -d /tmp/floe-provision.XXXXXX)"
loop_device=""
saved_resolv=""
mounted=0
cleanup() {
    [ -n "$saved_resolv" ] && [ -n "${loop_device:-}" ] && [ "$mounted" = "1" ] && {
        rm -f "$mnt/etc/resolv.conf"
        if [ -f "$mnt/etc/resolv.conf.floe-save" ]; then
            mv "$mnt/etc/resolv.conf.floe-save" "$mnt/etc/resolv.conf"
        fi
    } 2>/dev/null || true
    [ "$mounted" = "1" ] && umount -R "$mnt" 2>/dev/null || true
    [ -n "$loop_device" ] && losetup -d "$loop_device" 2>/dev/null || true
    rm -rf "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

loop_device="$(losetup --find --show "$image")"
mount "$loop_device" "$mnt"
mounted=1
mkdir -p "$mnt/dev" "$mnt/proc" "$mnt/sys"
mount --rbind /dev "$mnt/dev"
mount --make-rslave "$mnt/dev"
mount -t proc proc "$mnt/proc"
mount -t sysfs sys "$mnt/sys"

# Resolver for the chrooted apt run only; the original bytes are restored on
# exit (the runner writes its own resolver list at guest boot).
if [ -e "$mnt/etc/resolv.conf" ] || [ -L "$mnt/etc/resolv.conf" ]; then
    mv "$mnt/etc/resolv.conf" "$mnt/etc/resolv.conf.floe-save"
    saved_resolv=1
fi
cp -L /etc/resolv.conf "$mnt/etc/resolv.conf"

# Decline service starts in the chroot (no init is running there, exactly as
# on the runner-mediated guest boots); removed again before unmount.
printf '#!/bin/sh\nexit 101\n' >"$mnt/usr/sbin/policy-rc.d"
chmod 0755 "$mnt/usr/sbin/policy-rc.d"

build_root=/var/tmp/floe-image-build
mkdir -p "$mnt$build_root/wheels"
chmod 1777 "$mnt$build_root"

# Guest execution environment. `timeout` execs its argv directly and cannot
# see shell functions, so every bounded call must spell out
# `timeout N env "${guest_env[@]}" chroot "$mnt" ...` — never `timeout N
# inchroot ...`.
guest_env=(
    "QEMU_LD_PREFIX=$mnt"
    "DEBIAN_FRONTEND=noninteractive"
    "TMPDIR=$build_root"
    "TMP=$build_root"
    "TEMP=$build_root"
    "HOME=/root"
)
inchroot() {
    env "${guest_env[@]}" chroot "$mnt" "$@"
}

# Sanity: the binfmt handler must execute the guest's own riscv64 binaries.
if ! inchroot /bin/true 2>>"$env_file"; then
    note "binfmt: existing qemu-riscv64 registration cannot run guest binaries; re-registering"
    echo -1 >"$binfmt_dir/qemu-riscv64" 2>/dev/null || true
    register_binfmt
    inchroot /bin/true 2>>"$env_file" || die "qemu-user riscv64 chroot execution failed"
fi
note "binfmt: guest /bin/true executed via qemu-user (interpreter $qemu_bin)"

# ---------------------------------------------------------------------------
# 3. APT source surgery (identical to guest-stage1-install.sh)
# ---------------------------------------------------------------------------
phase "apt-source-surgery"
for source_file in "$mnt"/etc/apt/sources.list "$mnt"/etc/apt/sources.list.d/*.sources "$mnt"/etc/apt/sources.list.d/*.list;
do
    [ -f "$source_file" ] || continue
    if grep -q 'mirror+file:' "$source_file"; then
        mv "$source_file" "$source_file.floe-disabled"
        note "disabled unsupported APT mirror-list source: ${source_file#"$mnt"}"
    fi
done
cat >"$mnt/etc/apt/sources.list.d/floe-direct.sources" <<'FLOE_APT_SOURCES'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
FLOE_APT_SOURCES

# ---------------------------------------------------------------------------
# 4. recipe -> apt list + pinned wheel table (same rules as the guest parser)
# ---------------------------------------------------------------------------
phase "recipe-export"
python3 - "$share" "$recipe" <<'FLOE_RECIPE_EXPORT_PY'
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
FLOE_RECIPE_EXPORT_PY
template_name="$(cat "$share/template-name.txt")"
note "template '$template_name': $(wc -l <"$share/template-apt-list.txt") apt requirement(s), $(wc -l <"$share/template-pypi.tsv" 2>/dev/null || echo 0) pypi entry(ies)"
cp "$recipe" "$mnt$build_root/template-recipe.json"

# ---------------------------------------------------------------------------
# 5. signed HTTPS apt update + recipe package install (real dpkg, real scripts)
# ---------------------------------------------------------------------------
phase "apt-update"
note "apt-get update: signed HTTPS against the image's own keyring and sources"
update_rc=0
timeout "$apt_update_s" env "${guest_env[@]}" chroot "$mnt" apt-get update \
    >"$evidence/stage1-apt-update.log" 2>&1 || update_rc=$?
if [ "$update_rc" != "0" ]; then
    note "apt-get update FAILED (rc=$update_rc); see evidence/stage1-apt-update.log"
    tail -20 "$evidence/stage1-apt-update.log" >>"$notes" || true
    phase "apt-update"
    exit "$update_rc"
fi
note "apt-get update rc=0"
phase "apt-update"

phase "apt-install"
install_list="$(tr '\n' ' ' <"$share/template-apt-list.txt")"
# shellcheck disable=SC2086 # install_list is a deliberate word list
install_rc=0
# shellcheck disable=SC2086 # install_list is a deliberate word list
timeout "$apt_install_s" env "${guest_env[@]}" chroot "$mnt" \
    apt-get install -y --no-install-recommends \
    $install_list >"$evidence/stage1-apt-install.log" 2>&1 || install_rc=$?
if [ "$install_rc" != "0" ]; then
    note "apt-get install FAILED (rc=$install_rc); see evidence/stage1-apt-install.log"
    tail -20 "$evidence/stage1-apt-install.log" >>"$notes" || true
    phase "apt-install"
    exit "$install_rc"
fi
note "apt-get install rc=0 ($install_list)"
phase "apt-install"

# ---------------------------------------------------------------------------
# 6. inventory exports (same names/schema as the in-Guest stage 1)
# ---------------------------------------------------------------------------
phase "inventory-export"
inchroot dpkg-query -W \
    -f='${binary:Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n' \
    >"$evidence/guest-packages.tsv" 2>"$evidence/dpkg-query-provision.log" || true
cp "$mnt/var/lib/dpkg/status" "$evidence/guest-dpkg-status.txt"
# shellcheck disable=SC2046 # package names contain no whitespace
inchroot dpkg-query -W \
    -f='${binary:Package}\t${Version}\t${Architecture}\t${source:Package}\t${Installed-Size}\n' \
    $(cat "$share/template-apt-list.txt") \
    >"$mnt$build_root/template-apt-facts.tsv" 2>>"$notes" || true
cp "$mnt/etc/apt/sources.list" "$evidence/guest-apt-sources.list" 2>/dev/null || true
if [ -d "$mnt/etc/apt/sources.list.d" ]; then
    mkdir -p "$evidence/guest-apt-sources.list.d"
    cp -a "$mnt/etc/apt/sources.list.d/." "$evidence/guest-apt-sources.list.d/" 2>/dev/null || true
fi
note "package inventory: $(wc -l <"$evidence/guest-packages.tsv") records"

# ---------------------------------------------------------------------------
# 7. pinned PyPI wheels: download, sha256-verify, pip install, import facts
# ---------------------------------------------------------------------------
phase "wheels-download-install"
printf '0\n' >"$mnt$build_root/template-install-rc.txt"
pip_state=none
if [ -s "$share/template-pypi.tsv" ]; then
    : >"$mnt$build_root/template-pypi-prefail.tsv"
    wheel_paths=""
    while IFS="$(printf '\t')" read -r p_name p_version p_wheel p_url p_sha p_module; do
        [ -n "$p_name" ] || continue
        dest="$mnt$build_root/wheels/$p_wheel"
        note "pypi: downloading $p_name -> $p_wheel"
        if ! curl -L --fail --retry 3 -o "$dest" "$p_url" >"$evidence/wheel-$p_name.log" 2>&1; then
            printf '%s\t%s\n' "$p_name" "wheel download failed: $p_url" \
                >>"$mnt$build_root/template-pypi-prefail.tsv"
            continue
        fi
        printf '%s  %s\n' "$p_sha" "$p_wheel" >"$mnt$build_root/wheels/template-verify.sha256"
        if ! (cd "$mnt$build_root/wheels" && sha256sum --check --strict template-verify.sha256 \
                >>"$evidence/wheel-$p_name.log" 2>&1); then
            printf '%s\t%s\n' "$p_name" "sha256 mismatch for $p_wheel" \
                >>"$mnt$build_root/template-pypi-prefail.tsv"
            rm -f "$dest"
            continue
        fi
        wheel_paths="$wheel_paths $build_root/wheels/$p_wheel"
    done <"$share/template-pypi.tsv"
    if [ -n "$wheel_paths" ]; then
        if ! inchroot python3 -m pip --version >>"$notes" 2>&1; then
            pip_state=missing
            note "pypi: python3 -m pip is not available (python3-pip must come from the recipe)"
        else
            pip_rc=0
            # shellcheck disable=SC2086 # wheel_paths is a deliberate path list
            timeout "$wheels_s" env "${guest_env[@]}" chroot "$mnt" \
                python3 -m pip install --break-system-packages \
                --no-index --no-input --disable-pip-version-check \
                --find-links "$build_root/wheels" $wheel_paths \
                >"$evidence/stage1-pip-install.log" 2>&1 || pip_rc=$?
            if [ "$pip_rc" != "0" ]; then
                tail -20 "$evidence/stage1-pip-install.log" >>"$notes" || true
            fi
            pip_state=$pip_rc
            note "pypi: pip install rc=$pip_rc"
        fi
    fi
fi
printf '%s\n' "$pip_state" >"$mnt$build_root/template-pypi-pip-rc.txt"
phase "wheels-download-install"

# ---------------------------------------------------------------------------
# 8. template install facts (same JSON schema as the in-Guest stage 1)
# ---------------------------------------------------------------------------
phase "template-install-facts"
cat >"$mnt$build_root/template-install-facts.py" <<'FLOE_TEMPLATE_FACTS_PY'
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

facts_rc=0
inchroot python3 "$build_root/template-install-facts.py" "$build_root" "$build_root/template-recipe.json" \
    >>"$notes" 2>&1 || facts_rc=$?
note "template install facts rc=$facts_rc"
cp "$mnt$build_root/template-install.json" "$share/template-install.json" 2>/dev/null || true
cp "$mnt$build_root/template-install.json" "$evidence/template-install.json" 2>/dev/null || true
phase "template-install-facts"

# ---------------------------------------------------------------------------
# 9. clean the chroot back to the shippable state and unmount
# ---------------------------------------------------------------------------
phase "cleanup"
inchroot apt-get clean >/dev/null 2>&1 || true
rm -rf "$mnt/var/lib/apt/lists/partial" >/dev/null 2>&1 || true
rm -rf "$mnt$build_root/wheels" "$mnt$build_root/template-recipe.json" \
       "$mnt$build_root/template-apt-facts.tsv" "$mnt$build_root/template-pypi-prefail.tsv" \
       "$mnt$build_root/template-pypi-pip-rc.txt" "$mnt$build_root/template-install-rc.txt" \
       "$mnt$build_root/template-install-facts.py" "$mnt$build_root/template-install.json" \
       >/dev/null 2>&1 || true
rm -f "$mnt/usr/sbin/policy-rc.d"
note "cleaned: apt archives, wheel staging, provisioning helpers, policy-rc.d"
sync
umount -R "$mnt"
mounted=0
losetup -d "$loop_device"
loop_device=""
rm -rf "$mnt"

phase "done"
{
    printf 'provision_method=qemu-user riscv64 chroot (cloud-host acceleration, job-d56b526d441c4faa D3)\n'
    printf 'qemu_bin=%s\n' "$qemu_bin"
    printf 'template=%s\n' "$template_name"
    printf 'apt_update_s_bound=%s apt_install_s_bound=%s wheels_s_bound=%s\n' \
        "$apt_update_s" "$apt_install_s" "$wheels_s"
} >>"$env_file"

note "host provisioning done: method=qemu-user chroot, template=$template_name, facts_rc=$facts_rc"
[ "$facts_rc" = "0" ] || exit "$facts_rc"
