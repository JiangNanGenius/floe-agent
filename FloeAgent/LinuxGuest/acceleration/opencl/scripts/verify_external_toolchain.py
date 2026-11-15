#!/usr/bin/env python3
"""Strict source-host admission for the externally supplied OpenCL compiler.

The runtime-only CLVK profile never builds or links clspv/LLVM. It does keep
clCreateProgramWithSource/clBuildProgram by executing a separately supplied
ARM64 Linux clspv process. This validator checks the immutable bytes and the
declared provenance/ABI compatibility of that process. It never executes the
compiler, never loads the ICD and never contacts a device.

A manifest is an owner-supplied attestation. The checks below prove ABI shape,
immutable bytes and declared pin agreement; they cannot prove the binary's
origin. That limitation is reported explicitly.
"""
import argparse
import hashlib
import json
import os
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PINS = ROOT / "PINS.json"

ELF_MAGIC = b"\x7fELF"
PT_LOAD = 1
PT_DYNAMIC = 2
PT_INTERP = 3
DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_STRSZ = 10
DT_SONAME = 14
DT_RPATH = 15
DT_RUNPATH = 29


class ElfError(Exception):
    pass


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _read_cstr(data: bytes, offset: int) -> str:
    if offset < 0 or offset >= len(data):
        raise ElfError(f"string offset out of range: {offset}")
    end = data.find(b"\x00", offset)
    if end < 0:
        raise ElfError(f"unterminated string at offset {offset}")
    return data[offset:end].decode("utf-8", "strict")


def parse_elf64(path: pathlib.Path):
    data = path.read_bytes()
    if len(data) < 64:
        raise ElfError("file is shorter than an ELF64 header")
    if data[:4] != ELF_MAGIC:
        raise ElfError("not an ELF (magic mismatch)")
    ei_class, ei_data = data[4], data[5]
    if ei_class != 2:
        raise ElfError(f"not ELF64 (EI_CLASS={ei_class})")
    if ei_data != 1:
        raise ElfError(f"not little-endian (EI_DATA={ei_data})")
    (e_type, e_machine, e_version, _e_entry, e_phoff, _e_shoff, _e_flags,
     _e_ehsize, e_phentsize, e_phnum, _e_shentsize, _e_shnum,
     _e_shstrndx) = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    if e_version != 1:
        raise ElfError(f"unexpected e_version={e_version}")
    if e_phentsize != 56:
        raise ElfError(f"unexpected program header size {e_phentsize}")
    if e_phnum == 0:
        raise ElfError("no program headers")
    if e_phoff + e_phnum * e_phentsize > len(data):
        raise ElfError("program header table escapes the file")

    loads = []
    interp = None
    dynamic = None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        (p_type, _p_flags, p_offset, p_vaddr, _p_paddr, p_filesz, p_memsz,
         _p_align) = struct.unpack_from("<IIQQQQQQ", data, off)
        if p_offset + p_filesz > len(data):
            raise ElfError(f"segment {i} escapes the file")
        if p_type == PT_LOAD:
            loads.append((p_vaddr, p_offset, p_filesz, p_memsz))
        elif p_type == PT_INTERP:
            interp = _read_cstr(data, p_offset)
        elif p_type == PT_DYNAMIC:
            dynamic = (p_offset, p_filesz)

    needed = []
    soname = None
    runpaths = []
    dyn_tag_names = []
    if dynamic is not None:
        dyn_off, dyn_size = dynamic
        entries = []
        for off in range(dyn_off, dyn_off + dyn_size - (dyn_size % 16), 16):
            d_tag, d_val = struct.unpack_from("<qQ", data, off)
            if d_tag == DT_NULL:
                break
            entries.append((d_tag, d_val))
        strtab = None
        strsz = None
        for d_tag, d_val in entries:
            if d_tag == DT_STRTAB:
                strtab = d_val
            elif d_tag == DT_STRSZ:
                strsz = d_val
        if any(d_tag in (DT_NEEDED, DT_SONAME, DT_RPATH, DT_RUNPATH)
               for d_tag, _ in entries):
            if strtab is None or strsz is None:
                raise ElfError("dynamic name tags without a valid DT_STRTAB/DT_STRSZ")

            def map_vaddr(vaddr):
                for p_vaddr, p_offset, p_filesz, p_memsz in loads:
                    if p_vaddr <= vaddr < p_vaddr + p_filesz:
                        return p_offset + (vaddr - p_vaddr)
                raise ElfError(f"virtual address 0x{vaddr:x} has no file-backed segment")

            str_off = map_vaddr(strtab)
            if str_off + strsz > len(data):
                raise ElfError("DT_STRTAB escapes the file")
            string_table = data[str_off:str_off + strsz]

            def dyn_string(offset):
                if offset >= len(string_table):
                    raise ElfError(f"dynamic string offset {offset} escapes DT_STRTAB")
                end = string_table.find(b"\x00", offset)
                if end < 0:
                    raise ElfError("unterminated dynamic string")
                return string_table[offset:end].decode("utf-8", "strict")

            for d_tag, d_val in entries:
                if d_tag == DT_NEEDED:
                    needed.append(dyn_string(d_val))
                elif d_tag == DT_SONAME:
                    soname = dyn_string(d_val)
                elif d_tag in (DT_RPATH, DT_RUNPATH):
                    runpaths.append(dyn_string(d_val))
                dyn_tag_names.append(hex(d_tag))
    return {
        "bytes": len(data),
        "elfclass": 64,
        "littleEndian": True,
        "type": e_type,
        "machine": e_machine,
        "phnum": e_phnum,
        "interpreter": interp,
        "needed": needed,
        "soname": soname,
        "runpaths": runpaths,
        "dynamicTags": sorted(set(dyn_tag_names)),
    }


