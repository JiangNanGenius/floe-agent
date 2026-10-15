#!/usr/bin/env bash
# profile_guest_bench.sh — sample the qualification host while the fixed guest
# benchmark runs, so the optimization hypothesis is based on a real profile.
#
# Usage (same inputs as run_guest_bench.sh):
#   FLOE_BENCH_WORK FLOE_BENCH_VMHOST FLOE_BENCH_DISK [FLOE_BENCH_RUNS=4] \
#   [FLOE_BENCH_SAMPLE_SECONDS=25] bash profile_guest_bench.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../.." && pwd)"

work="${FLOE_BENCH_WORK:?set FLOE_BENCH_WORK}"
vmhost="${FLOE_BENCH_VMHOST:?set FLOE_BENCH_VMHOST}"
disk="${FLOE_BENCH_DISK:?set FLOE_BENCH_DISK}"
runs="${FLOE_BENCH_RUNS:-4}"
sample_seconds="${FLOE_BENCH_SAMPLE_SECONDS:-25}"
bios="${FLOE_BENCH_BIOS:-$repo_root/FloeAgent/ThirdParty/TinyEMU/guest-image/bundled-boot-pair/opensbi_fw_jump.bin}"
kernel="${FLOE_BENCH_KERNEL:-$repo_root/FloeAgent/ThirdParty/TinyEMU/guest-image/bundled-boot-pair/kernel-6.18.56-riscv64.bin}"

share="$work/profile-share"
mkdir -p "$share"
cp "$here/guest_bench.py" "$share/guest_bench.py"

{
  echo "@10 echo PROFILE_BOOT_READY"
  echo "@12 mkdir -p /mnt && mount -t 9p -o trans=virtio,version=9p2000.L floe /mnt && echo PROFILE_MOUNT_OK"
  seconds=20
  for index in $(seq 1 "$runs"); do
    echo "@$seconds python3 -u /mnt/guest_bench.py /mnt profile$index"
    seconds=$((seconds + 240))
  done
  echo "@$seconds printf 'PROFILE_ALL_%s\\n' DONE"
} > "$work/profile-script.txt"

transcript="$work/profile-transcript.txt"
"$vmhost" \
  --bios "$bios" --kernel "$kernel" --disk "$disk" --rw \
  --share floe="$share" --ram "${FLOE_BENCH_RAM:-512}" \
  --cmdline "console=hvc0 root=/dev/vda rw init=/bin/sh earlycon=sbi" \
  --script "$work/profile-script.txt" \
  --transcript "$transcript" \
  --until PROFILE_ALL_DONE \
  --max-s "${FLOE_BENCH_MAX_S:-1800}" > "$work/profile-host.txt" 2>&1 &
host_pid=$!
echo "floe_vm_host pid=$host_pid"

# Wait until the guest really started the benchmark, then sample the emulator.
deadline=$((SECONDS + 300))
while [ $SECONDS -lt $deadline ]; do
  if grep -aq "BENCH_IDENTITY" "$transcript" 2>/dev/null; then break; fi
  sleep 2
done

sample "$host_pid" "$sample_seconds" -file "$work/profile-sample.txt" || true

wait "$host_pid" || true
echo "== profile complete =="
grep -a "^BENCH " "$transcript" | tail -10
