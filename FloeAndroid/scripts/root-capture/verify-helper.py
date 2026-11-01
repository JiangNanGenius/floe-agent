#!/usr/bin/env python3
"""Verify the pinned root-capture helper ELF and emit its digest manifest.

The checks are intentionally byte-level and fail closed. This script does not
build, download, install or execute the helper; it only validates the exact
artifact produced by build-helper.sh.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys

ALLOWED_NEEDED = {
    "libc.so",
    "libm.so",
    "libdl.so",
    "liblog.so",
    "libz.so",
}
PT_LOAD = 1
PT_DYNAMIC = 2
PT_INTERP = 3
DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_STRSZ = 10
DT_RPATH = 15
DT_TEXTREL = 22
DT_RUNPATH = 29
DT_FLAGS_1 = 0x6FFFFFFB
DF_1_PIE = 0x08000000
ET_DYN = 3
EM_AARCH64 = 183
MAX_BYTES = 32 * 1024 * 1024
MIN_PAGE = 16 * 1024
EXPECTED_ID = "tcpdump-v1"
EXPECTED_SCHEMA = "floe.root-capture-helper.v1"
EXPECTED_NAME = "libfloecapture_helper.so"


class VerificationError(RuntimeError):
    pass


def fail(message: str) -> "None":
    raise VerificationError(message)


def parse_elf(data: bytes) -> dict:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        fail("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        fail("expected 64-bit little-endian ELF")
    e_type, e_machine = struct.unpack_from("<HH", data, 16)
    if e_type != ET_DYN:
        fail(f"expected ET_DYN PIE, got e_type={e_type}")
    if e_machine != EM_AARCH64:
        fail(f"expected AArch64, got e_machine={e_machine}")
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    if e_phentsize != 56 or e_phnum < 1 or e_phoff + e_phentsize * e_phnum > len(data):
        fail("invalid program header table")
    segments = []
    for index in range(e_phnum):
        offset = e_phoff + index * e_phentsize
        p_type, p_flags = struct.unpack_from("<II", data, offset)
        p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from(
            "<QQQQQQ", data, offset + 8
        )
        segments.append(
            {
                "type": p_type,
                "offset": p_offset,
                "vaddr": p_vaddr,
                "filesz": p_filesz,
                "memsz": p_memsz,
                "align": p_align,
            }
        )
    loads = [segment for segment in segments if segment["type"] == PT_LOAD]
    if not loads:
        fail("no PT_LOAD segments")
    for segment in loads:
        if segment["align"] < MIN_PAGE:
            fail(f"PT_LOAD alignment {segment['align']:#x} is below 16 KiB")
        if (segment["vaddr"] - segment["offset"]) % MIN_PAGE != 0:
            fail("PT_LOAD vaddr/offset are not 16 KiB congruent")
        if segment["offset"] + segment["filesz"] > len(data):
            fail("PT_LOAD extends past end of file")
    interp = [segment for segment in segments if segment["type"] == PT_INTERP]
    if not interp:
        fail("missing PT_INTERP (not a dynamic PIE executable)")
    interp_offset = interp[0]["offset"]
    interp_size = interp[0]["filesz"]
    interpreter = data[interp_offset : interp_offset + interp_size].split(b"\x00", 1)[0]
    if interpreter not in (b"/system/bin/linker64",):
        fail(f"unexpected interpreter: {interpreter!r}")
    dynamic = [segment for segment in segments if segment["type"] == PT_DYNAMIC]
    if not dynamic:
        fail("missing PT_DYNAMIC")
    return {
        "segments": segments,
        "loads": loads,
        "dynamic": dynamic[0],
    }


def virtual_to_offset(loads: list[dict], address: int) -> int:
    for segment in loads:
        start = segment["vaddr"]
        end = start + segment["filesz"]
        if start <= address < end:
            return segment["offset"] + (address - start)
    fail(f"address {address:#x} is not file-backed")


def read_dynamic(data: bytes, parsed: dict) -> dict:
    dynamic = parsed["dynamic"]
    entries = []
    offset = dynamic["offset"]
    end = offset + dynamic["filesz"]
    while offset + 16 <= end:
        tag, value = struct.unpack_from("<qQ", data, offset)
        offset += 16
        if tag == DT_NULL:
            break
        entries.append((tag, value))
    tags = {tag for tag, _ in entries}
    for forbidden, label in ((DT_RPATH, "RPATH"), (DT_RUNPATH, "RUNPATH"), (DT_TEXTREL, "TEXTREL")):
        if forbidden in tags:
            fail(f"forbidden dynamic tag {label}")
    strtab = next((value for tag, value in entries if tag == DT_STRTAB), None)
    strsz = next((value for tag, value in entries if tag == DT_STRSZ), None)
    if strtab is None or strsz is None:
        fail("missing dynamic string table")
    strtab_offset = virtual_to_offset(parsed["loads"], strtab)
    if strtab_offset + strsz > len(data):
        fail("dynamic string table extends past file")
    needed = []
    for tag, value in entries:
        if tag == DT_NEEDED:
            if value >= strsz:
                fail("DT_NEEDED outside string table")
            start = strtab_offset + value
            stop = data.index(b"\x00", start)
            needed.append(data[start:stop].decode("ascii", "replace"))
    unexpected = sorted(set(needed) - ALLOWED_NEEDED)
    if unexpected:
        fail("unexpected DT_NEEDED: " + ", ".join(unexpected))
    flags1 = next((value for tag, value in entries if tag == DT_FLAGS_1), 0)
    if not (flags1 & DF_1_PIE):
        fail("ELF is not marked DF_1_PIE")
    return {"needed": sorted(set(needed))}


def verify(path: str) -> tuple[dict, bytes]:
    with open(path, "rb") as handle:
        data = handle.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        fail("helper exceeds the 32 MiB byte cap")
    parsed = parse_elf(data)
    dynamic = read_dynamic(data, parsed)
    digest = hashlib.sha256(data).hexdigest()
    return {
        "sha256": digest,
        "sizeBytes": len(data),
        "needed": dynamic["needed"],
        "pageSize": min(segment["align"] for segment in parsed["loads"]),
    }, data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--write-manifest")
    parser.add_argument("--expect-sha")
    parser.add_argument("--source", action="append", default=[])
    parser.add_argument("--ndk-version", default="")
    parser.add_argument("--version", default="tcpdump-4.99.5+libpcap-1.10.5")
    args = parser.parse_args()

    binary = os.path.abspath(args.binary)
    if not os.path.isfile(binary):
        print(f"error: missing helper: {binary}", file=sys.stderr)
        return 2
    try:
        result, _ = verify(binary)
    except (VerificationError, OSError, ValueError) as error:
        print(f"error: helper verification failed: {error}", file=sys.stderr)
        return 3
    if args.expect_sha and result["sha256"] != args.expect_sha.lower():
        print("error: helper digest does not match --expect-sha", file=sys.stderr)
        return 4
    manifest = {
        "schema": EXPECTED_SCHEMA,
        "id": EXPECTED_ID,
        "version": args.version,
        "abi": "arm64-v8a",
        "minSdk": 28,
        "pageSize": result["pageSize"],
        "packagedName": EXPECTED_NAME,
        "sha256": result["sha256"],
        "sizeBytes": result["sizeBytes"],
        "needed": result["needed"],
        "ndkVersion": args.ndk_version,
        "sources": args.source,
    }
    if args.write_manifest:
        destination = os.path.abspath(args.write_manifest)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        temporary = destination + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
