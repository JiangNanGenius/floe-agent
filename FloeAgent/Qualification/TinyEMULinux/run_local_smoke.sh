#!/bin/bash
# run_local_smoke.sh — reproduce the local TinyEMU qualification smoke:
#   fetch pinned sources -> build embeddable core + host -> real boot ->
#   console commands -> 9p host-share write -> slirp ping/TCP -> evidence.
#
#   cd FloeAgent/Qualification/TinyEMULinux
#   ./run_local_smoke.sh [workdir]        # workdir default: ./out
#   MACOS=1 ./run_local_smoke.sh          # macOS host build shims
#
# Disk footprint: ~40 MB. No root needed. Nothing outside workdir is
# modified (except the guest writes one file into workdir/share9p).
#
# Marker protocol: guest scripts assemble every marker at runtime
# (echo X_$((6*7)), printf 'X_%s' OK) and --until uses the same assembled
# form, so a TTY echo of the input line can never be mistaken for the
# guest having executed the command (this happened once in CI; see
# .github/workflows/tinyemu-linux-qualification.yml header).
set -euo pipefail
cd "$(dirname "$0")"
WORK="${1:-out}"
TP="../../ThirdParty/TinyEMU"

mkdir -p "$WORK/share9p"
bash "$TP/fetch_source.sh" "$WORK/src"

echo "== GPL gate =="
bash "$TP/license_check.sh" "$WORK/src/tinyemu-2019-12-21"

echo "== build =="
make -f "$TP/adapter/Makefile" TINYEMU_SRC="$WORK/src/tinyemu-2019-12-21" \
     PATCH_DIR="$TP/patches" BUILD="$WORK/build" HOST_DIR=. \
     ${MACOS:+MACOS=1} -j2

echo "== lifecycle regression =="
IMG="$WORK/src/diskimage-linux-riscv-2018-09-23"
"$WORK/build/lifecycle_test" "$IMG/bbl64.bin" "$IMG/kernel-riscv64.bin" \
    "$IMG/root-riscv64.bin" "$WORK/share9p" | tee "$WORK/lifecycle.txt"
grep -a LIFECYCLE_OK "$WORK/lifecycle.txt"

cat > "$WORK/script.txt" <<'EOF'
@6 uname -a
@8 echo FLOE_SMOKE_OK_$((6*7))
@10 mount -t 9p -o trans=virtio,version=9p2000.L /dev/root /mnt
@12 echo floe-9p-proof > /mnt/floe_smoke_9p.txt && printf 'FLOE_SMOKE_9P_%s\n' OK
@14 ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up
@16 ping -c 1 -W 3 10.0.2.2 && printf 'FLOE_SMOKE_PING_%s\n' OK
@20 printf 'FLOE_SMOKE_%s\n' DONE
EOF

echo "== boot (embeddable API host) =="
set +e
"$WORK/build/floe_vm_host" \
  --bios "$IMG/bbl64.bin" --kernel "$IMG/kernel-riscv64.bin" \
  --disk "$IMG/root-riscv64.bin" --share /dev/root="$WORK/share9p" --net \
  --ram 128 --script "$WORK/script.txt" \
  --transcript "$WORK/smoke-transcript.txt" \
  --until FLOE_SMOKE_DONE --max-s 90
rc=$?
set -e

echo "== evidence =="
miss=0
for m in FLOE_SMOKE_OK_42 FLOE_SMOKE_9P_OK FLOE_SMOKE_PING_OK; do
  if grep -qa "$m" "$WORK/smoke-transcript.txt"; then
    echo "marker seen: $m"
  else
    echo "marker MISSING: $m"; miss=1
  fi
done
if [ -f "$WORK/share9p/floe_smoke_9p.txt" ]; then
  echo "9p host-share file present: $(cat "$WORK/share9p/floe_smoke_9p.txt")"
else
  echo "9p host-share file MISSING"; miss=1
fi
[ "$rc" -eq 0 ] || miss=1
[ "$miss" -eq 0 ] || rc=3
echo "smoke exit: $rc (0 = boot exited on the assembled marker and all checks passed)"
exit $rc
