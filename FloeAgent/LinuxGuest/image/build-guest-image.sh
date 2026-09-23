#!/usr/bin/env bash
# build-guest-image.sh — build, boot-verify and package the Floe Linux guest
# image candidate (Debian 13 riscv64 userland on the pinned 2018 bbl/kernel,
# with the Floe runner injected as PID 1).
#
# This is component tooling: it runs on a disposable Linux CI runner (root,
# ~15 GB free) and produces a pinned, reviewable artifact set. It never
# publishes anything and never touches app code.
#
# What it does, in order:
#   1. fetch + verify the pinned TinyEMU source and demo archive;
#   2. build the embeddable engine + qualification host (FENCE patch required);
#   3. fetch + verify the pinned Debian 13 nocloud qcow2 (dated URL, SHA-512);
#   4. clear the ext4 features the 4.15 fallback kernel cannot mount and
#      extract the rootfs partition into a partitionless whole-disk image;
#   5. cross-build the static riscv64 Floe runner (and its relink object);
#   6. inject /usr/local/bin/floe-exec;
#   7. provision A (default --provision host): the image is mounted on the
#      cloud host and the template recipe's packages are installed through a
#      qemu-user riscv64 chroot (host-provision-image.sh) — signed HTTPS APT
#      with the image's own keyring, real dpkg maintainer scripts against the
#      real ext4 rootfs/database, pinned PyPI wheels sha256-verified and pip
#      installed, then boot A re-checks clock/network/signed apt and the
#      recipe coherence against the LIVE dpkg database inside the real guest.
#      `--provision guest` keeps the historical all-in-Guest install path
#      (slow; it cannot finish the dev-document recipe under TinyEMU);
#   8. boot B: fresh `floe.epoch=`, re-checks the clock, signed HTTPS APT,
#      Python HTTPS with default CA verification, runs the 13 user-facing
#      commands the feedback report listed (ps setsid nohup bash zsh zip unzip
#      7z xz bzip2 sqlite3 ssh scp) as real operations and independently
#      re-verifies every template requirement against the live dpkg database;
#   9. collect evidence (dpkg inventory, copyrights, ext4 features, logs),
#      write manifest.json (the LinuxGuestImageStore schema) and package the
#      distributable zip.
#
# Every boot-verification assertion is a hard failure: a missing marker means
# the script exits non-zero and keeps the transcript. `--skip-qualified`
# writes the manifest with qualified=false instead (used when investigating).
#
# Usage (Linux, root):
#   sudo bash FloeAgent/LinuxGuest/image/build-guest-image.sh \
#       --work /tmp/floe-image-work --run-url https://github.com/.../runs/123
#
# Options:
#   --work DIR            scratch/output root (required)
#   --repo DIR            repository root (default: three levels above this script)
#   --pins FILE           pinned inputs JSON
#   --template NAME       runtime-template recipe templates/NAME.json
#                         (default: basic). The recipe is validated before
#                         any heavy work; a missing/invalid recipe aborts the
#                         build with the exact path (owner job-6f5ac974858c47c2
#                         D). The manifest id is always unique and versioned:
#                         floe-debian13-riscv64-<daily>-<template>-r<recipe
#                         content hash>; it never reuses the published
#                         plain-id of the pre-template image.
#   --image-id ID         manifest id (default: derived from the Debian build)
#   --run-url URL         qualification run URL recorded in the manifest
#   --source-ref REF      git commit recorded in the provenance source URLs
#   --skip-fetch          reuse already-downloaded sources/images
#   --skip-engine         reuse an existing engine build in <work>/build
#   --provision MODE      host (default) = qemu-user chroot provisioning on the
#                         cloud host + in-Guest coherence boot; guest = install
#                         everything inside the TinyEMU guest (legacy)
#   --boot-dir DIR        use bbl64.bin + kernel-riscv64.bin from DIR instead
#                         of the pinned 2018 demo pair (for a freshly built
#                         kernel/bbl: SMP qualification). Their real hashes are
#                         recorded in evidence/bios-kernel-pins.txt and in the
#                         manifest, and the pinned-kernel capability claim is
#                         dropped from the qualification evidence text.
#   --boot-max-s N        per-boot timeout seconds (default 2700)
#   --ram MB              guest RAM (default 1024)
#   --no-zip              skip the distributable zip (manifest still written)
#   --skip-qualified      write qualified=false (never used for a release)
set -euo pipefail