def load_manifest(path: pathlib.Path):
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"manifest is not valid JSON: {exc}")
    if data.get("schema") != 1:
        raise SystemExit(f"manifest schema must be 1, got {data.get('schema')!r}")
    for key in ("tool", "target", "artifact", "provenance"):
        if key not in data:
            raise SystemExit(f"manifest missing required key: {key}")
    return data


def resolve_artifact(manifest_path: pathlib.Path, manifest, override, stage_root):
    raw = override or manifest["artifact"].get("path")
    if not raw:
        raise SystemExit("manifest artifact.path is empty and --artifact was not supplied")
    p = pathlib.Path(raw)
    if not p.is_absolute():
        p = (manifest_path.parent / p)
    p = p.absolute()
    if stage_root is not None:
        stage = stage_root.resolve()
        expected = (stage / "usr/lib/floe-opencl" / manifest["tool"]).resolve()
        resolved = p.resolve()
        if resolved != expected:
            raise SystemExit(
                f"staged artifact must be {expected}, got {resolved}")
        try:
            resolved.relative_to(stage)
        except ValueError:
            raise SystemExit(f"artifact escapes stage root: {resolved}")
    return p


def validate(manifest_path: pathlib.Path, pins, artifact_override=None,
             stage_root=None, tool_override=None):
    manifest = load_manifest(manifest_path)
    tool = tool_override or manifest["tool"]
    errors = []
    checks = []

    def check(name, condition, detail=None):
        entry = {"check": name, "ok": bool(condition)}
        if detail is not None:
            entry["detail"] = detail
        checks.append(entry)
        if not condition:
            errors.append(f"{name}: {detail}" if detail else name)

    admission = pins["externalCompilerAdmission"]
    required = admission["requiredProvenance"]
    prov = manifest.get("provenance", {})
    check("tool", manifest.get("tool") == tool,
          f"manifest tool={manifest.get('tool')!r} expected={tool!r}")
    check("target", manifest.get("target") == admission["target"],
          f"target={manifest.get('target')!r} expected={admission['target']!r}")
    for key in ("clvkCommit", "clspvCommit", "llvmCommit", "reflectionABI"):
        check(f"provenance.{key}", prov.get(key) == required[key],
              f"{prov.get(key)!r} != {required[key]!r}")
    check("provenance.producer", bool(prov.get("producer")),
          "producer attestation identity is required")
    check("provenance.builtUTC", bool(prov.get("builtUTC")),
          "build timestamp is required")
    declared_oc = set(prov.get("openCLCVersions") or [])
    check("provenance.openCLCVersions",
          set(required["openCLCVersions"]).issubset(declared_oc),
          f"declared={sorted(declared_oc)} required={required['openCLCVersions']}")
    declared_arch = set(prov.get("spirvArchitectures") or [])
    check("provenance.spirvArchitectures",
          set(required["spirvArchitectures"]).issubset(declared_arch),
          f"declared={sorted(declared_arch)} required={required['spirvArchitectures']}")
    version = manifest.get("version") or ""
    check("version.marker", tool in version,
          f"declared version {version!r} must contain {tool!r}")
    libclc = prov.get("libclc") or {}
    if libclc.get("embedded") is True:
        check("libclc.embeddedCommit",
              libclc.get("commit") == required["llvmCommit"],
              f"libclc commit={libclc.get('commit')!r} expected={required['llvmCommit']!r}")
    else:
        files = libclc.get("files") or []
        check("libclc.files", bool(files),
              "non-embedded libclc requires a non-empty files list with hashes")
        for item in files:
            fp = pathlib.Path(item.get("path", ""))
            if not fp.is_absolute():
                fp = manifest_path.parent / fp
            ok = fp.is_file() and sha256_file(fp) == item.get("sha256")
            check(f"libclc.file:{item.get('path')}", ok,
                  f"missing or hash mismatch: {fp}")

    try:
        artifact = resolve_artifact(manifest_path, manifest, artifact_override, stage_root)
    except SystemExit as exc:
        errors.append(str(exc))
        return {"ok": False, "tool": tool, "errors": errors, "checks": checks,
                "manifest": str(manifest_path)}

    declared = manifest.get("artifact", {})
    checks_artifact = {
        "path": str(artifact),
        "expectedBytes": declared.get("bytes"),
        "expectedSHA256": declared.get("sha256"),
    }
    if not artifact.is_file():
        errors.append(f"artifact missing: {artifact}")
        return {"ok": False, "tool": tool, "errors": errors, "checks": checks,
                "artifact": checks_artifact, "manifest": str(manifest_path)}
    if artifact.is_symlink():
        errors.append(f"artifact must not be a symlink: {artifact}")
    mode = artifact.stat().st_mode
    check("artifact.regular", artifact.is_file(), str(artifact))
    check("artifact.executable", bool(mode & 0o111), oct(mode & 0o777))
    check("artifact.readable", bool(mode & 0o444), oct(mode & 0o777))
    actual_bytes = artifact.stat().st_size
    actual_sha = sha256_file(artifact)
    check("artifact.bytes", actual_bytes == declared.get("bytes"),
          f"{actual_bytes} != {declared.get('bytes')}")
    check("artifact.sha256", actual_sha == declared.get("sha256"),
          f"{actual_sha} != {declared.get('sha256')}")
    checks_artifact.update({"bytes": actual_bytes, "sha256": actual_sha})

    try:
        elf = parse_elf64(artifact)
    except ElfError as exc:
        errors.append(f"artifact ELF: {exc}")
        return {"ok": False, "tool": tool, "errors": errors, "checks": checks,
                "artifact": checks_artifact, "manifest": str(manifest_path)}
    checks_artifact["elf"] = elf
    check("elf.machine", elf["machine"] == admission["elf"]["machine"],
          f"{elf['machine']} != {admission['elf']['machine']}")
    check("elf.type", elf["type"] in admission["elf"]["allowedTypes"],
          f"type={elf['type']} allowed={admission['elf']['allowedTypes']}")
    is_static = declared.get("static") is True
    if is_static:
        check("elf.static", elf["interpreter"] is None and not elf["needed"],
              "static declaration requires no PT_INTERP and no DT_NEEDED")
    else:
        check("elf.interpreter",
              elf["interpreter"] in admission["elf"]["allowedInterpreters"],
              f"interpreter={elf['interpreter']!r} "
              f"allowed={admission['elf']['allowedInterpreters']}")
    check("elf.runpath", not elf["runpaths"],
          f"RPATH/RUNPATH is not allowed: {elf['runpaths']}")
    forbidden = admission["elf"]["forbiddenNeededPrefixes"]
    bad = [n for n in elf["needed"] if any(n.startswith(p) for p in forbidden)]
    check("elf.forbiddenNeeded", not bad, f"{bad}")
    allowed_needed = set(admission["elf"]["allowedNeededBasenames"])
    unknown = [n for n in elf["needed"] if n not in allowed_needed]
    check("elf.allowedNeeded", not unknown,
          f"undeclared dependencies {unknown}; allowed={sorted(allowed_needed)}")

    marker = declared.get("requiredMarker") or admission.get("requiredEmbeddedMarker")
    if marker:
        hay = artifact.read_bytes()
        check("artifact.marker", marker.encode() in hay,
              f"required embedded marker {marker!r} not found")

    result = {
        "schema": 1,
        "status": "pass" if not errors else "fail",
        "ok": not errors,
        "tool": tool,
        "manifest": str(manifest_path),
        "artifact": checks_artifact,
        "checks": checks,
        "errors": errors,
        "executedArtifact": False,
        "limitations": admission.get("limitations", []),
    }
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=pathlib.Path, required=True)
    ap.add_argument("--pins", type=pathlib.Path, default=DEFAULT_PINS)
    ap.add_argument("--artifact", type=pathlib.Path,
                    help="actual candidate file to validate (defaults to manifest artifact.path)")
    ap.add_argument("--stage-root", type=pathlib.Path,
                    help="require artifact at <stage>/usr/lib/floe-opencl/<tool>")
    ap.add_argument("--tool", choices=("clspv", "llvm-spirv"))
    ap.add_argument("--out", type=pathlib.Path)
    args = ap.parse_args()
    pins = json.loads(args.pins.read_text())
    result = validate(args.manifest, pins, args.artifact, args.stage_root, args.tool)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text)
    print(text, end="")
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
