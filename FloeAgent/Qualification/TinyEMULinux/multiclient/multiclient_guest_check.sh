#!/usr/bin/env bash
# multiclient_guest_check.sh — run the multiclient harness against a REAL
# TinyEMU guest: the pinned production image boots its own runner
# (`/usr/local/bin/floe-exec`) as PID 1 and `mc_guest_bridge` exposes that
# guest console on stdin/stdout, so the production `LinuxGuestCommandChannel`
# drives the actual guest (real kernel, real fork/exec, real PTYs, real exit
# statuses) with the same scenarios as the host-process check.
#
# Required env:
#   FLOE_MC_BRIDGE     path to the built mc_guest_bridge binary
#   FLOE_MC_IMAGE_DIR  directory containing the pinned image's manifest.json,
#                      bbl64.bin, kernel-riscv64.bin and disk.img
# Optional env:
#   FLOE_MC_SCRATCH    scratch dir (default: mktemp -d under $TMPDIR)
#   FLOE_MC_KEEP       1 = keep the scratch dir
#   FLOE_MC_DISK       writable disk copy to use (default: a fresh APFS clone
#                      of $FLOE_MC_IMAGE_DIR/disk.img in the scratch dir; the
#                      pinned original is never opened read-write)
#   FLOE_MC_RAM        guest RAM MB (default 512)
#   FLOE_MC_VCPU       hart count (default 1)
#
# The guest work root is /floe/mc-work; the bridge exports its host backing
# directory (the scratch dir) as the guest's `floe` 9p share.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bridge="${FLOE_MC_BRIDGE:?set FLOE_MC_BRIDGE to the built mc_guest_bridge}"
image_dir="${FLOE_MC_IMAGE_DIR:?set FLOE_MC_IMAGE_DIR to the pinned image dir}"
for f in "$bridge" "$image_dir/manifest.json" "$image_dir/bbl64.bin" \
         "$image_dir/kernel-riscv64.bin" "$image_dir/disk.img"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 2; }
done

if [ -n "${FLOE_MC_SCRATCH:-}" ]; then
  scratch="$FLOE_MC_SCRATCH"
  mkdir -p "$scratch"
else
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/floe-mc-guest.XXXXXX")"
fi

disk="${FLOE_MC_DISK:-$scratch/disk-guest-check.img}"
if [ ! -f "$disk" ]; then
  # APFS clone when possible: instant and copy-on-write, so the pinned image
  # is never written and each run starts from the same bytes.
  cp -c "$image_dir/disk.img" "$disk" 2>/dev/null || cp "$image_dir/disk.img" "$disk"
fi

echo "==> real-guest multiclient check"
echo "    bridge:  $bridge"
echo "    image:   $image_dir"
echo "    disk:    $disk"
echo "    scratch: $scratch"

export FLOE_MC_RUNNER="$bridge"
export FLOE_MC_GUEST_WORK_ROOT="/floe/mc-work"
export FLOE_MC_HOST_WORK_ROOT="$scratch/mc-work"
export FLOE_MC_BRIDGE_BIOS="$image_dir/bbl64.bin"
export FLOE_MC_BRIDGE_KERNEL="$image_dir/kernel-riscv64.bin"
export FLOE_MC_BRIDGE_DISK="$disk"
export FLOE_MC_BRIDGE_SHARE_DIR="$scratch"
export FLOE_MC_BRIDGE_RAM="${FLOE_MC_RAM:-512}"
export FLOE_MC_BRIDGE_VCPU="${FLOE_MC_VCPU:-1}"
export FLOE_MC_BRIDGE_MAX_S="${FLOE_MC_BRIDGE_MAX_S:-900}"

FLOE_MC_SCRATCH="$scratch" FLOE_MC_KEEP="${FLOE_MC_KEEP:-1}" \
  bash "$here/multiclient_host_check.sh"
