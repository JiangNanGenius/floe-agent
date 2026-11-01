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
import re
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
EXPECTED_SCHEMA = "floe.root-capture-helper.v2"
EXPECTED_NAME = "libfloecapture_helper.so"
GUARD_SCHEMA = "floe.capture-guard.v1"
GUARD_VERSION = 1
GUARD_ABI = "arm64-v8a"
GUARD_MAGIC = b"FLOE_CAPTURE_GUARD_V1|"
GUARD_MAX_IDENTITY = 512
HEX64 = re.compile(r"^[0-9a-f]{64}$")


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


def parse_guard_identity(data: bytes) -> dict:
    """Extract the stripped-safe guard build identity from .rodata.

    The marker is a single NUL-terminated record:
      FLOE_CAPTURE_GUARD_V1|arm64-v8a|1|<source>|<header>|<patch>
    Exactly one occurrence is required; the hashes must be syntactically
    valid. This is a packaging-identity binding, not an ELF signature.
    """
    positions = []
    cursor = 0
    while True:
        found = data.find(GUARD_MAGIC, cursor)
        if found < 0:
            break
        positions.append(found)
        cursor = found + 1
    if len(positions) != 1:
        fail(f"expected exactly one guard identity record, found {len(positions)}")
    start = positions[0]
    stop = data.find(b"\x00", start, start + GUARD_MAX_IDENTITY)
    if stop < 0:
        fail("guard identity record is not NUL terminated")
    try:
        text = data[start:stop].decode("ascii", "strict")
    except UnicodeDecodeError:
        fail("guard identity record is not ASCII")
    fields = text.split("|")
    if len(fields) != 6:
        fail(f"guard identity record has {len(fields)} fields, expected 6")
    magic, abi, version, source, header, patch = fields
    if magic != GUARD_MAGIC.decode("ascii").rstrip("|"):
        fail("guard identity magic mismatch")
    if abi != GUARD_ABI:
        fail(f"guard identity ABI mismatch: {abi}")
    if version != str(GUARD_VERSION):
        fail(f"guard identity version mismatch: {version}")
    for label, value in (("source", source), ("header", header), ("patch", patch)):
        if not HEX64.match(value):
            fail(f"guard identity {label} hash is not 64 lowercase hex characters")
    return {
        "schema": GUARD_SCHEMA,
        "version": int(version),
        "abi": abi,
        "sourceSha256": source,
        "headerSha256": header,
        "patchSha256": patch,
    }


def guard_problem(guard: dict | None) -> str | None:
    if not isinstance(guard, dict):
        return "guard manifest is missing"
    if guard.get("schema") != GUARD_SCHEMA:
        return "guard schema mismatch"
    if str(guard.get("version")) != str(GUARD_VERSION):
        return "guard version mismatch"
    if guard.get("abi") != GUARD_ABI:
        return "guard ABI mismatch"
    for key in ("sourceSha256", "headerSha256", "patchSha256"):
        value = guard.get(key)
        if not isinstance(value, str) or not HEX64.match(value):
            return f"guard {key} is invalid"
    return None


def verify(path: str) -> tuple[dict, bytes]:
    with open(path, "rb") as handle:
        data = handle.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        fail("helper exceeds the 32 MiB byte cap")
    parsed = parse_elf(data)
    dynamic = read_dynamic(data, parsed)
    guard = parse_guard_identity(data)
    digest = hashlib.sha256(data).hexdigest()
    return {
        "sha256": digest,
        "sizeBytes": len(data),
        "needed": dynamic["needed"],
        "pageSize": min(segment["align"] for segment in parsed["loads"]),
        "guard": guard,
    }, data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--write-manifest")
    parser.add_argument("--expect-sha")
    parser.add_argument("--source", action="append", default=[])
    parser.add_argument("--guard-source", default="")
    parser.add_argument("--guard-header", default="")
    parser.add_argument("--guard-patch", default="")
    parser.add_argument("--ndk-version", default="")
    parser.add_argument(
        "--version",
        default="tcpdump-4.99.5+libpcap-1.10.5+floe-guard-1",
    )
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
    supplied = {
        "sourceSha256": args.guard_source.lower(),
        "headerSha256": args.guard_header.lower(),
        "patchSha256": args.guard_patch.lower(),
    }
    if any(supplied.values()):
        for key, value in supplied.items():
            if not HEX64.match(value):
                print(f"error: {key} must be 64 lowercase hex characters", file=sys.stderr)
                return 5
        for key, value in supplied.items():
            if result["guard"][key] != value:
                print(f"error: embedded guard {key} does not match the build input", file=sys.stderr)
                return 6
    if args.write_manifest and not all(supplied.values()):
        print(
            "error: --write-manifest requires --guard-source/--guard-header/--guard-patch",
            file=sys.stderr,
        )
        return 5
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
        "guard": result["guard"],
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
