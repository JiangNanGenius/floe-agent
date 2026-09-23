#!/usr/bin/env python3
"""gen_smp_payload.py — build the RISC-V M-mode test payloads for the
Floe TinyEMU SMP host tests, without needing a RISC-V toolchain.

Outputs (flat binaries loaded by the adapter as the BIOS image at
0x80000000; the stock reset ROM enters them in M-mode with a0=mhartid,
a1=ROM-computed dtb pointer):

  smp_test.bin    dual-hart functional test (also runs in UP mode when
                  only hart 0 exists: prints UP-OK and powers off)
  perf_dual.bin   both harts run a fixed ALU loop (vcpu_count=2 run)
  perf_single.bin hart 0 runs 2x the same loop (vcpu_count=1 run)

The payload prints results over the HTIF console (device 1 cmd 1) and
requests poweroff with tohost=1. See smp_host_test.c for the harness.
"""

import struct
import sys

REGS = {f"x{i}": i for i in range(32)}
REGS.update({
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7, "s0": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15,
    "a6": 16, "a7": 17, "s2": 18, "s3": 19, "s4": 20, "s5": 21,
    "s6": 22, "s7": 23, "s8": 24, "s9": 25, "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
})


def R(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def I(imm, rs1, f3, rd, op):
    # The 12-bit immediate field is signed. Silently wrapping here once
    # sent an l1[0x100] page-table store (offset 0x800) to 0x80060800
    # instead of 0x80061800, which looked like an engine translation
    # fault. Callers must use li(base+off) + offset 0 for large offsets.
    # NOTE: the 12-bit field is signed for load/jalr immediates but the
    # CSR number for system instructions (0xF14 etc.), so the range check
    # lives in the load/store helpers below.
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def S(imm, rs2, rs1, f3, op):
    assert -2048 <= imm <= 2047, f"S-type imm {imm:#x} out of range"
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | ((imm & 0x1F) << 7) | op


def B(imm, rs2, rs1, f3, op):
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op


def U(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def J(imm, rd, op):
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | op


class Asm:
    def __init__(self):
        self.code = []      # list of 32-bit words
        self.data = bytearray()
        self.labels = {}    # name -> byte offset in blob
        self.fix = []       # (code_index, target, kind, extra)

    # ---- layout helpers -------------------------------------------------
    def label(self, name):
        self.labels[name] = len(self.code) * 4

    def dlabel(self, name):
        self.labels[name] = len(self.code) * 4 + len(self.data)

    def asciz(self, s):
        off = len(self.code) * 4 + len(self.data)
        self.data += s.encode() + b"\x00"
        return off

    def emit(self, w):
        self.code.append(w & 0xFFFFFFFF)

    # ---- fixup-based instructions ---------------------------------------
    def la(self, rd, target):
        # auipc rd, hi20; addi rd, rd, lo12  (target = label or abs addr)
        idx = len(self.code)
        self.emit(0)
        self.emit(0)
        self.fix.append((idx, target, "la", rd))

    def call(self, target):
        self.jal("ra", target)

    def j(self, target):
        self.jal("zero", target)

    def jal(self, rd, target):
        idx = len(self.code)
        self.emit(0)
        self.fix.append((idx, target, "jal", rd))

    def b(self, name, rs1, rs2, target):
        idx = len(self.code)
        self.emit(0)
        self.fix.append((idx, target, name, (rs1, rs2)))

    # ---- real instructions ----------------------------------------------
    def _r(self, name):
        return REGS[name]

    def addi(self, rd, rs1, imm):
        self.emit(I(imm, self._r(rs1), 0, self._r(rd), 0x13))

    def xori(self, rd, rs1, imm):
        self.emit(I(imm, self._r(rs1), 4, self._r(rd), 0x13))

    def ori(self, rd, rs1, imm):
        self.emit(I(imm, self._r(rs1), 6, self._r(rd), 0x13))

    def andi(self, rd, rs1, imm):
        self.emit(I(imm, self._r(rs1), 7, self._r(rd), 0x13))

    def slli(self, rd, rs1, sh):
        self.emit(I(sh & 0x3F, self._r(rs1), 1, self._r(rd), 0x13))

    def srli(self, rd, rs1, sh):
        self.emit(I(sh & 0x3F, self._r(rs1), 5, self._r(rd), 0x13))

    def add(self, rd, rs1, rs2):
        self.emit(R(0, self._r(rs2), self._r(rs1), 0, self._r(rd), 0x33))

    def sub(self, rd, rs1, rs2):
        self.emit(R(0x20, self._r(rs2), self._r(rs1), 0, self._r(rd), 0x33))

    def xor(self, rd, rs1, rs2):
        self.emit(R(0, self._r(rs2), self._r(rs1), 4, self._r(rd), 0x33))

    def or_(self, rd, rs1, rs2):
        self.emit(R(0, self._r(rs2), self._r(rs1), 6, self._r(rd), 0x33))

    def and_(self, rd, rs1, rs2):
        self.emit(R(0, self._r(rs2), self._r(rs1), 7, self._r(rd), 0x33))

    def mv(self, rd, rs):
        self.addi(rd, rs, 0)

    def li(self, rd, val):
        val &= 0xFFFFFFFFFFFFFFFF
        if val <= 0x7FFFFFFF:
            if val <= 2047:
                self.addi(rd, "zero", val)
            else:
                hi = (val + 0x800) >> 12
                lo = val - (hi << 12)
                self.emit(U(hi, self._r(rd), 0x37))   # lui
                if lo:
                    self.addi(rd, rd, lo)
        else:
            # 32-bit constant with bit31 set: zero-extend explicitly
            hi = (val + 0x800) >> 12
            lo = val - (hi << 12)
            self.emit(U(hi, self._r(rd), 0x37))
            if lo:
                self.addi(rd, rd, lo)
            self.slli(rd, rd, 32)
            self.srli(rd, rd, 32)

    def lui(self, rd, imm20):
        self.emit(U(imm20, self._r(rd), 0x37))

    def auipc(self, rd, imm20):
        self.emit(U(imm20, self._r(rd), 0x17))

    def _soff(self, imm, what):
        # 12-bit signed load/store offset; use li(base + off) + offset 0 for
        # large offsets (a silent wrap here once moved an l1[0x100] page
        # table store from 0x80061800 to 0x80060800).
        assert -2048 <= imm <= 2047, f"{what} offset {imm:#x} out of range"
        return imm

    def lw(self, rd, rs1, imm):
        self.emit(I(self._soff(imm, "lw"), self._r(rs1), 2, self._r(rd), 0x03))

    def ld(self, rd, rs1, imm):
        self.emit(I(self._soff(imm, "ld"), self._r(rs1), 3, self._r(rd), 0x03))

    def lbu(self, rd, rs1, imm):
        self.emit(I(self._soff(imm, "lbu"), self._r(rs1), 4, self._r(rd), 0x03))

    def sw(self, rs2, rs1, imm):
        self.emit(S(self._soff(imm, "sw"), self._r(rs2), self._r(rs1), 2, 0x23))

    def sd(self, rs2, rs1, imm):
        self.emit(S(self._soff(imm, "sd"), self._r(rs2), self._r(rs1), 3, 0x23))

    def jalr(self, rd, rs1, imm):
        self.emit(I(imm, self._r(rs1), 0, self._r(rd), 0x67))

    def ret(self):
        self.jalr("zero", "ra", 0)

    def beq(self, rs1, rs2, target):
        self.b("beq", rs1, rs2, target)

    def bne(self, rs1, rs2, target):
        self.b("bne", rs1, rs2, target)

    def bge(self, rs1, rs2, target):
        self.b("bge", rs1, rs2, target)

    def blt(self, rs1, rs2, target):
        self.b("blt", rs1, rs2, target)

    def csrr(self, rd, csr):
        self.emit(I(csr, 0, 2, self._r(rd), 0x73))     # csrrs rd, csr, x0

    def csrw(self, csr, rs1):
        self.emit(I(csr, self._r(rs1), 1, 0, 0x73))     # csrrw x0, csr, rs1

    def csrrs(self, rd, csr, rs1):
        self.emit(I(csr, self._r(rs1), 2, self._r(rd), 0x73))

    def csrrc(self, rd, csr, rs1):
        self.emit(I(csr, self._r(rs1), 3, self._r(rd), 0x73))

    def fence_rw(self):
        self.emit(0x0330000F)

    def fence_tso(self):
        self.emit(0x8330000F)

    def fence_i(self):
        self.emit(0x0000100F)

    def sfence_vma(self, rs1, rs2):
        self.emit(R(0x09, self._r(rs2), self._r(rs1), 0, 0, 0x73))

    def wfi(self):
        self.emit(0x10500073)

    def mret(self):
        self.emit(0x30200073)

    def amoadd_w(self, rd, rs2, rs1):
        # funct5=00000 (amoadd), aq=rl=0 -> funct7 field = 0
        self.emit(R(0x00, self._r(rs2), self._r(rs1), 2, self._r(rd), 0x2F))

    def lr_w(self, rd, rs1):
        # funct5=00010 (lr), rs2=0, aq=rl=0 -> funct7 field = 0b0001000
        self.emit(R(0x08, 0, self._r(rs1), 2, self._r(rd), 0x2F))

    def sc_w(self, rd, rs2, rs1):
        # funct5=00011 (sc), aq=rl=0 -> funct7 field = 0b0001100
        self.emit(R(0x0C, self._r(rs2), self._r(rs1), 2, self._r(rd), 0x2F))

    # ---- resolve + output ------------------------------------------------
    def _target_off(self, target, pc):
        if isinstance(target, str):
            return self.labels[target] - pc
        return target - pc

    def resolve(self):
        for idx, target, kind, extra in self.fix:
            pc = idx * 4
            off = self._target_off(target, pc)
            if kind == "jal":
                self.code[idx] = J(off, self._r(extra), 0x6F)
            elif kind == "la":
                hi = (off + 0x800) >> 12
                lo = off - (hi << 12)
                rd = self._r(extra)
                self.code[idx] = U(hi, rd, 0x17)
                self.code[idx + 1] = I(lo, rd, 0, rd, 0x13)
            else:
                f3 = {"beq": 0, "bne": 1, "blt": 4, "bge": 5,
                      "bltu": 6, "bgeu": 7}[kind]
                rs1, rs2 = extra
                self.code[idx] = B(off, self._r(rs2), self._r(rs1), f3, 0x63)

    def blob(self):
        self.resolve()
        # pad data to 4 bytes
        while len(self.data) % 4:
            self.data.append(0)
        out = b"".join(struct.pack("<I", w) for w in self.code)
        return out + bytes(self.data)


# ---------------------------------------------------------------------------
# payload memory map (guest RAM, starts zeroed)
# ---------------------------------------------------------------------------
FLAGS = 0x80020000
MARK = FLAGS + 0x000          # 2 x u64 hartid markers
READY = FLAGS + 0x040         # 2 x u32
AMO_DONE = FLAGS + 0x060      # 2 x u32
LRSC_DONE = FLAGS + 0x080     # 2 x u32
IPI_READY1 = FLAGS + 0x0A0
IPI_DONE1 = FLAGS + 0x0A4
IPI_CNT1 = FLAGS + 0x0A8
CODE_RDY = FLAGS + 0x0AC
CODE_DONE1 = FLAGS + 0x0B0
CODE_RES = FLAGS + 0x0B4
FINAL = FLAGS + 0x0C0         # 2 x u32
FAILCNT = FLAGS + 0x0E0
MODE_SMP = FLAGS + 0x0E4
FAILCODE = FLAGS + 0x0E8      # u32: ra of the failing check (see .map)
BOOT_A1 = FLAGS + 0x0F0       # u64: a1 handed over by the reset ROM
CNT = FLAGS + 0x100           # u32 AMO counter
LRS = FLAGS + 0x108           # u32 LR/SC value
CODE_BUF = FLAGS + 0x200      # cross-hart written code buffer

# adversarial atomicity phase flags
ORD_RDY = FLAGS + 0x140
ORD_DONE = FLAGS + 0x144
AMOS_RDY = FLAGS + 0x148
AMOS_DONE = FLAGS + 0x14C
ALIAS_READY = FLAGS + 0x150
ALIAS_LR = FLAGS + 0x154
ALIAS_DONE1 = FLAGS + 0x158
ORD_RES = FLAGS + 0x160       # u32: ordinary-store SC status (expect 1=fail)
AMOS_RES = FLAGS + 0x164      # u32: AMO+store serialization value
ALIAS_RES = FLAGS + 0x168     # u32: alias SC status (expect 1=fail)
PRINT_LOCK = FLAGS + 0x16C    # u32: guest console spinlock

PAGE_TEST = 0x80050000        # physical page used by the VA-alias test
PT_ROOT = 0x80060000
PT_L1 = 0x80061000
PT_L1B = 0x80062000
PT_L2A = 0x80063000
PT_L2B = 0x80064000
VA1 = 0x10000000              # alias 1 -> PAGE_TEST
VA2 = 0x20000000              # alias 2 -> PAGE_TEST

HTIF = 0x40008000
CLINT_MSIP1 = 0x02000004
FDT_ADDR = 0x1040             # riscv_build_fdt writes the dtb here
TIMEOUT = 50000000

# per-hart stacks (the reset state has sp == 0; every hart gets its own)
STACK_TOP = 0x80031000
STACK_STRIDE = 0x1000

ADDI_A0_ZERO_42 = I(42, 0, 0, 10, 0x13)   # addi a0, zero, 42
JALR_ZERO_0_RA = I(0, 1, 0, 0, 0x67)      # jalr zero, 0(ra)


def setup_stack(a):
    # sp = STACK_TOP + hartid * STACK_STRIDE
    a.li("sp", STACK_TOP)
    a.csrr("t0", 0xF14)
    a.slli("t0", "t0", 12)
    a.add("sp", "sp", "t0")


def common_routines(a):
    # putc: a0 = char -> HTIF console (device 1 cmd 1), serialized by a
    # guest spinlock (the HTIF tohost register is shared by the harts)
    a.label("putc")
    a.addi("sp", "sp", -16)
    a.sd("ra", "sp", 0)
    a.sd("s0", "sp", 8)
    a.mv("s0", "a0")
    a.li("t0", PRINT_LOCK)
    a.label("putc_lock")
    a.lr_w("t2", "t0")             # t2 = lock
    a.bne("t2", "zero", "putc_lock")
    a.li("t1", 1)
    a.sc_w("t2", "t1", "t0")       # try lock = 1
    a.bne("t2", "zero", "putc_lock")
    a.li("t0", HTIF)
    a.li("t1", 0x01010000)
    a.sw("s0", "t0", 0)
    a.sw("t1", "t0", 4)
    a.li("t0", PRINT_LOCK)
    a.sw("zero", "t0", 0)
    a.ld("ra", "sp", 0)
    a.ld("s0", "sp", 8)
    a.addi("sp", "sp", 16)
    a.ret()

    # puts: a0 = NUL-terminated string ptr (uses s0, saves ra)
    a.label("puts")
    a.addi("sp", "sp", -16)
    a.sd("ra", "sp", 0)
    a.sd("s0", "sp", 8)
    a.mv("s0", "a0")
    a.label("puts_loop")
    a.lbu("a0", "s0", 0)
    a.beq("a0", "zero", "puts_done")
    a.call("putc")
    a.addi("s0", "s0", 1)
    a.j("puts_loop")
    a.label("puts_done")
    a.ld("ra", "sp", 0)
    a.ld("s0", "sp", 8)
    a.addi("sp", "sp", 16)
    a.ret()

    # puthex4: a0 & 15 -> one lowercase hex digit
    a.label("puthex4")
    a.andi("a0", "a0", 15)
    a.li("t0", 10)
    a.blt("a0", "t0", "puthex_digit")
    a.addi("a0", "a0", 87)
    a.j("putc")
    a.label("puthex_digit")
    a.addi("a0", "a0", 48)
    a.j("putc")

    # fail: FAILCNT++ (guest atomic; also exercises AMO on both paths)
    a.label("fail")
    a.addi("sp", "sp", -16)
    a.sd("ra", "sp", 0)
    a.li("t0", FAILCNT)
    a.li("t1", 1)
    a.amoadd_w("t2", "t1", "t0")
    # record the failing check: ra = instruction after the call site, so it
    # can be resolved against the generated <payload>.map
    a.li("t0", FAILCODE)
    a.sw("ra", "t0", 0)
    a.ld("ra", "sp", 0)
    a.addi("sp", "sp", 16)
    a.ret()

    # puthex8: a0 = value -> 8 hex digits (putc-safe: only s0/s1/s2/a0, ra)
    a.label("puthex8")
    a.addi("sp", "sp", -32)
    a.sd("ra", "sp", 0)
    a.sd("s0", "sp", 8)
    a.sd("s1", "sp", 16)
    a.sd("s2", "sp", 24)
    a.mv("s0", "a0")
    a.li("s1", 8)
    a.label("ph8_loop")
    a.srli("s2", "s0", 28)
    a.mv("a0", "s2")
    a.call("puthex4")
    a.slli("s0", "s0", 4)
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "ph8_loop")
    a.ld("ra", "sp", 0)
    a.ld("s0", "sp", 8)
    a.ld("s1", "sp", 16)
    a.ld("s2", "sp", 24)
    a.addi("sp", "sp", 32)
    a.ret()

    # poweroff: tohost = 1 (HTIF shutdown)
    a.label("poweroff")
    a.li("t0", HTIF)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.sw("zero", "t0", 4)
    a.label("poweroff_park")
    a.wfi()
    a.j("poweroff_park")

    # alias_enable: satp = sv39 root, sfence, MPRV=1 MPP=S (per hart)
    a.label("alias_enable")
    a.li("t0", PT_ROOT)
    a.srli("t1", "t0", 12)
    a.li("t2", 8)
    a.slli("t2", "t2", 60)
    a.or_("t1", "t1", "t2")
    a.csrw(0x180, "t1")            # satp
    a.sfence_vma("zero", "zero")
    a.li("t0", (1 << 17) | (1 << 11))
    a.csrrs("zero", 0x300, "t0")   # mstatus |= MPRV | MPP=S
    a.ret()

    # alias_disable: clear MPRV, satp = bare
    a.label("alias_disable")
    a.li("t0", (1 << 17))
    a.csrrc("zero", 0x300, "t0")   # mstatus &= ~MPRV
    a.csrw(0x180, "zero")
    a.sfence_vma("zero", "zero")
    a.ret()


def fdt_dump(a):
    """Hex-dump the generated device tree (FDT_ADDR) over HTIF.

    putc-safe registers only (s2/s4/s5/s10/s11); the loop counters must
    survive putc, which clobbers t0-t2/s0/a0.
    """
    a.label("fdt_dump")
    a.addi("sp", "sp", -32)
    a.sd("ra", "sp", 0)
    a.sd("s10", "sp", 8)
    a.sd("s11", "sp", 16)
    a.sd("s2", "sp", 24)
    a.la("a0", "str_fdt_begin")
    a.call("puts")
    a.li("s11", FDT_ADDR)
    a.lbu("t0", "s11", 4)
    a.slli("t0", "t0", 24)
    a.lbu("t1", "s11", 5)
    a.slli("t1", "t1", 16)
    a.or_("t0", "t0", "t1")
    a.lbu("t1", "s11", 6)
    a.slli("t1", "t1", 8)
    a.or_("t0", "t0", "t1")
    a.lbu("t1", "s11", 7)
    a.or_("s10", "t0", "t1")         # s10 = fdt totalsize
    a.li("s2", 0)
    a.label("fdt_dump_loop")
    a.bge("s2", "s10", "fdt_dump_done")
    a.add("s5", "s11", "s2")
    a.lbu("s4", "s5", 0)
    a.srli("a0", "s4", 4)
    a.call("puthex4")
    a.andi("a0", "s4", 15)
    a.call("puthex4")
    a.addi("s2", "s2", 1)
    a.j("fdt_dump_loop")
    a.label("fdt_dump_done")
    a.la("a0", "str_fdt_end")
    a.call("puts")
    a.ld("ra", "sp", 0)
    a.ld("s10", "sp", 8)
    a.ld("s11", "sp", 16)
    a.ld("s2", "sp", 24)
    a.addi("sp", "sp", 32)
    a.ret()


def trap_handler(a):
    # M-mode trap handler: IPI (msip) -> count+ack; anything else -> report
    a.label("trap_handler")
    a.csrr("t0", 0x342)          # mcause
    a.srli("t1", "t0", 31)
    a.beq("t1", "zero", "trap_bad")
    a.slli("t0", "t0", 1)
    a.srli("t0", "t0", 1)
    a.li("t1", 3)                # M software interrupt
    a.bne("t0", "t1", "trap_bad")
    a.li("t0", IPI_CNT1)
    a.lw("t1", "t0", 0)
    a.addi("t1", "t1", 1)
    a.sw("t1", "t0", 0)
    a.li("t0", CLINT_MSIP1)
    a.sw("zero", "t0", 0)        # clear msip1
    a.li("t0", IPI_DONE1)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.mret()
    a.label("trap_bad")
    a.la("a0", "str_trap")
    a.call("puts")
    a.label("trap_park")
    a.wfi()
    a.j("trap_park")


def build_smp_test():
    a = Asm()
    # ---- entry ----
    a.label("_start")
    setup_stack(a)
    a.la("t0", "trap_handler")
    a.csrw(0x305, "t0")          # mtvec
    a.csrr("s0", 0xF14)          # s0 = mhartid
    a.li("t0", BOOT_A1)
    a.sd("a1", "t0", 0)          # record the ROM's a1 for the host
    a.li("t0", MARK)
    a.slli("t1", "s0", 3)
    a.add("t0", "t0", "t1")
    a.sd("s0", "t0", 0)          # MARK[hart] = hartid
    a.li("t0", READY)
    a.slli("t1", "s0", 2)
    a.add("t0", "t0", "t1")
    a.li("t2", 1)
    a.sw("t2", "t0", 0)          # READY[hart] = 1
    a.bne("s0", "zero", "hart1_main")

    # ---- hart 0: detect hart 1 ----
    a.li("s1", TIMEOUT)
    a.label("h0_wait_h1")
    a.li("t0", READY)
    a.lw("t1", "t0", 4)
    a.bne("t1", "zero", "h0_have_h1")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_h1")
    a.j("up_mode")
    a.label("h0_have_h1")
    a.li("t0", MODE_SMP)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    # write the cross-hart code buffer (addi a0,zero,42; jalr zero,0(ra))
    a.li("t0", CODE_BUF)
    a.li("t1", ADDI_A0_ZERO_42)
    a.sw("t1", "t0", 0)
    a.li("t1", JALR_ZERO_0_RA)
    a.sw("t1", "t0", 4)
    a.li("t0", CODE_RDY)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.j("amo_test")

    a.label("hart1_main")
    a.j("amo_test")

    # ---- AMO test (both harts): CNT += 1 x200, must total 400 ----
    a.label("amo_test")
    a.li("s1", 200)
    a.li("s2", CNT)
    a.li("s3", 1)
    a.label("amo_loop")
    a.amoadd_w("t3", "s3", "s2")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "amo_loop")
    a.li("t0", AMO_DONE)
    a.slli("t1", "s0", 2)
    a.add("t0", "t0", "t1")
    a.li("t2", 1)
    a.sw("t2", "t0", 0)
    a.j("lrsc_test")

    # ---- LR/SC test (both harts): LRS += 1 x100, must total 200 ----
    a.label("lrsc_test")
    a.li("s1", 100)
    a.li("s2", LRS)
    a.label("lrsc_loop")
    a.lr_w("t3", "s2")
    a.addi("t3", "t3", 1)
    a.sc_w("t3", "t3", "s2")
    a.bne("t3", "zero", "lrsc_loop")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "lrsc_loop")
    a.li("t0", LRSC_DONE)
    a.slli("t1", "s0", 2)
    a.add("t0", "t0", "t1")
    a.li("t2", 1)
    a.sw("t2", "t0", 0)
    a.bne("s0", "zero", "h1_after_lrsc")

    # ---- hart 0: check AMO + LR/SC results ----
    a.li("s1", TIMEOUT)
    a.label("h0_wait_amo")
    a.li("t0", AMO_DONE)
    a.lw("t1", "t0", 4)
    a.bne("t1", "zero", "h0_check_amo")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_amo")
    a.call("fail")
    a.j("h0_wait_lrsc")
    a.label("h0_check_amo")
    a.li("t0", CNT)
    a.lw("t1", "t0", 0)
    a.li("t2", 400)
    a.beq("t1", "t2", "h0_amo_ok")
    a.call("fail")
    a.j("h0_wait_lrsc")
    a.label("h0_amo_ok")
    a.la("a0", "str_amo_ok")
    a.call("puts")

    a.li("s1", TIMEOUT)
    a.label("h0_wait_lrsc")
    a.li("t0", LRSC_DONE)
    a.lw("t1", "t0", 4)
    a.bne("t1", "zero", "h0_check_lrsc")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_lrsc")
    a.call("fail")
    a.j("h0_ipi")
    a.label("h0_check_lrsc")
    a.li("t0", LRS)
    a.lw("t1", "t0", 0)
    a.li("t2", 200)
    a.beq("t1", "t2", "h0_lrsc_ok")
    a.call("fail")
    a.j("h0_ipi")
    a.label("h0_lrsc_ok")
    a.la("a0", "str_lrsc_ok")
    a.call("puts")

    # ---- IPI test: hart 0 doorbells hart 1 via CLINT msip1 ----
    a.label("h0_ipi")
    a.li("s1", TIMEOUT)
    a.label("h0_wait_ipir")
    a.li("t0", IPI_READY1)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h0_send_ipi")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_ipir")
    a.call("fail")
    a.j("h0_fence")
    a.label("h0_send_ipi")
    a.li("t0", CLINT_MSIP1)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.li("s1", TIMEOUT)
    a.label("h0_wait_ipid")
    a.li("t0", IPI_DONE1)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h0_check_ipi")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_ipid")
    a.call("fail")
    a.j("h0_fence")
    a.label("h0_check_ipi")
    a.li("t0", IPI_CNT1)
    a.lw("t1", "t0", 0)
    a.li("t2", 1)
    a.beq("t1", "t2", "h0_ipi_ok")
    a.call("fail")
    a.j("h0_fence")
    a.label("h0_ipi_ok")
    a.la("a0", "str_ipi_ok")
    a.call("puts")

    # ---- fence / sfence smoke (both harts execute; hart 0 here) ----
    a.label("h0_fence")
    a.fence_rw()
    a.fence_tso()
    a.fence_i()
    a.sfence_vma("zero", "zero")

    # ---- cross-hart code visibility: hart 1 calls CODE_BUF ----
    a.li("s1", TIMEOUT)
    a.label("h0_wait_code")
    a.li("t0", CODE_DONE1)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h0_check_code")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_code")
    a.call("fail")
    a.j("h0_fdt")
    a.label("h0_check_code")
    a.li("t0", CODE_RES)
    a.lw("t1", "t0", 0)
    a.li("t2", 42)
    a.beq("t1", "t2", "h0_code_ok")
    a.call("fail")
    a.j("h0_fdt")
    a.label("h0_code_ok")
    a.la("a0", "str_code_ok")
    a.call("puts")

    # ---- adversarial: ordinary store between LR/SC must fail the SC ----
    a.label("h0_ord")
    a.li("t0", ORD_RES)
    a.lr_w("t1", "t0")
    a.li("t0", ORD_RDY)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.li("s1", TIMEOUT)
    a.label("h0_wait_ord")
    a.li("t0", ORD_DONE)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h0_ord_sc")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_ord")
    a.call("fail")
    a.j("h0_amo_st")
    a.label("h0_ord_sc")
    a.li("t0", ORD_RES)
    a.li("t1", 99)
    a.sc_w("t2", "t1", "t0")
    a.li("t3", 1)
    a.beq("t2", "t3", "h0_ord_ok")     # SC must FAIL (status 1)
    a.call("fail")
    a.j("h0_amo_st")
    a.label("h0_ord_ok")

    # ---- adversarial: AMO + normal store serialization ----
    a.label("h0_amo_st")
    a.li("s1", 50)
    a.li("s2", AMOS_RES)
    a.li("s3", 1)
    a.label("h0_amost_loop")
    a.amoadd_w("t3", "s3", "s2")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_amost_loop")
    a.li("t0", AMOS_RDY)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.li("s1", TIMEOUT)
    a.label("h0_wait_amost")
    a.li("t0", AMOS_DONE)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h0_check_amost")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_amost")
    a.call("fail")
    a.j("h0_alias")
    a.label("h0_check_amost")
    a.li("t0", AMOS_RES)
    a.lw("t1", "t0", 0)
    a.li("t2", 1000)
    a.beq("t1", "t2", "h0_amost2")     # 50 AMOs then store 1000 -> 1000
    a.call("fail")
    a.j("h0_alias")
    a.label("h0_amost2")
    # round 2: store 1000 first, then 50 AMOs -> 1050
    a.li("s1", TIMEOUT)
    a.label("h0_wait_amost2")
    a.li("t0", AMOS_RDY)
    a.lw("t1", "t0", 0)
    a.li("t2", 2)
    a.beq("t1", "t2", "h0_amost2_go")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_amost2")
    a.call("fail")
    a.j("h0_alias")
    a.label("h0_amost2_go")
    a.li("s1", 50)
    a.li("s2", AMOS_RES)
    a.li("s3", 1)
    a.label("h0_amost2_loop")
    a.amoadd_w("t3", "s3", "s2")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_amost2_loop")
    a.li("t0", AMOS_RES)
    a.lw("t1", "t0", 0)
    a.li("t2", 1050)
    a.beq("t1", "t2", "h0_alias")
    a.call("fail")

    # ---- adversarial: VA alias (sv39) between LR/SC must fail the SC ----
    a.label("h0_alias")
    # build page tables (physical addresses, MPRV still off)
    a.li("t0", PT_ROOT)
    a.li("t1", ((PT_L1 >> 12) << 10) | 1)
    a.sd("t1", "t0", 0)                # root[0] -> PT_L1
    a.li("t1", ((PT_L1B >> 12) << 10) | 1)
    a.sd("t1", "t0", 16)               # root[2] -> PT_L1B
    a.li("t0", PT_L1)
    a.li("t1", ((PT_L2A >> 12) << 10) | 1)
    a.sd("t1", "t0", 0x400)            # l1[0x80] -> PT_L2A
    a.li("t1", ((PT_L2B >> 12) << 10) | 1)
    a.li("t0", PT_L1 + 0x800)          # l1[0x100]: offset 0x800 > 12-bit imm
    a.sd("t1", "t0", 0)                # l1[0x100] -> PT_L2B
    a.li("t0", PT_L2A)
    a.li("t1", ((PAGE_TEST >> 12) << 10) | 0xCF)
    a.sd("t1", "t0", 0)                # l2a[0] -> PAGE_TEST (RWX)
    a.li("t0", PT_L2B)
    a.sd("t1", "t0", 0)                # l2b[0] -> PAGE_TEST (RWX)
    # l1b[i] = 2MB leaf at 0x80000000 + i*0x200000, i in 0..7
    a.li("t0", PT_L1B)
    a.li("t2", 0x80000000)
    a.li("t3", 0xCF)
    a.li("s1", 8)
    a.label("h0_pt_loop")
    a.srli("t1", "t2", 12)
    a.slli("t1", "t1", 10)
    a.or_("t1", "t1", "t3")
    a.sd("t1", "t0", 0)
    a.addi("t0", "t0", 8)
    a.li("t4", 0x200000)
    a.add("t2", "t2", "t4")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_pt_loop")
    a.li("t0", ALIAS_READY)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    # enable translation on this hart and take the reservation via VA1
    a.call("alias_enable")
    a.li("t0", VA1)
    a.lr_w("t1", "t0")
    a.li("t0", ALIAS_LR)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.li("s1", TIMEOUT)
    a.label("h0_wait_alias")
    a.li("t0", ALIAS_DONE1)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h0_alias_sc")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_alias")
    a.call("fail")
    a.j("h0_alias_done")
    a.label("h0_alias_sc")
    a.li("t0", VA1)
    a.li("t1", 55)
    a.sc_w("t2", "t1", "t0")
    a.li("t3", 1)
    a.beq("t2", "t3", "h0_alias_ok")   # SC must FAIL (status 1)
    a.call("fail")
    a.j("h0_alias_done")
    a.label("h0_alias_ok")
    a.li("t0", VA1)                    # hart1's store via VA2 must be visible
    a.lw("t1", "t0", 0)
    a.li("t2", 66)
    a.beq("t1", "t2", "h0_alias_done")
    a.call("fail")
    a.label("h0_alias_done")
    a.call("alias_disable")
    a.la("a0", "str_adv_ok")
    a.call("puts")

    a.label("h0_fdt")
    a.call("fdt_dump")

    # ---- final: wait hart 1 FINAL, report ----
    a.li("s1", TIMEOUT)
    a.label("h0_wait_final")
    a.li("t0", FINAL)
    a.lw("t1", "t0", 4)
    a.bne("t1", "zero", "h0_report")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h0_wait_final")
    a.call("fail")
    a.label("h0_report")
    a.li("t0", FAILCNT)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h0_fail")
    a.la("a0", "str_smp_ok")
    a.call("puts")
    a.j("poweroff")
    a.label("h0_fail")
    a.la("a0", "str_smp_fail")
    a.call("puts")
    a.li("t0", FAILCNT)
    a.lw("a0", "t0", 0)
    a.addi("a0", "a0", 48)
    a.call("putc")
    a.la("a0", "str_at")
    a.call("puts")
    a.li("t0", FAILCODE)
    a.lw("a0", "t0", 0)
    a.call("puthex8")
    a.la("a0", "str_nl")
    a.call("puts")
    a.j("poweroff")

    # ---- hart 1: IPI receiver, then cross-hart code call ----
    a.label("h1_after_lrsc")
    a.li("t0", 8)                  # MSIE
    a.csrrs("zero", 0x304, "t0")   # mie |= MSIE
    # an M-mode interrupt is only taken with mstatus.MIE=1 (the engine
    # follows the spec: get_pending_irq_mask gates PRV_M on MSTATUS_MIE)
    a.li("t0", 8)                  # MIE
    a.csrrs("zero", 0x300, "t0")   # mstatus |= MIE
    a.li("t0", IPI_READY1)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.wfi()
    # woken by the IPI; the handler acked it and set IPI_DONE1
    a.li("s1", TIMEOUT)
    a.label("h1_wait_code")
    a.li("t0", CODE_RDY)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h1_call_code")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h1_wait_code")
    a.call("fail")
    a.j("h1_final")
    a.label("h1_call_code")
    a.fence_i()
    a.li("t0", CODE_BUF)
    a.jalr("ra", "t0", 0)          # call hart 0's code -> a0 = 42
    a.li("t0", CODE_RES)
    a.sw("a0", "t0", 0)
    a.li("t0", CODE_DONE1)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)

    # ---- adversarial: ordinary store between hart 0's LR/SC ----
    a.label("h1_ord")
    a.li("s1", TIMEOUT)
    a.label("h1_wait_ord")
    a.li("t0", ORD_RDY)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h1_ord_store")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h1_wait_ord")
    a.call("fail")
    a.j("h1_amo_st")
    a.label("h1_ord_store")
    a.li("t0", ORD_RES)
    a.li("t1", 77)
    a.sw("t1", "t0", 0)            # plain store: must invalidate hart 0's LR
    a.li("t0", ORD_DONE)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)

    # ---- adversarial: AMO + normal store serialization ----
    a.label("h1_amo_st")
    a.li("s1", TIMEOUT)
    a.label("h1_wait_amost")
    a.li("t0", AMOS_RDY)
    a.lw("t1", "t0", 0)
    a.li("t2", 1)
    a.beq("t1", "t2", "h1_amost_store")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h1_wait_amost")
    a.call("fail")
    a.j("h1_alias"
    )
    a.label("h1_amost_store")
    a.li("t0", AMOS_RES)
    a.li("t1", 1000)
    a.sw("t1", "t0", 0)            # after hart 0's 50 AMOs -> 1000
    a.li("t0", AMOS_DONE)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    # round 2: store 1000 first, then hart 0 does 50 AMOs -> 1050
    a.li("t0", AMOS_RES)
    a.li("t1", 1000)
    a.sw("t1", "t0", 0)
    a.li("t0", AMOS_RDY)
    a.li("t1", 2)
    a.sw("t1", "t0", 0)

    # ---- adversarial: VA alias store between hart 0's LR/SC ----
    a.label("h1_alias")
    a.li("s1", TIMEOUT)
    a.label("h1_wait_aliasr")
    a.li("t0", ALIAS_READY)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h1_alias_en")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h1_wait_aliasr")
    a.call("fail")
    a.j("h1_final"
    )
    a.label("h1_alias_en")
    a.call("alias_enable")
    a.li("s1", TIMEOUT)
    a.label("h1_wait_aliaslr")
    a.li("t0", ALIAS_LR)
    a.lw("t1", "t0", 0)
    a.bne("t1", "zero", "h1_alias_store")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "h1_wait_aliaslr")
    a.call("fail")
    a.j("h1_alias_dis")
    a.label("h1_alias_store")
    a.li("t0", VA2)
    a.li("t1", 66)
    a.sw("t1", "t0", 0)            # plain store via the alias: same PA
    a.li("t0", ALIAS_DONE1)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.label("h1_alias_dis")
    a.call("alias_disable")

    a.label("h1_final")
    a.fence_rw()
    a.li("t0", FINAL)
    a.li("t1", 1)
    a.sw("t1", "t0", 4)            # FINAL[1] = 1
    a.label("h1_park")
    a.wfi()
    a.j("h1_park")

    # ---- UP mode (hart 0 only, no hart 1 answered) ----
    a.label("up_mode")
    a.li("s1", 200)
    a.li("s2", CNT)
    a.li("s3", 1)
    a.label("up_amo_loop")
    a.amoadd_w("t3", "s3", "s2")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "up_amo_loop")
    a.li("s1", 100)
    a.li("s2", LRS)
    a.label("up_lrsc_loop")
    a.lr_w("t3", "s2")
    a.addi("t3", "t3", 1)
    a.sc_w("t3", "t3", "s2")
    a.bne("t3", "zero", "up_lrsc_loop")
    a.addi("s1", "s1", -1)
    a.bne("s1", "zero", "up_lrsc_loop")
    a.li("t0", CNT)
    a.lw("t1", "t0", 0)
    a.li("t2", 200)
    a.bne("t1", "t2", "up_bad")
    a.li("t0", LRS)
    a.lw("t1", "t0", 0)
    a.li("t2", 100)
    a.bne("t1", "t2", "up_bad")
    a.call("fdt_dump")
    a.la("a0", "str_up_ok")
    a.call("puts")
    a.j("poweroff")
    a.label("up_bad")
    a.la("a0", "str_up_bad")
    a.call("puts")
    a.j("poweroff")

    fdt_dump(a)
    trap_handler(a)
    common_routines(a)

    # ---- data ----
    a.dlabel("str_amo_ok")
    a.asciz("AMO-OK\n")
    a.dlabel("str_lrsc_ok")
    a.asciz("LRSC-OK\n")
    a.dlabel("str_ipi_ok")
    a.asciz("IPI-OK\n")
    a.dlabel("str_code_ok")
    a.asciz("CODE-OK\n")
    a.dlabel("str_fdt_begin")
    a.asciz("FDT-BEGIN\n")
    a.dlabel("str_fdt_end")
    a.asciz("\nFDT-END\n")
    a.dlabel("str_smp_ok")
    a.asciz("SMP-OK\n")
    a.dlabel("str_at")
    a.asciz(" at 0x")
    a.dlabel("str_smp_fail")
    a.asciz("SMP-FAIL ")
    a.dlabel("str_nl")
    a.asciz("\n")
    a.dlabel("str_up_ok")
    a.asciz("UP-OK\n")
    a.dlabel("str_up_bad")
    a.asciz("UP-BAD\n")
    a.dlabel("str_adv_ok")
    a.asciz("ADV-OK\n")
    a.dlabel("str_trap")
    a.asciz("TRAP\n")
    return a.blob(), a


