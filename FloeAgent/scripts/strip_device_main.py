"""Strip only a copied iOS app executable after its original dSYM is preserved."""

import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import tempfile

from normalize_simulator_runpaths import digest_file
from verify_github_release_publication import macho_device_platform


def runtime_digest(path):
    """Compare mapped content, load commands and dyld payloads independent of symbol offsets."""
    digest = hashlib.sha256()
    with path.open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as image:
        macho_device_platform(image)  # Checks arm64 MH_EXECUTE, iOS and all load-command bounds.
        with memoryview(image) as data:
            def include(start, size):
                if start + size > len(data):
                    raise ValueError("Mach-O payload extends past the executable")
                digest.update(struct.pack("<Q", size))
                digest.update(data[start:start + size])

            include(0, 16)  # Magic, CPU/subtype and file type.
            include(24, 8)  # Executable flags and reserved word.
            offset = 32
            for _ in range(struct.unpack_from("<I", data, 16)[0]):
                cmd, length = struct.unpack_from("<II", data, offset)
                if cmd == 0x19:  # LC_SEGMENT_64
                    if length < 72:
                        raise ValueError("Truncated 64-bit segment")
                    name = bytes(data[offset + 8:offset + 24]).rstrip(b"\0")
                    if name == b"__LINKEDIT":
                        include(offset, 32)
                        include(offset + 40, 8)
                        include(offset + 56, length - 56)  # Only mapped/file sizes can shrink.
                    elif name != b"__DWARF":
                        sections = struct.unpack_from("<I", data, offset + 64)[0]
                        if 72 + 80 * sections != length:
                            raise ValueError("Invalid 64-bit segment section table")
                        include(offset, length)  # VM addresses, protections and section layout.
                        for section in range(offset + 72, offset + length, 80):
                            size, start = struct.unpack_from("<QI", data, section + 40)
                            flags = struct.unpack_from("<I", data, section + 64)[0]
                            if (flags & 0xff) not in (0x1, 0xc, 0x12):  # zero-fill sections have no file bytes.
                                include(start, size)
                elif cmd in (0x22, 0x80000022):  # LC_DYLD_INFO[_ONLY]: rebase/bind/weak/lazy/export.
                    digest.update(struct.pack("<I", cmd))
                    if length != 48:
                        raise ValueError("Invalid dyld info command")
                    for pair in range(offset + 8, offset + length, 8):
                        include(*struct.unpack_from("<II", data, pair))
                elif cmd in (0x26, 0x29, 0x80000033, 0x80000034):  # function starts, data-in-code, exports, chained fixups.
                    digest.update(struct.pack("<I", cmd))
                    if length != 16:
                        raise ValueError("Invalid link-edit data command")
                    include(*struct.unpack_from("<II", data, offset + 8))
                elif cmd not in (0x2, 0xb, 0x1d):  # SYMTAB/DYSYMTAB offsets and the previous signature can change.
                    include(offset, length)
                offset += length
    return digest.hexdigest()


def external_symbols_digest(path):
    # Darwin format includes addresses, sections, weakness and import libraries. The
    # full sorted symbol listing for the production app is large; stream it.
    digest = hashlib.sha256()
    command = ["xcrun", "nm", "-g", "-m", "--no-dyldinfo", str(path)]
    with subprocess.Popen(command, stdout=subprocess.PIPE) as tool:
        for block in iter(lambda: tool.stdout.read(1024 * 1024), b""):
            digest.update(block)
        if tool.wait():
            raise subprocess.CalledProcessError(tool.returncode, command)
    if digest.digest() == hashlib.sha256().digest():
        raise ValueError("Empty external symbol table for the app")
    return digest.hexdigest()


def arm64_uuid(path):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path)], text=True)
    match = re.fullmatch(r"UUID: ([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}) \(arm64\) [^\n]+\n?", output)
    if not match:
        raise ValueError(f"Expected one arm64 UUID in {path.name}")
    return match[1].upper()


def file_state(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"Expected a regular file: {path.name}")
    return info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def strip_staged_main(raw_app, staged_app, dsym):
    name = plistlib.loads((raw_app / "Info.plist").read_bytes())["CFBundleExecutable"]
    staged_name = plistlib.loads((staged_app / "Info.plist").read_bytes())["CFBundleExecutable"]
    if not name or name != Path(name).name or name in (".", "..") or staged_name != name:
        raise ValueError("Invalid or inconsistent main executable name")
    raw, staged = raw_app / name, staged_app / name
    dwarf = dsym / "Contents/Resources/DWARF" / name
    states = {path: file_state(path) for path in (raw, staged, dwarf)}
    mode = stat.S_IMODE(staged.stat().st_mode)
    if raw.samefile(staged) or not mode & 0o111 or mode != stat.S_IMODE(raw.stat().st_mode):
        raise ValueError("Expected a separate staged executable with its original permissions")
    raw_sha = digest_file(raw)
    if raw_sha != digest_file(staged):
        raise ValueError("Staged main differs from the preserved raw executable")
    uuid = arm64_uuid(raw)
    dsym_uuid = arm64_uuid(dwarf)
    if dsym_uuid != uuid:
        raise ValueError("Main executable and dSYM UUIDs differ")
    with dwarf.open("rb") as data:
        header = data.read(16)
    if len(header) != 16 or struct.unpack_from("<I", header, 12)[0] != 0xa:  # MH_DSYM
        raise ValueError("Expected a DWARF debug-symbol companion")
    sections = subprocess.check_output(["xcrun", "size", "-m", str(dwarf)], text=True)
    if not re.search(r"(?m)^\s*Section __debug_info: [1-9][0-9]*\b", sections):
        raise ValueError("Missing DWARF debug information in the matching dSYM")
    runtime = runtime_digest(raw)
    symbols = external_symbols_digest(raw)
    with tempfile.TemporaryDirectory(prefix=".floe-strip-", dir=staged.parent) as scratch:
        candidate = Path(scratch) / name
        subprocess.run(["xcrun", "strip", "-S", "-x", "-o", str(candidate), str(staged)], check=True)
        if arm64_uuid(candidate) != uuid or runtime_digest(candidate) != runtime:
            raise ValueError("Stripping changed the app UUID, runtime contents or loader metadata")
        if external_symbols_digest(candidate) != symbols:
            raise ValueError("Stripping changed the app's external symbols")
        candidate.chmod(mode)
        if stat.S_IMODE(candidate.stat().st_mode) != mode or candidate.stat().st_size > raw.stat().st_size:
            raise ValueError("Unexpected stripped executable mode or size")
        report = {"uuid": uuid, "dsym_uuid": dsym_uuid,
                  "bytes_before": raw.stat().st_size, "bytes_after": candidate.stat().st_size,
                  "raw_sha256": raw_sha, "stripped_sha256": digest_file(candidate),
                  "runtime_sha256": runtime, "external_symbols_sha256": symbols}
        if any(file_state(path) != before for path, before in states.items()):
            raise ValueError("A packaging input changed during stripping")
        os.replace(candidate, staged)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("raw_app", "staged_app", "dsym"):
        parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    print(json.dumps(strip_staged_main(args.raw_app, args.staged_app, args.dsym)))
