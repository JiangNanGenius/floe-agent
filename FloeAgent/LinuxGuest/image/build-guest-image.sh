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
#   7. boot A: the runner is PID 1, consumes `floe.epoch=`, installs the
#      packages over signed HTTPS APT, exports the package inventory;
#   8. boot B: fresh `floe.epoch=`, re-checks the clock, signed HTTPS APT,
#      Python HTTPS with default CA verification, and runs the 13 user-facing
#      commands the feedback report listed (ps setsid nohup bash zsh zip unzip
#      7z xz bzip2 sqlite3 ssh scp) as real operations;
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
#   --image-id ID         manifest id (default: derived from the Debian build)
#   --run-url URL         qualification run URL recorded in the manifest
#   --source-ref REF      git commit recorded in the provenance source URLs
#   --skip-fetch          reuse already-downloaded sources/images
#   --skip-engine         reuse an existing engine build in <work>/build
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

work=""
repo=""
pins=""
image_id=""
run_url=""
source_ref=""
skip_fetch=0
skip_engine=0
boot_max_s=2700
ram_mb=1024
make_zip=1
claim_qualified=1

while [ $# -gt 0 ]; do
    case "$1" in
        --work) work="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --pins) pins="${2:-}"; shift 2 ;;
        --image-id) image_id="${2:-}"; shift 2 ;;
        --run-url) run_url="${2:-}"; shift 2 ;;
        --source-ref) source_ref="${2:-}"; shift 2 ;;
        --skip-fetch) skip_fetch=1; shift ;;
        --skip-engine) skip_engine=1; shift ;;
        --boot-max-s) boot_max_s="${2:-}"; shift 2 ;;
        --ram) ram_mb="${2:-}"; shift 2 ;;
        --no-zip) make_zip=0; shift ;;
        --skip-qualified) claim_qualified=0; shift ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$work" ] || die "--work is required"
[ "$(uname -s)" = "Linux" ] || die "this script needs Linux loop mounts"
[ "$(id -u)" = "0" ] || die "run as root (losetup/mount are required)"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${repo:-$(cd "$script_dir/../../.." && pwd)}"
pins="${pins:-$repo/FloeAgent/ThirdParty/TinyEMU/guest-image/pinned-inputs.json}"
image_dir="$work/image"
evidence_dir="$work/evidence"
share_dir="$work/share9p"
runner_dir="$work/runner"
mnt_dir="$work/mnt"

for tool in curl python3 parted e2fsck tune2fs losetup mount dd qemu-img sha512sum sha256sum make gcc zip unzip; do
    command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
[ -f "$pins" ] || die "pinned inputs not found: $pins"
mkdir -p "$work" "$image_dir" "$evidence_dir" "$share_dir" "$runner_dir" "$mnt_dir"

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
image_id="${image_id:-floe-debian13-riscv64-$(printf '%s' "$daily_build" | tr -d '-')}"
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
[ -d "$demo_dir" ] || die "demo archive missing (fetch failed?)"
[ "$(sha256sum "$work/src/tinyemu-2019-12-21.tar.gz" | cut -d' ' -f1)" = "$engine_sha" ] \
    || die "tinyemu-2019-12-21.tar.gz does not match the pinned sha256"
[ "$(sha256sum "$work/src/diskimage-linux-riscv-2018-09-23.tar.gz" | cut -d' ' -f1)" = "$demo_sha" ] \
    || die "diskimage-linux-riscv-2018-09-23.tar.gz does not match the pinned sha256"
printf 'engine_url=%s\nengine_sha256=%s\ndemo_sha256=%s\n' "$engine_url" "$engine_sha" "$demo_sha" \
    >"$evidence_dir/input-pins.txt"
[ "$(sha256sum "$demo_dir/bbl64.bin" | cut -d' ' -f1)" = "$bios_sha" ] || die "bbl64.bin does not match the pinned sha256"
[ "$(sha256sum "$demo_dir/kernel-riscv64.bin" | cut -d' ' -f1)" = "$kernel_sha" ] || die "kernel-riscv64.bin does not match the pinned sha256"
cp "$demo_dir/bbl64.bin" "$image_dir/bbl64.bin"
cp "$demo_dir/kernel-riscv64.bin" "$image_dir/kernel-riscv64.bin"
printf 'bbl64.bin bytes=%s sha256=%s\nkernel-riscv64.bin bytes=%s sha256=%s\n' \
    "$bios_bytes" "$bios_sha" "$kernel_bytes" "$kernel_sha" >"$evidence_dir/bios-kernel-pins.txt"

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
e2fsck -fy "$disk_img" >"$evidence_dir/e2fsck-disk-image.log" 2>&1 || true
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
step "7/9 boot A — install the capability packages through the runner"
# ---------------------------------------------------------------------------
cp "$repo/FloeAgent/LinuxGuest/image/guest-stage1-install.sh" "$share_dir/"
cp "$repo/FloeAgent/LinuxGuest/image/guest-stage2-verify.sh" "$share_dir/"
cp "$repo/FloeAgent/LinuxGuest/image/guest-https-check.py" "$share_dir/"
cp "$repo/FloeAgent/LinuxGuest/image/guest-instruction-probe.py" "$share_dir/"
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

boot_guest stage1 guest-stage1-install.sh bootA "$boot_max_s" || {
    echo "boot A did not reach its marker (rc above); keeping transcript" >&2
    exit 1
}
grep -aq 'clock set from floe.epoch=' "$evidence_dir/boot-stage1-transcript.txt" \
    || die "runner never reported setting the clock from floe.epoch="
assert_markers "$evidence_dir/boot-stage1-transcript.txt" bootA \
    FLOE_STAGE1_CLOCK_OK FLOE_STAGE1_APT_UPDATE_RC_0 FLOE_STAGE1_APT_INSTALL_RC_0 FLOE_STAGE1_DONE \
    || die "stage 1 assertions failed"
e2fsck -fy "$disk_img" >"$evidence_dir/e2fsck-after-stage1.log" 2>&1 || true

# ---------------------------------------------------------------------------
step "8/9 boot B — verify clock, HTTPS APT, HTTPS and the 13 commands"
# ---------------------------------------------------------------------------
boot_guest stage2 guest-stage2-verify.sh bootB "$boot_max_s" || {
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
    FLOE_CMD_scp_OK FLOE_STAGE2_DONE \
    || die "stage 2 capability assertions failed"
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
evidence_text="component-image-ci boot A+B: runner PID1 clock from floe.epoch, signed HTTPS apt update/install, Python HTTPS 200, 13 user commands executed. Runtime capability on this exact kernel/bbl/userland was independently verified by tinyemu-linux-qualification run 35500083112 (APT/numpy/node/HTTPS)."
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
    printf 'cmdline=%s init=/usr/local/bin/floe-exec floe.epoch=<boot epoch>\n' "$cmdline"
    printf 'qualified=%s\n' "$claim_qualified"
    printf 'bootA_rc=%s\n' "$(cat "$evidence_dir/boot-stage1-rc.txt")"
    printf 'bootB_rc=%s\n' "$(cat "$evidence_dir/boot-stage2-rc.txt")"
    printf 'runner_sha256=%s\n' "$(cut -d' ' -f1 "$evidence_dir/runner-sha256.txt")"
    printf 'disk_bytes=%s\n' "$(stat -c %s "$disk_img")"
} >"$evidence_dir/build-summary.txt"

step "done: image candidate in $image_dir, evidence in $evidence_dir"
