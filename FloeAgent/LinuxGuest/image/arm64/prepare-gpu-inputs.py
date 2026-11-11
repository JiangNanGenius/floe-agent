#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Extend a boot-input lock with GPU modules from its exact pinned kernel.

Creates a new candidate lock, never changes the input recipe or an image.
--check is read-only. This does not qualify, boot or publish an image.
"""
import sys
sys.dont_write_bytecode = True

import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import lzma
import struct


# Dependency order matters: init loads modules in filename order.
GPU_MODULES = (
    "drm.ko", "drm_kms_helper.ko", "drm_shmem_helper.ko",
    "virtio_dma_buf.ko", "virtio-gpu.ko",
)


def canonical(name):
    return name.removesuffix(".ko").replace("-", "_")


def module_info(data):
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != 183:
        raise ValueError("Kernel module must be little-endian ARM64 ELF")
    offset = struct.unpack_from("<Q", data, 40)[0]
    width, count, names_index = struct.unpack_from("<HHH", data, 58)
    if width != 64 or not count or names_index >= count or offset + width * count > len(data):
        raise ValueError("Invalid ELF section table")

    def section(index):
        fields = struct.unpack_from("<IIQQQQIIQQ", data, offset + index * width)
        if fields[4] > len(data) or fields[5] > len(data) - fields[4]:
            # NOBITS has no bytes in the file; it is never .modinfo/.shstrtab.
            if fields[1] != 8:
                raise ValueError("ELF section escapes module")
        return fields

    names = section(names_index)
    if names[1] != 3:
        raise ValueError("Missing ELF string table")
    strings = data[names[4]:names[4] + names[5]]
    for index in range(count):
        fields = section(index)
        if fields[0] >= len(strings):
            raise ValueError("Invalid ELF section name")
        if strings[fields[0]:].split(b"\0", 1)[0] == b".modinfo":
            if fields[1] != 1:
                raise ValueError("Invalid module information section")
            result = {}
            for field in data[fields[4]:fields[4] + fields[5]].split(b"\0"):
                if b"=" in field:
                    key, value = field.decode("utf-8").split("=", 1)
                    result.setdefault(key, []).append(value)
            return result
    raise ValueError("Missing module information")


def make_candidate(pins, archive):
    wanted = set(GPU_MODULES)
    selected = {}
    for member in archive:
        basename = Path(member.name).name.removesuffix(".xz")
        if basename not in wanted:
            continue
        if basename in selected or not member.isfile() or member.size > 16 * 1024 * 1024:
            raise ValueError("Unexpected or duplicate kernel module: " + basename)
        data = archive.extractfile(member).read()
        if member.name.endswith(".xz"):
            data = lzma.decompress(data, memlimit=128 * 1024 * 1024)
        selected[basename] = (data, module_info(data))
    if selected.keys() != wanted:
        raise ValueError("Missing kernel GPU modules: " + ", ".join(sorted(wanted - selected.keys())))

    result = copy.deepcopy(pins)
    available = {canonical(Path(row["name"]).name.split("-", 1)[1]) for row in pins["modules"]}
    used_paths = {row["name"] for row in pins["modules"]}
    existing = {canonical(Path(row["name"]).name.split("-", 1)[1]): row for row in pins["modules"]}
    vermagic = set()
    additions = []
    for index, name in enumerate(GPU_MODULES, 80):
        data, info = selected[name]
        dependencies = set(filter(None, ",".join(info.get("depends", [])).split(",")))
        if not dependencies <= available:
            raise ValueError("Unresolved module dependency for " + name + ": " + ", ".join(sorted(dependencies - available)))
        versions = info.get("vermagic", [])
        if len(versions) != 1:
            raise ValueError("Missing or ambiguous module vermagic")
        vermagic.add(versions[0])
        digest = hashlib.sha256(data).hexdigest()
        key = canonical(name)
        if key in existing:
            if existing[key]["sha256"] != digest:
                raise ValueError("Existing module pin differs: " + name)
        else:
            path = f"lib/modules/{index:02d}-{name}"
            if path in used_paths:
                raise ValueError("Initrd module path already occupied: " + path)
            row = {"name": path, "sha256": digest}
            result["modules"].append(row)
            additions.append(row)
            used_paths.add(path)
        available.add(key)
    if len(vermagic) != 1:
        raise ValueError("Kernel modules do not share a build identity")
    return result, additions, next(iter(vermagic))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--boot-inputs", type=Path, help="May include the online-memory candidate's extra pins")
    parser.add_argument("--kernel-deb", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.boot_inputs or args.recipe / "boot-inputs.json"
    if args.out.resolve() == source.resolve():
        raise ValueError("Output must not replace the input lock")
    pins = json.loads(source.read_text())
    spec = importlib.util.spec_from_file_location("floe_boot_input_builder", args.recipe / "build-initrd.py")
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    with builder.deb_tar(args.kernel_deb, pins["kernelModules"]["packageSHA256"]) as archive:
        candidate, additions, vermagic = make_candidate(pins, archive)
    if args.check:
        if json.loads(args.out.read_text()) != candidate:
            raise ValueError("Candidate boot-input lock does not match pinned kernel modules")
    else:
        with args.out.open("x") as output:
            output.write(json.dumps(candidate, indent=2) + "\n")
    print(json.dumps({"readOnlyCheck": args.check, "addedModules": len(additions),
                      "vermagic": vermagic, "qualified": False}))


if __name__ == "__main__":
    main()