die() {
    printf 'build-guest-image: ERROR: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\n=== [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

# The workflow invokes this script under sudo, but later workflow steps run as
# the invoking user and must write into the evidence bundle (boot-file
# provenance record, staging). sudo leaves every file root-owned, which made
# run 35922881481 fail its provenance step with EACCES after provisioning.
# Hand the output tree back to the invoking user on every exit path.
restore_ownership() {
    local uid="${SUDO_UID:-}"
    local gid="${SUDO_GID:-$uid}"
    [ -n "$uid" ] || return 0
    [ -d "$evidence_dir" ] || return 0
    chown -R "$uid:$gid" "$evidence_dir" "$share_dir" "$image_dir" 2>/dev/null || true
    chmod -R u+rwX "$evidence_dir" "$share_dir" 2>/dev/null || true
}

work=""
repo=""
pins=""
template="basic"
image_id=""
run_url=""
source_ref=""
skip_fetch=0
skip_engine=0
provision="host"
boot_dir=""
boot_max_s=2700
ram_mb=1024
make_zip=1
claim_qualified=1

while [ $# -gt 0 ]; do
    case "$1" in
        --work) work="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --pins) pins="${2:-}"; shift 2 ;;
        --template) template="${2:-}"; shift 2 ;;
        --image-id) image_id="${2:-}"; shift 2 ;;
        --run-url) run_url="${2:-}"; shift 2 ;;
        --source-ref) source_ref="${2:-}"; shift 2 ;;
        --skip-fetch) skip_fetch=1; shift ;;
        --skip-engine) skip_engine=1; shift ;;
        --provision) provision="${2:-}"; shift 2 ;;
        --boot-dir) boot_dir="${2:-}"; shift 2 ;;
        --boot-max-s) boot_max_s="${2:-}"; shift 2 ;;
        --ram) ram_mb="${2:-}"; shift 2 ;;
        --no-zip) make_zip=0; shift ;;
        --skip-qualified) claim_qualified=0; shift ;;
        -h|--help) sed -n '2,63p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$work" ] || die "--work is required"
[ "$(uname -s)" = "Linux" ] || die "this script needs Linux loop mounts"
[ "$(id -u)" = "0" ] || die "run as root (losetup/mount are required)"
case "$provision" in
    host|guest) ;;
    *) die "invalid --provision mode: '$provision' (allowed: host, guest)" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$provision" = "host" ]; then
    # The accelerated path is cloud-only tooling; it must never be required
    # on a developer machine, so its absence is an explicit early error.
    [ -f "$script_dir/host-provision-image.sh" ] \
        || die "host provisioning script missing: $script_dir/host-provision-image.sh"
fi
repo="${repo:-$(cd "$script_dir/../../.." && pwd)}"
pins="${pins:-$repo/FloeAgent/ThirdParty/TinyEMU/guest-image/pinned-inputs.json}"
image_dir="$work/image"
evidence_dir="$work/evidence"
share_dir="$work/share9p"
runner_dir="$work/runner"
mnt_dir="$work/mnt"

for tool in curl python3 parted e2fsck resize2fs tune2fs losetup mount dd qemu-img sha512sum sha256sum make gcc zip unzip; do
    command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
[ -f "$pins" ] || die "pinned inputs not found: $pins"
mkdir -p "$work" "$image_dir" "$evidence_dir" "$share_dir" "$runner_dir" "$mnt_dir"

