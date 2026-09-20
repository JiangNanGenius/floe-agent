#!/usr/bin/env python3
"""guest-instruction-probe.py — execute one RISC-V instruction word per child
process and report the outcome.

This is the direct CPU probe used during the APT SIGILL investigation: Debian's
libapt-pkg executes FENCE.TSO (0x8330000f), which upstream TinyEMU trapped as
illegal. The probe executes each candidate word in its own subprocess so a
SIGILL is reported as SIG4 instead of killing the parent.

It is diagnostic evidence, not a product gate. If the probe result disagrees
with an independent capability that exercises the same hardware path (for
example a signed HTTPS `apt-get update`, which really executes libapt-pkg),
record both observations and investigate the specific contradiction: a
working apt does not by itself prove every encoding is handled, and a single
probe child does not by itself prove a product defect. Report only the actual
observed status; never describe a probe as passing unless its line says OK.

Output lines (one per word):
    FLOE_INSN_fence_tso=OK
    FLOE_INSN_fence_tso_rs1_3=SIG4
    ...
"""
import subprocess
import sys

WORDS = [
    ("fence_tso", 0x8330000F),
    ("fence_tso_rs1_3", 0x8333000F),
    ("fence_rw_rw", 0x0FF0000F),
    ("pause", 0x0100000F),
    ("fence_plain", 0x0000000F),
    ("fence_i", 0x0000100F),
]

# The instruction bytes followed by `ret` (jalr x0, 0(x1) = 0x00008067, which
# is bytes 67 80 00 00 in little-endian memory order). mmap PROT_EXEC is the
# same mechanism the qualification harness used.
PROBE = r"""
import ctypes, mmap, sys
w = int(sys.argv[1], 16)
insn = bytes([w & 0xff, (w >> 8) & 0xff, (w >> 16) & 0xff, (w >> 24) & 0xff])
m = mmap.mmap(-1, 4096, prot=mmap.PROT_READ | mmap.PROT_WRITE | mmap.PROT_EXEC)
m.write(insn + b"\x67\x80\x00\x00")
fn = ctypes.CFUNCTYPE(None)(ctypes.addressof(ctypes.c_char.from_buffer(m)))
fn()
"""


def main():
    for name, word in WORDS:
        result = subprocess.run(
            [sys.executable, "-c", PROBE, hex(word)],
            capture_output=True,
        )
        if result.returncode == 0:
            status = "OK"
        elif result.returncode < 0:
            status = "SIG%d" % (-result.returncode)
        else:
            status = "FAIL_%d" % result.returncode
        print("FLOE_INSN_%s=%s" % (name, status))
        if result.stderr:
            detail = result.stderr.decode("utf-8", "replace").strip().replace("\n", " ")
            print("  stderr=%s" % detail[:200])
    return 0


if __name__ == "__main__":
    sys.exit(main())
