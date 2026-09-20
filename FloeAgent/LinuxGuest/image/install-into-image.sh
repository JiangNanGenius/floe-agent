#!/usr/bin/env bash
# install-into-image.sh — inject the Floe guest runner into a whole-disk ext4
# guest image (the Debian 13 riscv64 rootfs the qualification workflow builds).
#
# Usage (Linux, root):
#   make -C FloeAgent/LinuxGuest/runner riscv64
#   sudo bash FloeAgent/LinuxGuest/image/install-into-image.sh \
#       --image Local/Private/tinyemu-qualification/work/debian13-rootfs.img \
#       --runner FloeAgent/LinuxGuest/runner/floe-exec-riscv64
#
# Optional:
#   --script <floe-guest-init>   install the startup/mount script too
#   --dry-run                    print the plan and hashes, change nothing
#
# Installed paths (also in FloeAgent/LinuxGuest/README.md):
#   /usr/local/bin/floe-exec                 0755 root:root  (static riscv64)
#   /usr/local/lib/floe/floe-guest-init      0755 root:root  (optional)
#
# The image is mounted read-write through a loop device, so the caller must be
# root and the image must be the whole-disk ext4 (no partition table): the
# 2018 demo kernel cannot parse GPT.
set -euo pipefail

image=""
runner=""
script=""
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --image) image="${2:-}"; shift 2 ;;
    --runner) runner="${2:-}"; shift 2 ;;
    --script) script="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$image" ] || [ -z "$runner" ]; then
  echo "usage: sudo bash $0 --image <rootfs.ext4> --runner <floe-exec-riscv64> [--script <floe-guest-init>] [--dry-run]" >&2
  exit 2
fi
if [ ! -f "$image" ]; then
  echo "guest image not found: $image" >&2
  exit 2
fi
if [ ! -f "$runner" ]; then
  echo "runner binary not found: $runner" >&2
  echo "build it first: make -C FloeAgent/LinuxGuest/runner riscv64" >&2
  exit 2
fi
if [ -n "$script" ] && [ ! -f "$script" ]; then
  echo "init script not found: $script" >&2
  exit 2
fi

# Portable helpers so --dry-run also works on the developer Mac.
file_size() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1"
}
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

echo "image:  $image ($(file_size "$image") bytes, sha256 $(file_sha256 "$image"))"
echo "runner: $runner ($(file_size "$runner") bytes, sha256 $(file_sha256 "$runner"))"
if [ -n "$script" ]; then
  echo "script: $script (sha256 $(file_sha256 "$script"))"
fi
echo "plan:"
echo "  /usr/local/bin/floe-exec              <- $runner"
if [ -n "$script" ]; then
  echo "  /usr/local/lib/floe/floe-guest-init   <- $script"
fi
echo "  kernel cmdline: console=hvc0 root=/dev/vda rw init=/usr/local/bin/floe-exec"

if [ "$dry_run" = "1" ]; then
  echo "dry-run: nothing changed"
  exit 0
fi

if [ "$(uname -s)" != "Linux" ]; then
  echo "this injector needs Linux loop mounts (run it in the qualification CI)" >&2
  exit 2
fi
if [ "$(id -u)" != "0" ]; then
  echo "must run as root to mount the image" >&2
  exit 2
fi

mount_dir="$(mktemp -d /tmp/floe-guest-image.XXXXXX)"
loop_device=""
cleanup() {
  if mountpoint -q "$mount_dir" 2>/dev/null; then
    umount "$mount_dir" || true
  fi
  if [ -n "$loop_device" ]; then
    losetup -d "$loop_device" || true
  fi
  rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT

loop_device="$(losetup --find --show "$image")"
mount "$loop_device" "$mount_dir"

install -D -m 0755 -o root -g root "$runner" "$mount_dir/usr/local/bin/floe-exec"
if [ -n "$script" ]; then
  install -D -m 0755 -o root -g root "$script" "$mount_dir/usr/local/lib/floe/floe-guest-init"
fi

echo "installed:"
ls -l "$mount_dir/usr/local/bin/floe-exec"
if [ -n "$script" ]; then
  ls -l "$mount_dir/usr/local/lib/floe/floe-guest-init"
fi
echo "after-injection sha256:"
file_sha256 "$mount_dir/usr/local/bin/floe-exec"
if [ -n "$script" ]; then
  file_sha256 "$mount_dir/usr/local/lib/floe/floe-guest-init"
fi

umount "$mount_dir"
losetup -d "$loop_device"
loop_device=""