def build_perf(dual):
    a = Asm()
    a.label("_start")
    setup_stack(a)
    a.csrr("s0", 0xF14)
    a.li("s1", 25000000 if dual else 50000000)
    a.li("s2", 0)
    a.li("s3", 0)
    a.li("s4", 0)
    a.label("perf_loop")
    a.addi("s1", "s1", -1)
    a.addi("s2", "s2", 1)
    a.addi("s3", "s3", 1)
    a.xor("s4", "s4", "s2")
    a.bne("s1", "zero", "perf_loop")
    a.bne("s0", "zero", "perf_h1")
    if dual:
        # only the dual payload runs with 2 harts; a single-hart run must
        # not burn ~800M spin instructions waiting for a hart that does
        # not exist (that made the "same guest work" comparison fail)
        a.li("s5", 100000000)
        a.label("perf_wait")
        a.li("t0", FINAL)
        a.lw("t1", "t0", 4)
        a.bne("t1", "zero", "perf_done")
        a.addi("s5", "s5", -1)
        a.bne("s5", "zero", "perf_wait")
    a.j("perf_done")
    a.label("perf_h1")
    a.li("t0", FINAL)
    a.li("t1", 1)
    a.sw("t1", "t0", 4)
    a.label("perf_done")
    a.bne("s0", "zero", "perf_park")
    a.li("t0", HTIF)
    a.li("t1", 1)
    a.sw("t1", "t0", 0)
    a.sw("zero", "t0", 4)
    a.label("perf_park")
    a.wfi()
    a.j("perf_park")
    return a.blob(), a


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    for name, (blob, asm) in [("smp_test.bin", build_smp_test()),
                              ("perf_dual.bin", build_perf(True)),
                              ("perf_single.bin", build_perf(False))]:
        with open(f"{outdir}/{name}", "wb") as f:
            f.write(blob)
        # FAILCODE holds the caller PC of the failing check; resolve it here
        with open(f"{outdir}/{name}.map", "w") as f:
            for label, off in sorted(asm.labels.items(), key=lambda kv: kv[1]):
                f.write(f"{0x80000000 + off:08x} {label}\n")
        print(f"{name}: {len(blob)} bytes")


if __name__ == "__main__":
    main()
