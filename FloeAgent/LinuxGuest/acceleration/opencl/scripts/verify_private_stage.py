#!/usr/bin/env python3
"""Validate the staged private ICD symlink without executing it.

The critical regression here is that `file symlink` reports the link itself,
not the ELF. This helper resolves the link inside the private libdir, parses
the target ELF header/SONAME, and rejects escapes or wrong targets.
"""
import argparse
import hashlib
import json
import os
import pathlib
import sys

try:
    from elftools.elf.elffile import ELFFile
except Exception as exc:
    print(f"pyelftools required: {exc}", file=sys.stderr)
    sys.exit(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--libdir", required=True)
    ap.add_argument("--expected-soname")
    args = ap.parse_args()
    libdir = pathlib.Path(args.libdir).resolve()
    link = libdir / "libfloe_clvk.so.1"
    result = {"libdir": str(libdir), "link": str(link), "ok": False, "errors": []}
    if not libdir.is_dir():
        result["errors"].append("private libdir missing")
    elif not link.is_symlink():
        result["errors"].append("libfloe_clvk.so.1 is not a symlink")
    else:
        raw_target = os.readlink(link)
        result["target"] = raw_target
        try:
            real = (link.parent / raw_target).resolve(strict=True)
        except OSError as exc:
            result["errors"].append(f"broken symlink: {exc}")
            real = None
        if real is not None:
            result["real"] = str(real)
            if real.parent != libdir:
                result["errors"].append("symlink target escapes the private libdir")
            if not real.is_file():
                result["errors"].append("symlink target is not a regular file")
            else:
                data = real.read_bytes()
                result["sha256"] = hashlib.sha256(data).hexdigest()
                result["bytes"] = len(data)
                try:
                    with real.open("rb") as f:
                        elf = ELFFile(f)
                        soname = None
                        dyn = elf.get_section_by_name(".dynamic")
                        if dyn is not None:
                            for tag in dyn.iter_tags():
                                if tag.entry.d_tag == "DT_SONAME":
                                    soname = tag.soname
                        machine = elf.header.e_machine
                        etype = elf.header.e_type
                        machine = 183 if machine in (183, "EM_AARCH64") else machine
                        etype = 3 if etype in (3, "ET_DYN") else etype
                        result.update({
                            "elfclass": elf.elfclass,
                            "little_endian": elf.little_endian,
                            "machine": machine,
                            "type": etype,
                            "soname": soname,
                        })
                except Exception as exc:
                    result["errors"].append(f"target is not a parseable ELF: {exc}")
                else:
                    if result.get("elfclass") != 64 or result.get("machine") != 183 \
                            or result.get("type") != 3 or not result.get("little_endian"):
                        result["errors"].append("target is not ELF64 LSB AArch64 ET_DYN")
                    if args.expected_soname and result.get("soname") != args.expected_soname:
                        result["errors"].append(
                            f"SONAME mismatch: {result.get('soname')!r} != {args.expected_soname!r}")
    result["ok"] = not result["errors"]
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