# Runtime-template recipe: the package/PyPI manifest of the image being built.
# It is validated before any heavy work (fetch/build are expensive, and a
# missing recipe is an explicit dependency failure owned by job D).
case "$template" in
    ""|*/*|.|..) die "invalid --template name: '$template'" ;;
    *[!A-Za-z0-9._-]*) die "invalid --template name: '$template' (allowed: letters, digits, '.', '_', '-')" ;;
esac
recipe_path="$script_dir/templates/$template.json"
[ -f "$recipe_path" ] || die "template recipe not found: $recipe_path (owner job-6f5ac974858c47c2 D)"
[ -r "$recipe_path" ] && [ -s "$recipe_path" ] \
    || die "template recipe is not readable or is empty: $recipe_path (owner job-6f5ac974858c47c2 D)"
[ -f "$script_dir/template_recipe.py" ] || die "template validator not found: $script_dir/template_recipe.py"
if ! recipe_summary="$(python3 "$script_dir/template_recipe.py" validate --recipe "$recipe_path" 2>&1)"; then
    die "template recipe is invalid: $recipe_path (owner job-6f5ac974858c47c2 D)
$recipe_summary"
fi
printf 'template recipe: %s\n' "$recipe_summary"

pin() { # pin <python expression over the parsed JSON>
    python3 - "$pins" "$1" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = eval(sys.argv[2], {"__builtins__": {}}, {"p": data})  # noqa: S307 - fixed caller expressions
print(value)
PY
}

engine_url="$(pin 'p["engine"]["url"]')"
engine_sha="$(pin 'p["engine"]["sha256"]')"
demo_sha="$(pin 'p["demo_archive"]["sha256"]')"
bios_sha="$(pin 'p["demo_archive"]["bios"]["sha256"]')"
kernel_sha="$(pin 'p["demo_archive"]["kernel"]["sha256"]')"
kernel_bytes="$(pin 'p["demo_archive"]["kernel"]["bytes"]')"
bios_bytes="$(pin 'p["demo_archive"]["bios"]["bytes"]')"
debian_url="$(pin 'p["debian_image"]["url"]')"
debian_sha512="$(pin 'p["debian_image"]["sha512"]')"
debian_sha256="$(pin 'p["debian_image"]["sha256"]')"
debian_bytes="$(pin 'p["debian_image"]["bytes"]')"
daily_build="$(pin 'p["debian_image"]["daily_build"]')"
patch_marker="$(pin 'p["engine"]["required_patch_marker"]')"
cmdline="console=hvc0 root=/dev/vda rw loglevel=4"
if [ -z "$image_id" ]; then
    # Template images are NEW versioned artifacts: they must never reuse the
    # published plain id `floe-debian13-riscv64-<daily>` (run 35923812691
    # showed the collision breaks C5 prepare and user upgrades — same id,
    # different disk digest). Both basic and named templates therefore carry
    # the template name plus a stable content version derived from the
    # recipe's semantic fields (name/packages/pypi): a recipe edit that
    # changes what is installed re-versions the id, while description-only
    # edits keep it stable.
    template_rev="$(python3 - "$recipe_path" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    recipe = json.load(handle)
semantic = {
    "name": recipe.get("name"),
    "packages": recipe.get("packages") or {},
    "pypi": recipe.get("pypi") or {},
}
canonical = json.dumps(semantic, sort_keys=True, separators=(",", ":"))
print(hashlib.sha512(canonical.encode("utf-8")).hexdigest()[:12])
PY
)"
    image_id="floe-debian13-riscv64-$(printf '%s' "$daily_build" | tr -d '-')-${template}-r${template_rev}"
fi
runner_src="$repo/FloeAgent/LinuxGuest/runner/floe_exec.c"
[ -f "$runner_src" ] || die "runner source not found: $runner_src"
if [ -z "$source_ref" ]; then
    source_ref="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
fi

# ---------------------------------------------------------------------------
step "1/9 fetch + verify pinned sources (TinyEMU + 2018 demo archive)"
# ---------------------------------------------------------------------------
if [ "$skip_fetch" = 0 ]; then
    bash "$repo/FloeAgent/ThirdParty/TinyEMU/fetch_source.sh" "$work/src" >"$evidence_dir/fetch-sources.log" 2>&1
fi
demo_dir="$work/src/diskimage-linux-riscv-2018-09-23"
tinyemu_src="$work/src/tinyemu-2019-12-21"
[ -d "$tinyemu_src" ] || die "TinyEMU source missing (fetch failed?)"
if [ -z "$boot_dir" ]; then
    [ -d "$demo_dir" ] || die "demo archive missing (fetch failed?)"
fi
[ "$(sha256sum "$work/src/tinyemu-2019-12-21.tar.gz" | cut -d' ' -f1)" = "$engine_sha" ] \
    || die "tinyemu-2019-12-21.tar.gz does not match the pinned sha256"
[ "$(sha256sum "$work/src/diskimage-linux-riscv-2018-09-23.tar.gz" | cut -d' ' -f1)" = "$demo_sha" ] \
    || die "diskimage-linux-riscv-2018-09-23.tar.gz does not match the pinned sha256"
printf 'engine_url=%s\nengine_sha256=%s\ndemo_sha256=%s\n' "$engine_url" "$engine_sha" "$demo_sha" \
    >"$evidence_dir/input-pins.txt"
if [ -n "$boot_dir" ]; then
    # Freshly built boot pair (e.g. a CONFIG_SMP kernel + bbl from the SMP
    # qualification pipeline). It is NOT the pinned 2018 pair, so the pin
    # check is replaced by "must exist, must be non-empty" and the real
    # hashes are recorded for the manifest and for review.
    [ -d "$boot_dir" ] || die "--boot-dir is not a directory: $boot_dir"
    for f in bbl64.bin kernel-riscv64.bin; do
        [ -s "$boot_dir/$f" ] || die "--boot-dir is missing $f: $boot_dir"
        # TinyEMU's copy_bios() memcpy()s the BIOS at 0x80000000 and the
        # -kernel file is located through the FDT's riscv,kernel-start; both
        # must be raw images (an ELF bbl would execute its header instead of
        # the reset vector, which is exactly what build-kernel-bbl.sh's
        # objcopy step exists to prevent).
        magic="$(dd if="$boot_dir/$f" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        [ "$magic" != "7f454c46" ] || die "--boot-dir/$f is an ELF file, not a raw boot image"
    done
    if [ -f "$boot_dir/SMP-BUILD.txt" ]; then
        cp "$boot_dir/SMP-BUILD.txt" "$evidence_dir/boot-pair-SMP-BUILD.txt"
        cp "$boot_dir/BOOT-PAIR.txt" "$evidence_dir/boot-pair-BOOT-PAIR.txt" 2>/dev/null || true
        grep -q 'multi-hart IPI path present' "$boot_dir/SMP-BUILD.txt" \
            || die "--boot-dir SMP-BUILD.txt has no firmware multi-hart evidence"
    fi
    cp "$boot_dir/bbl64.bin" "$image_dir/bbl64.bin"
    cp "$boot_dir/kernel-riscv64.bin" "$image_dir/kernel-riscv64.bin"
    printf 'boot pair source=--boot-dir %s (locally built, NOT the pinned 2018 pair)\n' "$boot_dir" \
        >"$evidence_dir/bios-kernel-pins.txt"
    printf 'bbl64.bin bytes=%s sha256=%s\nkernel-riscv64.bin bytes=%s sha256=%s\n' \
        "$(stat -c %s "$image_dir/bbl64.bin")" "$(sha256sum "$image_dir/bbl64.bin" | cut -d' ' -f1)" \
        "$(stat -c %s "$image_dir/kernel-riscv64.bin")" "$(sha256sum "$image_dir/kernel-riscv64.bin" | cut -d' ' -f1)" \
        >>"$evidence_dir/bios-kernel-pins.txt"
    printf 'pinned bbl sha256=%s\npinned kernel sha256=%s\n' "$bios_sha" "$kernel_sha" \
        >>"$evidence_dir/bios-kernel-pins.txt"
else
    [ "$(sha256sum "$demo_dir/bbl64.bin" | cut -d' ' -f1)" = "$bios_sha" ] || die "bbl64.bin does not match the pinned sha256"
    [ "$(sha256sum "$demo_dir/kernel-riscv64.bin" | cut -d' ' -f1)" = "$kernel_sha" ] || die "kernel-riscv64.bin does not match the pinned sha256"
    cp "$demo_dir/bbl64.bin" "$image_dir/bbl64.bin"
    cp "$demo_dir/kernel-riscv64.bin" "$image_dir/kernel-riscv64.bin"
    printf 'bbl64.bin bytes=%s sha256=%s\nkernel-riscv64.bin bytes=%s sha256=%s\n' \
        "$bios_bytes" "$bios_sha" "$kernel_bytes" "$kernel_sha" >"$evidence_dir/bios-kernel-pins.txt"
fi

# ---------------------------------------------------------------------------
step "2/9 build the embeddable engine + qualification host"
# ---------------------------------------------------------------------------
if [ "$skip_engine" = 0 ] || [ ! -x "$work/build/floe_vm_host" ]; then
    (
        cd "$repo/FloeAgent/Qualification/TinyEMULinux"
        make -f "$repo/FloeAgent/ThirdParty/TinyEMU/adapter/Makefile" \
            TINYEMU_SRC="$tinyemu_src" \
            PATCH_DIR="$repo/FloeAgent/ThirdParty/TinyEMU/patches" \
            BUILD="$work/build" HOST_DIR="$repo/FloeAgent/Qualification/TinyEMULinux" \
            -j"$(nproc)"
    ) >"$evidence_dir/engine-build.log" 2>&1
fi
[ -x "$work/build/floe_vm_host" ] || die "floe_vm_host was not built"
grep -q "$patch_marker" "$work/build/riscv_cpu_template.h" \
    || die "the built riscv_cpu_template.h does not carry the FENCE patch marker"
sha256sum FloeAgent/ThirdParty/TinyEMU/patches/*.patch 2>/dev/null || true
( cd "$repo" && sha256sum FloeAgent/ThirdParty/TinyEMU/patches/*.patch ) >"$evidence_dir/engine-patches.sha256"
"$work/build/floe_vm_host" 2>&1 | head -2 >"$evidence_dir/engine-version.txt" || true

# ---------------------------------------------------------------------------
step "3/9 fetch + verify the pinned Debian 13 nocloud image"
# ---------------------------------------------------------------------------
debian_dir="$work/debian"
mkdir -p "$debian_dir"
qcow2="$debian_dir/boot.qcow2"
if [ "$skip_fetch" = 0 ] || [ ! -f "$qcow2" ]; then
    curl -fL --retry 3 --max-time 3600 -o "$qcow2" "$debian_url" \
        >"$evidence_dir/debian-fetch.log" 2>&1
fi
actual_bytes="$(stat -c %s "$qcow2")"
[ "$actual_bytes" = "$debian_bytes" ] || die "Debian qcow2 size mismatch: $actual_bytes != $debian_bytes"
actual_sha512="$(sha512sum "$qcow2" | cut -d' ' -f1)"
[ "$actual_sha512" = "$debian_sha512" ] || die "Debian qcow2 SHA-512 mismatch (the pinned daily build changed or is corrupt)"
actual_sha256="$(sha256sum "$qcow2" | cut -d' ' -f1)"
[ "$actual_sha256" = "$debian_sha256" ] || die "Debian qcow2 SHA-256 mismatch"
{
    printf 'url=%s\nsha512=%s\nsha256=%s\nbytes=%s\n' "$debian_url" "$actual_sha512" "$actual_sha256" "$actual_bytes"
} >"$evidence_dir/debian-input-verified.txt"

# ---------------------------------------------------------------------------
step "4/9 prepare the partitionless ext4 rootfs image"
# ---------------------------------------------------------------------------
raw="$debian_dir/boot.raw"
qemu-img convert -O raw "$qcow2" "$raw" >"$evidence_dir/qemu-convert.log" 2>&1
loop_device="$(losetup -fP --show "$raw")"
cleanup_loop() { losetup -d "$loop_device" 2>/dev/null || true; }
trap cleanup_loop EXIT
partprobe "$loop_device" 2>/dev/null || true
sleep 2
parted -s "$loop_device" unit s print >"$evidence_dir/debian-partitions.txt"
root_part="$(parted -s "$loop_device" print | awk '/ext4/{print $1}' | sort -n | tail -1)"
[ -n "$root_part" ] || die "no ext4 partition found in the Debian image"
# The 4.15 fallback kernel cannot mount orphan_file/metadata_csum_seed.
tune2fs -O ^orphan_file "${loop_device}p${root_part}" >"$evidence_dir/tune2fs-orphan.log" 2>&1 || true
tune2fs -O ^metadata_csum_seed "${loop_device}p${root_part}" >"$evidence_dir/tune2fs-csum-seed.log" 2>&1 || true
e2fsck -fy "${loop_device}p${root_part}" >"$evidence_dir/e2fsck-debian-rootfs.log" 2>&1 || true
part_info="$(parted -s "$loop_device" unit s print | awk -v p="$root_part" '$1==p {gsub(/s/,"",$2); gsub(/s/,"",$3); gsub(/s/,"",$4); print $2, $3, $4}')"
read -r rstart rend rsize <<<"$part_info"
[ -n "$rstart" ] && [ -n "$rend" ] && [ -n "$rsize" ] || die "cannot resolve the rootfs extent from parted"
[ "$((rend - rstart + 1))" = "$rsize" ] || die "parted extent mismatch; refusing to dd a truncated rootfs"
disk_img="$image_dir/disk.img"
dd if="$raw" of="$disk_img" bs=512 skip="$rstart" count="$rsize" status=none
losetup -d "$loop_device"
trap - EXIT
trap restore_ownership EXIT
# The cloud builder installs compilers and document packages before the image
# is distributed. The Debian nocloud root partition is only ~2.8 GiB, which
# leaves too little room for APT archives, unpacking and pinned wheels. Grow
# the partitionless ext4 image sparsely to the same 16 GiB logical capacity
# used for environment disks. Zero-filled extents do not add 16 GiB of host
# storage or download bytes after compression.
logical_disk_bytes=$((16 * 1024 * 1024 * 1024))
truncate -s "$logical_disk_bytes" "$disk_img"
e2fsck -fy "$disk_img" >"$evidence_dir/e2fsck-disk-image.log" 2>&1 || {
    rc=$?
    [ "$rc" -eq 1 ] || die "ext4 check before resize failed (exit $rc)"
}
resize2fs "$disk_img" >"$evidence_dir/resize2fs-disk-image.log" 2>&1 \
    || die "cannot expand the guest ext4 root to 16 GiB"
e2fsck -fy "$disk_img" >"$evidence_dir/e2fsck-resized-disk-image.log" 2>&1 || {
    rc=$?
    [ "$rc" -eq 1 ] || die "ext4 check after resize failed (exit $rc)"
}
printf 'logical_disk_bytes=%s\n' "$(stat -c %s "$disk_img")" >"$evidence_dir/disk-capacity.txt"
tune2fs -l "$disk_img" | grep -aE 'Filesystem features|Block size|Filesystem state' >"$evidence_dir/disk-ext4-features.txt"
rm -f "$raw"

# ---------------------------------------------------------------------------
step "5/9 cross-build the static riscv64 runner (+ relink object)"
# ---------------------------------------------------------------------------
make -C "$repo/FloeAgent/LinuxGuest/runner" riscv64 >"$evidence_dir/runner-build.log" 2>&1
cp "$repo/FloeAgent/LinuxGuest/runner/floe-exec-riscv64" "$runner_dir/floe-exec-riscv64"
riscv64-linux-gnu-gcc -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE \
    -static -I"$repo/FloeAgent/LinuxGuest/runner" \
    -c -o "$runner_dir/floe-exec-riscv64.o" "$runner_src" >"$evidence_dir/runner-object-build.log" 2>&1
{
    printf 'cross_cc=%s\n' "$(riscv64-linux-gnu-gcc --version | head -1)"
    printf 'link_command=riscv64-linux-gnu-gcc -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE -static -o floe-exec-riscv64 floe_exec.c\n'
    dpkg-query -W -f='toolchain_package ${binary:Package} ${Version}\n' \
        gcc-riscv64-linux-gnu libc6-dev-riscv64-cross binutils-riscv64-linux-gnu 2>/dev/null || true
    file "$runner_dir/floe-exec-riscv64"
    sha256sum "$runner_dir/floe-exec-riscv64" "$runner_dir/floe-exec-riscv64.o"
} >"$evidence_dir/runner-toolchain.txt"
file "$runner_dir/floe-exec-riscv64" | grep -q 'statically linked' || die "runner is not statically linked"
sha256sum "$runner_dir/floe-exec-riscv64" | tee "$evidence_dir/runner-sha256.txt"
# The compiled object is LGPL-2.1 §6 relink material: it must travel with the
# evidence bundle, not only in the ephemeral runner dir.
cp "$runner_dir/floe-exec-riscv64.o" "$evidence_dir/floe-exec-riscv64.o"

# ---------------------------------------------------------------------------
step "6/9 inject the runner into the image"
# ---------------------------------------------------------------------------
bash "$repo/FloeAgent/LinuxGuest/image/install-into-image.sh" \
    --image "$disk_img" \
    --runner "$runner_dir/floe-exec-riscv64" \
    --script "$repo/FloeAgent/LinuxGuest/image/floe-guest-init" \
    >"$evidence_dir/runner-injection.log" 2>&1
grep -q 'installed' "$evidence_dir/runner-injection.log" || die "runner injection did not report success"

# ---------------------------------------------------------------------------
step "7/9 provision A — install the recipe, then boot A checks it in-Guest"
# ---------------------------------------------------------------------------
cp "$repo/FloeAgent/LinuxGuest/image/guest-stage1-install.sh" "$share_dir/"
cp "$repo/FloeAgent/LinuxGuest/image/guest-stage1-coherence.sh" "$share_dir/"
cp "$repo/FloeAgent/LinuxGuest/image/guest-stage2-verify.sh" "$share_dir/"
cp "$repo/FloeAgent/LinuxGuest/image/guest-https-check.py" "$share_dir/"
cp "$repo/FloeAgent/LinuxGuest/image/guest-instruction-probe.py" "$share_dir/"
# The guest scripts read /floe/template-recipe.json on both boots; the same
# validated bytes that the manifest records by SHA-512.
cp "$recipe_path" "$share_dir/template-recipe.json"
chmod 0755 "$share_dir"/*.sh "$share_dir"/*.py

boot_guest() { # boot_guest <name> <guest-script> <token> <max-s>
    # The host exits when the runner's END frame for this token appears; that
    # frame is printed after the guest command finished, so the transcript is
    # guaranteed to contain the command's real output and its exit code.
    local name="$1" guest_script="$2" token="$3" max_s="$4"
    local epoch
    epoch="$(date +%s)"
    printf '%s\n' "$epoch" >"$share_dir/host-epoch.txt"
    local script_file="$work/boot-$name.txt"
    {
        printf '@20 '
        python3 "$repo/FloeAgent/LinuxGuest/image/make-exec-frame.py" --token "$token" --cwd=/ \
            -- /bin/sh -c "sh /floe/$guest_script"
        printf '\n'
    } >"$script_file"
    printf 'floe.epoch=%s\n' "$epoch" >"$evidence_dir/boot-$name-epoch.txt"
    step "boot $name: floe.epoch=$epoch until=FLOE-END $token max=${max_s}s"
    set +e
    timeout $((max_s + 300)) "$work/build/floe_vm_host" \
        --bios "$image_dir/bbl64.bin" \
        --kernel "$image_dir/kernel-riscv64.bin" \
        --disk "$disk_img" --rw \
        --ram "$ram_mb" \
        --cmdline "$cmdline init=/usr/local/bin/floe-exec floe.epoch=$epoch" \
        --net --share "floe=$share_dir" \
        --script "$script_file" \
        --transcript "$evidence_dir/boot-$name-transcript.txt" \
        --until "FLOE-END $token" \
        --max-s "$max_s" \
        >"$evidence_dir/boot-$name-stdout.txt" 2>&1
    local rc=$?
    set -e
    printf '%s\n' "$rc" >"$evidence_dir/boot-$name-rc.txt"
    printf 'boot %s rc=%s\n' "$name" "$rc"
    return "$rc"
}

assert_markers() { # assert_markers <transcript> <token> <markers...>
    local transcript="$1" token="$2"
    shift 2
    local failed=0
    grep -aq "FLOE-END $token 0" "$transcript" || { printf 'MISSING end frame: FLOE-END %s 0\n' "$token"; failed=1; }
    for marker in "$@"; do
        if grep -aq "$marker" "$transcript"; then
            printf 'seen: %s\n' "$marker"
        else
            printf 'MISSING: %s\n' "$marker"
            failed=1
        fi
    done
    if [ "$failed" != 0 ]; then
        printf '\n--- last 4000 bytes of %s ---\n' "$transcript" >&2
        tail -c 4000 "$transcript" >&2 || true
        return 1
    fi
    return 0
}

if [ "$provision" = "host" ]; then
    # Cloud-host acceleration (job-d56b526d441c4faa D3): the recipe install
    # runs in a qemu-user riscv64 chroot against this exact disk. Signed APT,
    # real dpkg scripts and the real package database are preserved; the
    # in-Guest boots below are the verification, never skipped.
    step "provision A: qemu-user chroot install of recipe '$template'"
    bash "$script_dir/host-provision-image.sh" \
        --image "$disk_img" \
        --recipe "$recipe_path" \
        --share "$share_dir" \
        --evidence "$evidence_dir" 2>&1 | tee "$evidence_dir/provision.log"
    # Hard gate on the real install facts before anything else may run.
    python3 - "$evidence_dir/template-install.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
apt = data.get("apt") or {}
pypi = data.get("pypi") or {}
problems = []
if apt.get("install_rc") != 0:
    problems.append("apt install_rc=%s" % apt.get("install_rc"))
if apt.get("missing"):
    problems.append("apt missing=%s" % apt.get("missing"))
if pypi.get("failures"):
    problems.append("pypi failures=%s" % pypi.get("failures"))
if problems:
    print("PROVISION GATE: " + "; ".join(problems))
    sys.exit(1)
print("PROVISION GATE: ok (apt install_rc=0, no missing packages, no pypi failures)")
PY
    cp "$share_dir/stage1-install.log" "$evidence_dir/" 2>/dev/null || true
    e2fsck -fy "$disk_img" >"$evidence_dir/e2fsck-after-provision.log" 2>&1 || true

    # Boot A (light): the provisioned image must boot under the real kernel and
    # present the installed state to the guest's own tools (dpkg + imports).
    boot_guest stage1 guest-stage1-coherence.sh bootA "$boot_max_s" || {
        cp "$share_dir/stage1-coherence.log" "$evidence_dir/" 2>/dev/null || true
        echo "boot A (coherence) did not reach its marker (rc above); keeping transcript" >&2
        exit 1
    }
    cp "$share_dir/stage1-coherence.log" "$evidence_dir/" 2>/dev/null || true
    cp "$share_dir/template-coherence.json" "$evidence_dir/" 2>/dev/null || true
    grep -aq 'clock set from floe.epoch=' "$evidence_dir/boot-stage1-transcript.txt" \
        || die "runner never reported setting the clock from floe.epoch="
    assert_markers "$evidence_dir/boot-stage1-transcript.txt" bootA \
        FLOE_STAGE1_CLOCK_OK FLOE_STAGE1_APT_UPDATE_RC_0 FLOE_STAGE1_TEMPLATE_COHERENT FLOE_STAGE1_DONE \
        || die "stage 1 (coherence) assertions failed"
    e2fsck -fy "$disk_img" >"$evidence_dir/e2fsck-after-stage1.log" 2>&1 || true
else
    boot_guest stage1 guest-stage1-install.sh bootA "$boot_max_s" || {
        # A slow package install can time out before the runner sends its END
        # frame. Preserve the guest's APT log on this path too; otherwise the
        # transcript stops at the last progress marker and hides the cause.
        cp "$share_dir/stage1-install.log" "$evidence_dir/" 2>/dev/null || true
        echo "boot A did not reach its marker (rc above); keeping transcript" >&2
        exit 1
    }
    # Preserve the guest's APT diagnostics even when the stage-1 assertion below
    # fails. The final evidence collection is unreachable on that path.
    cp "$share_dir/stage1-install.log" "$evidence_dir/" 2>/dev/null || true
    grep -aq 'clock set from floe.epoch=' "$evidence_dir/boot-stage1-transcript.txt" \
        || die "runner never reported setting the clock from floe.epoch="
    assert_markers "$evidence_dir/boot-stage1-transcript.txt" bootA \
        FLOE_STAGE1_CLOCK_OK FLOE_STAGE1_APT_UPDATE_RC_0 FLOE_STAGE1_APT_INSTALL_RC_0 FLOE_STAGE1_DONE \
        || die "stage 1 assertions failed"
    e2fsck -fy "$disk_img" >"$evidence_dir/e2fsck-after-stage1.log" 2>&1 || true
fi

# ---------------------------------------------------------------------------
step "8/9 boot B — verify clock, HTTPS APT, HTTPS and the 13 commands"
# ---------------------------------------------------------------------------
boot_guest stage2 guest-stage2-verify.sh bootB "$boot_max_s" || {
    cp "$share_dir/stage2-verify.log" "$evidence_dir/" 2>/dev/null || true
    echo "boot B did not reach its marker (rc above); keeping transcript" >&2
    exit 1
}
grep -aq 'clock set from floe.epoch=' "$evidence_dir/boot-stage2-transcript.txt" \
    || die "runner never reported setting the clock from floe.epoch= on the verification boot"
assert_markers "$evidence_dir/boot-stage2-transcript.txt" bootB \
    FLOE_STAGE2_CLOCK_OK FLOE_STAGE2_APT_UPDATE_RC_0 FLOE_STAGE2_PY_HTTPS_200 \
    FLOE_CMD_ps_OK FLOE_CMD_setsid_OK FLOE_CMD_nohup_OK FLOE_CMD_bash_OK \
    FLOE_CMD_zsh_OK FLOE_CMD_zip_OK FLOE_CMD_unzip_OK FLOE_CMD_7z_OK \
    FLOE_CMD_xz_OK FLOE_CMD_bzip2_OK FLOE_CMD_sqlite3_OK FLOE_CMD_ssh_OK \
    FLOE_CMD_scp_OK "FLOE_TEMPLATE_VERIFIED $template" FLOE_STAGE2_DONE \
    || die "stage 2 capability assertions failed (including template '$template')"
e2fsck -fy "$disk_img" >"$evidence_dir/e2fsck-after-stage2.log" 2>&1 || true
tune2fs -l "$disk_img" | grep -aE 'Filesystem features|Block size|Filesystem state' >"$evidence_dir/disk-ext4-features-final.txt"

# ---------------------------------------------------------------------------
step "9/9 collect evidence, write manifest.json and package the zip"
# ---------------------------------------------------------------------------
cp "$share_dir/guest-packages.tsv" "$evidence_dir/guest-packages.tsv" 2>/dev/null || true
cp "$share_dir/guest-dpkg-status.txt" "$evidence_dir/guest-dpkg-status.txt" 2>/dev/null || true
cp "$share_dir/stage1-install.log" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/stage2-verify.log" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/image-capability-report.txt" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/stage1-apt-update.log" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/stage1-apt-install.log" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/stage2-package-versions.txt" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/stage2-insns.out" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/template-install.json" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/template-verify.json" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/template-coherence.json" "$evidence_dir/" 2>/dev/null || true
cp "$share_dir/stage1-coherence.log" "$evidence_dir/" 2>/dev/null || true
cp "$recipe_path" "$evidence_dir/template-recipe.json" 2>/dev/null || true

mount -o ro,loop "$disk_img" "$mnt_dir"
dpkg-query --admindir="$mnt_dir/var/lib/dpkg" -W \
    -f='${binary:Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n' \
    >"$evidence_dir/guest-packages-host.tsv" 2>"$evidence_dir/dpkg-query-host.log" || true
cp "$mnt_dir/var/lib/dpkg/status" "$evidence_dir/guest-dpkg-status-host.txt" 2>/dev/null || true
( cd "$mnt_dir" && find usr/share/doc -name copyright -print0 2>/dev/null \
    | tar --null -T - -czf "$evidence_dir/guest-copyrights.tar.gz" ) 2>>"$evidence_dir/copyrights.log" || true
( cd "$mnt_dir" && tar -czf "$evidence_dir/guest-common-licenses.tar.gz" usr/share/common-licenses 2>>"$evidence_dir/copyrights.log" ) || true
if [ -f "$mnt_dir/etc/apt/sources.list.d/debian.sources" ]; then
    cp "$mnt_dir/etc/apt/sources.list.d/debian.sources" "$evidence_dir/guest-apt-debian.sources"
fi
umount "$mnt_dir"
sha512sum "$disk_img" >"$evidence_dir/disk-sha512.txt"
printf 'disk_bytes=%s\n' "$(stat -c %s "$disk_img")" >>"$evidence_dir/disk-sha512.txt"

qualified_flag=()
if [ "$claim_qualified" = 1 ]; then
    qualified_flag=(--qualified)
fi
evidence_text="component-image-ci boot A+B: runner PID1 clock from floe.epoch, signed HTTPS apt update/install, Python HTTPS 200, 13 user commands executed."
if [ "$provision" = "host" ]; then
    evidence_text="$evidence_text APT/PyPI provisioning ran on the cloud host in a qemu-user riscv64 chroot against the shipped ext4 (signed verification, real dpkg scripts/database; evidence provision-*.txt); boot A re-verified the provisioned state in-Guest (dpkg live + pinned imports), boot B is the full verification."
fi
if [ -n "$boot_dir" ]; then
    evidence_text="$evidence_text Unpinned boot pair from --boot-dir (locally built kernel/bbl); the 2018-pair capability run and its runtime claim do not apply to this image."
else
    evidence_text="$evidence_text Runtime capability on this exact kernel/bbl/userland was independently verified by tinyemu-linux-qualification run 35500083112 (APT/numpy/node/HTTPS)."
fi
python3 "$repo/FloeAgent/LinuxGuest/image/write-image-manifest.py" write \
    --image-dir "$image_dir" \
    --id "$image_id" \
    --bios "$image_dir/bbl64.bin" \
    --kernel "$image_dir/kernel-riscv64.bin" \
    --disk "$disk_img" \
    --cmdline "$cmdline" \
    --qualification-run "${run_url:-local-unpublished}" \
    --qualification-evidence "$evidence_text" \
    --source-url "https://github.com/JiangNanGenius/floe-agent/tree/${source_ref}/FloeAgent/LinuxGuest" \
    --build-configuration-url "https://github.com/JiangNanGenius/floe-agent/tree/${source_ref}/FloeAgent/ThirdParty/TinyEMU/guest-image" \
    --license "Floe runner MPL-2.0; guest userland under its own Debian package licenses; kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1" \
    --template-id "$template" \
    --template-recipe "$recipe_path" \
    --template-json "$evidence_dir/template-verify.json" \
    --template-install-json "$evidence_dir/template-install.json" \
    "${qualified_flag[@]+"${qualified_flag[@]}"}"
python3 "$repo/FloeAgent/LinuxGuest/image/write-image-manifest.py" verify --image-dir "$image_dir"

( cd "$image_dir" && sha512sum manifest.json bbl64.bin kernel-riscv64.bin disk.img >SHA512SUMS )

if [ "$make_zip" = 1 ]; then
    zip_path="$image_dir/floe-linux-guest-$image_id.zip"
    rm -f "$zip_path"
    ( cd "$image_dir" && zip -q "$(basename "$zip_path")" manifest.json bbl64.bin kernel-riscv64.bin disk.img )
    zip_bytes="$(stat -c %s "$zip_path")"
    [ "$zip_bytes" -le $((2 * 1024 * 1024 * 1024)) ] || die "zip exceeds the app import limit (2 GiB)"
    ( cd "$image_dir" && unzip -l "$(basename "$zip_path")" >"$evidence_dir/zip-listing.txt" )
    ( cd "$image_dir" && sha512sum "$(basename "$zip_path")" >"$evidence_dir/zip-sha512.txt" )
    printf 'zip=%s bytes=%s\n' "$zip_path" "$zip_bytes"
fi

{
    printf 'image_id=%s\n' "$image_id"
    printf 'template=%s\n' "$template"
    printf 'cmdline=%s init=/usr/local/bin/floe-exec floe.epoch=<boot epoch>\n' "$cmdline"
    printf 'qualified=%s\n' "$claim_qualified"
    printf 'bootA_rc=%s\n' "$(cat "$evidence_dir/boot-stage1-rc.txt")"
    printf 'bootB_rc=%s\n' "$(cat "$evidence_dir/boot-stage2-rc.txt")"
    printf 'runner_sha256=%s\n' "$(cut -d' ' -f1 "$evidence_dir/runner-sha256.txt")"
    printf 'disk_bytes=%s\n' "$(stat -c %s "$disk_img")"
} >"$evidence_dir/build-summary.txt"

step "done: image candidate in $image_dir, evidence in $evidence_dir"
