#!/usr/bin/env bash
# run_guest_bench.sh — run the fixed guest benchmark (bench/guest_bench.py)
# against a real TinyEMU guest on this host.
#
# Contract facts this script pins:
#   * the SAME engine source set the app builds (ThirdParty/TinyEMU vendored
#     patches applied by the adapter Makefile),
#   * the bundled 6.18.56 + OpenSBI boot pair,
#   * a TASK-OWNED writable disk copy (the original is never written),
#   * the fixed benchmark script (its sha256 is recorded; the script must be
#     byte-identical between the pre/post comparisons),
#   * raw transcripts + per-run `BENCH_JSON` lines kept for evidence.
#
# Usage:
#   FLOE_BENCH_WORK=<scratch> FLOE_BENCH_VMHOST=<floe_vm_host> \
#   FLOE_BENCH_DISK=<copy.img> [FLOE_BENCH_RUNS=3] bash run_guest_bench.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../.." && pwd)"

work="${FLOE_BENCH_WORK:?set FLOE_BENCH_WORK to a task-owned scratch dir}"
vmhost="${FLOE_BENCH_VMHOST:?set FLOE_BENCH_VMHOST to the built floe_vm_host}"
disk="${FLOE_BENCH_DISK:?set FLOE_BENCH_DISK to a task-owned writable disk copy}"
runs="${FLOE_BENCH_RUNS:-3}"
ram="${FLOE_BENCH_RAM:-512}"
max_s="${FLOE_BENCH_MAX_S:-3600}"

bios="${FLOE_BENCH_BIOS:-$repo_root/FloeAgent/ThirdParty/TinyEMU/guest-image/bundled-boot-pair/opensbi_fw_jump.bin}"
kernel="${FLOE_BENCH_KERNEL:-$repo_root/FloeAgent/ThirdParty/TinyEMU/guest-image/bundled-boot-pair/kernel-6.18.56-riscv64.bin}"

for file in "$vmhost" "$disk" "$bios" "$kernel" "$here/guest_bench.py"; do
  if [ ! -f "$file" ]; then
    echo "missing input: $file" >&2
    exit 2
  fi
done

share="$work/share"
mkdir -p "$share"
cp "$here/guest_bench.py" "$share/guest_bench.py"

# One console command per benchmark run, plus the terminal marker the host
# waits for. `python3 -u` keeps the structured lines unbuffered.
{
  echo "@10 echo BENCH_BOOT_READY"
  echo "@12 mkdir -p /mnt && mount -t 9p -o trans=virtio,version=9p2000.L floe /mnt && echo BENCH_MOUNT_OK"
  echo "@14 ls /mnt/guest_bench.py >/dev/null && echo BENCH_SCRIPT_VISIBLE"
seconds=20
spacing="${FLOE_BENCH_SPACING:-600}"
for index in $(seq 1 "$runs"); do
  echo "@$seconds python3 -u /mnt/guest_bench.py /mnt run$index"
  seconds=$((seconds + spacing))
done
  echo "@$seconds printf 'BENCH_ALL_%s\\n' DONE"
} > "$work/bench-script.txt"

echo "== bench script sha256 =="
shasum -a 256 "$here/guest_bench.py" | tee "$work/guest_bench.py.sha256"
echo "== engine/boot inputs =="
shasum -a 256 "$bios" "$kernel" | tee "$work/boot-assets.sha256"
shasum -a 256 "$vmhost" | tee "$work/floe_vm_host.sha256"
echo "== host facts =="
{
  sysctl -n machdep.cpu.brand_string 2>/dev/null || true
  sysctl -n hw.ncpu hw.memsize 2>/dev/null || true
  uname -a
} | tee "$work/host-facts.txt"

transcript="$work/bench-transcript.txt"
started=$(date +%s)
"$vmhost" \
  --bios "$bios" \
  --kernel "$kernel" \
  --disk "$disk" \
  --rw \
  --share floe="$share" \
  --ram "$ram" \
  --cmdline "console=hvc0 root=/dev/vda rw init=/bin/sh earlycon=sbi" \
  --script "$work/bench-script.txt" \
  --transcript "$transcript" \
  --until BENCH_ALL_DONE \
  --max-s "$max_s" | tee "$work/bench-host.txt"
finished=$(date +%s)
echo "wall_seconds=$((finished - started))" | tee "$work/bench-wall.txt"

echo "== BENCH results =="
grep -a "^BENCH_JSON " "$transcript" | sed 's/^BENCH_JSON //' | tee "$work/bench-json-lines.txt"
grep -a "BENCH_ALL_DONE" "$transcript" >/dev/null
echo "== guest bench complete =="
