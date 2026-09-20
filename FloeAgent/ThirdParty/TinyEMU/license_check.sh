#!/bin/bash
# license_check.sh — host-side GPL gate for the Floe TinyEMU engine build.
# Fails if any GPL/LGPL-licensed marker appears in the sources that the
# embeddable build actually compiles. Read-only.
#
#   license_check.sh <tinyemu_source_dir>
set -euo pipefail
SRC="${1:?usage: license_check.sh <tinyemu_source_dir>}"

# exact source list mirrored from adapter/Makefile
CORE="virtio.c pci.c fs.c cutils.c iomem.c simplefb.c json.c machine.c fs_disk.c riscv_machine.c softfp.c riscv_cpu.c"
SLIRP="bootp.c ip_icmp.c mbuf.c slirp.c tcp_output.c cksum.c ip_input.c misc.c socket.c tcp_subr.c udp.c if.c ip_output.c sbuf.c tcp_input.c tcp_timer.c"
HDRS="cutils.h iomem.h virtio.h machine.h fs.h list.h riscv_cpu.h riscv_cpu_priv.h riscv_cpu_template.h riscv_cpu_fp_template.h softfp.h softfp_template.h softfp_template_icvt.h json.h pci.h fs_disk.c"

fail=0
check() {
  local f="$1"
  if [ ! -f "$f" ]; then echo "WARN: missing $f"; return; fi
  if grep -qiE "GNU GENERAL PUBLIC LICENSE|GNU LESSER GENERAL PUBLIC LICENSE|GPLv[23]|LGPL" "$f"; then
    echo "GPL-GATE FAIL: $f"; fail=1
  fi
}
for f in $CORE $HDRS; do check "$SRC/$f"; done
for f in $SLIRP; do check "$SRC/slirp/$f"; done

if [ "$fail" = "0" ]; then
  echo "GPL-GATE OK: no GPL/LGPL markers in engine build sources"
else
  exit 1
fi
