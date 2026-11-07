#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Remove packaging-only LLVM IR; preserve native code, symbols and DWARF."""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inspect(path, details=False):
    archive = path.read_bytes()
    if not archive.startswith(b"!<arch>\n"):
        raise ValueError("Expected a regular static ar archive")
    position, objects, member_counts = 8, [], collections.Counter()
    debug_bytes = bitcode_bytes = 0
    bitcode_sections, debug_sections = set(), []
    while position < len(archive):
        header = archive[position:position + 60]
        if len(header) != 60 or header[58:] != b"`\n":
            raise ValueError("Invalid ar member")
        name = header[:16].decode("ascii").strip()
        size = int(header[48:58])
        data = archive[position + 60:position + 60 + size]
        position += 60 + size + (size % 2)
        if name.startswith("#1/"):
            length = int(name[3:])
            name, data = data[:length].split(b"\0", 1)[0].decode(), data[length:]
        else:
            name = name.rstrip("/")
        if name.startswith("__.SYMDEF") or name in ["", "/"]:
            continue
        if data[:4] != b"\xcf\xfa\xed\xfe":
            raise ValueError("Expected native Mach-O object: " + name)
        _, cpu, subtype, filetype, commands, _, _, _ = struct.unpack_from("<IiiIIIII", data)
        if filetype != 1:
            raise ValueError("Expected MH_OBJECT: " + name)
        sections, names, symbols, platform = [], [], [], []
        command_offset, symtab = 32, None
        for _ in range(commands):
            command, length = struct.unpack_from("<II", data, command_offset)
            if command == 0x19:
                count = struct.unpack_from("<I", data, command_offset + 64)[0]
                for index in range(count):
                    offset = command_offset + 72 + index * 80
                    section, segment, _, section_size, file_offset, _, _, _, flags, _, _, _ = struct.unpack_from("<16s16sQQIIIIIIII", data, offset)
                    section, segment = section.rstrip(b"\0").decode(), segment.rstrip(b"\0").decode()
                    names.append((segment, section))
                    if segment == "__DWARF":
                        debug_bytes += section_size
                        debug_sections.append((name, section, section_size, digest(data[file_offset:file_offset + section_size])))
                        continue
                    if segment == "__LLVM":
                        bitcode_bytes += section_size
                        bitcode_sections.add(segment + "," + section)
                        continue
                    zero_fill = flags & 0xff in [1, 0xc, 0x12]
                    payload = b"ZERO-FILL" if zero_fill else data[file_offset:file_offset + section_size]
                    if not zero_fill and len(payload) != section_size:
                        raise ValueError("Invalid section bounds")
                    sections.append((segment, section, section_size, flags, digest(payload)))
            elif command == 2:
                symtab = struct.unpack_from("<IIII", data, command_offset + 8)
            elif command in [0x24, 0x25, 0x2f, 0x30, 0x32]:
                platform.append(digest(data[command_offset:command_offset + length]))
            command_offset += length
        if symtab is None:
            raise ValueError("Native object has no symbol table")
        symbol_offset, count, string_offset, string_size = symtab
        strings = data[string_offset:string_offset + string_size]
        def string_at(index):
            if index >= len(strings):
                raise ValueError("Invalid symbol name")
            return strings[index:].split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
        for index in range(count):
            string_index, kind, section, description, value = struct.unpack_from("<IBBHQ", data, symbol_offset + index * 16)
            if kind & 0xe0:  # STAB debug symbol
                continue
            if section and names[section - 1][0] in ["__DWARF", "__LLVM"]:
                continue
            alias = string_at(value) if kind & 0x0e == 0x0a else None
            symbols.append((string_at(string_index), kind, description, alias))
        occurrence = member_counts[name]
        member_counts[name] += 1
        objects.append((name, occurrence, cpu, subtype, sorted(sections), sorted(symbols), platform))
    canonical = json.dumps(sorted(objects), ensure_ascii=True, separators=(",", ":")).encode()
    result = {"sha256": digest(archive), "byteCount": len(archive), "nativeObjectCount": len(objects),
            "runtimeSectionsAndSymbolsSha256": digest(canonical), "dwarfSectionBytes": debug_bytes,
            "embeddedLLVMSectionBytes": bitcode_bytes, "embeddedLLVMSectionNames": sorted(bitcode_sections),
            "dwarfSectionsSha256": digest(json.dumps(sorted(debug_sections), separators=(",", ":")).encode())}
    if details:
        result["objects"] = objects
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("receipt", type=Path)
    arguments = parser.parse_args()
    source = arguments.source.resolve()
    destination = arguments.destination.resolve()
    if source == destination:
        raise ValueError("Preserve the raw producer archive separately")
    before = inspect(source, True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="font-normalize-", dir=destination.parent) as temporary:
        candidate = Path(temporary) / "consumer.a"
        bitcode = subprocess.run(["xcrun", "bitcode_strip", str(source), "-r", "-o", str(candidate)], capture_output=True, text=True)
        tool = "Apple bitcode_strip -r"
        if bitcode.returncode:
            # Xcode 27's bitcode_strip delegates MH_OBJECT/ar edits to the
            # removed ld -bitcode_process_mode option. Use the installed Rust
            # LLVM tool on each archive member, with the same verification.
            sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
            version = subprocess.check_output(["rustc", "-vV"], text=True)
            host = next(line.split(": ", 1)[1] for line in version.splitlines() if line.startswith("host: "))
            objcopy = sysroot / "lib" / "rustlib" / host / "bin" / "llvm-objcopy"
            if not objcopy.is_file():
                raise RuntimeError("bitcode_strip failed and installed Rust LLVM objcopy is unavailable")
            subprocess.run([str(objcopy), *["--remove-section=" + section for section in before["embeddedLLVMSectionNames"]], str(source), str(candidate)], check=True)
            tool = "Rust toolchain LLVM objcopy: remove recorded __LLVM sections (Apple ld option unavailable)"
        after = inspect(candidate, True)
        if before["runtimeSectionsAndSymbolsSha256"] != after["runtimeSectionsAndSymbolsSha256"]:
            first = {(v[0], v[1]): v[2:] for v in before["objects"]}
            second = {(v[0], v[1]): v[2:] for v in after["objects"]}
            changes = []
            for key in sorted(first.keys() | second.keys()):
                a, b = first.get(key), second.get(key)
                if a == b:
                    continue
                changes.append({"member": key, "missingBefore": a is None, "missingAfter": b is None,
                    "cpuChanged": a[:2] != b[:2] if a and b else None,
                    "sectionsRemoved": list(set(a[2]) - set(b[2]))[:4] if a and b else None,
                    "sectionsAdded": list(set(b[2]) - set(a[2]))[:4] if a and b else None,
                    "symbolsRemoved": list(set(a[3]) - set(b[3]))[:4] if a and b else None,
                    "symbolsAdded": list(set(b[3]) - set(a[3]))[:4] if a and b else None,
                    "platformChanged": a[4] != b[4] if a and b else None})
                if len(changes) == 4:
                    break
            print(json.dumps({"verificationFailure": changes}), flush=True)
            raise ValueError("Native runtime sections, platform or non-STAB symbols changed")
        if before["nativeObjectCount"] != after["nativeObjectCount"] or after["embeddedLLVMSectionBytes"]:
            raise ValueError("Incomplete archive normalization")
        if before["dwarfSectionBytes"] != after["dwarfSectionBytes"] or before["dwarfSectionsSha256"] != after["dwarfSectionsSha256"]:
            raise ValueError("Debug information changed")
        os.replace(candidate, destination)
    del before["objects"], after["objects"]
    receipt = {"recipe": [tool], "raw": before, "consumer": after,
               "runtimeSectionsPlatformAndNonSTABSymbolsPreserved": True, "debugInformationPreserved": True}
    arguments.receipt.parent.mkdir(parents=True, exist_ok=True)
    arguments.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
