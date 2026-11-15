#!/usr/bin/env python3
"""Assemble the private runtime-only floe-opencl-clvk .deb.

The stage must come from build_clvk_runtime_aarch64.sh. Packaging is refused
unless a verified external clspv manifest and the corresponding immutable
staged executable are present. A runtime stage without a compiler is a valid
component artifact, never a packageable/advertised source-compiling runtime.

This script does not build, download, install or execute anything.
"""
import argparse
import hashlib
import io
import json
import lzma
import os
import pathlib
import re
import sys
import tarfile

try:
    from elftools.elf.elffile import ELFFile
except Exception as exc:  # pragma: no cover
    print(f"pyelftools is required: {exc}", file=sys.stderr)
    sys.exit(2)

ROOT = pathlib.Path(__file__).resolve().parent.parent
PINS = json.loads((ROOT / "PINS.json").read_text())
LICENSES = json.loads((ROOT / "licenses" / "LICENSES.json").read_text())
REQUIRED_LICENSE_FILES = [
    "clvk-LICENSE", "clspv-LICENSE", "llvm-LICENSE.TXT", "libclc-LICENSE.TXT",
    "opencl-headers-LICENSE", "spirv-headers-LICENSE", "spirv-tools-LICENSE",
    "spirv-llvm-translator-LICENSE.TXT", "ocl-icd-COPYING", "vulkan-headers-LICENSE.md",
]
REQUIRED_DYN_SYMBOLS = [
    "clGetPlatformIDs", "clGetPlatformInfo", "clGetExtensionFunctionAddress",
    "clBuildProgram", "clCreateProgramWithSource",
]
PATCH_FILES = [
    "0001-floe-private-icd-output-name.patch",
    "0002-floe-external-clspv-runtime.patch",
    "0003-floe-runtime-compiler-admission.patch",
    "0004-floe-il-disabled-api-honesty.patch",
]


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fail(message: str):
    print(message, file=sys.stderr)
    raise SystemExit(2)


def elf_info(path: pathlib.Path):
    info = {"path": str(path), "sha256": sha256(path), "bytes": path.stat().st_size}
    with path.open("rb") as f:
        elf = ELFFile(f)
        machine = elf.header.e_machine
        etype = elf.header.e_type
        info.update({
            "elfclass": elf.elfclass,
            "little_endian": elf.little_endian,
            "machine": 183 if machine in (183, "EM_AARCH64") else machine,
            "type": 3 if etype in (3, "ET_DYN") else etype,
        })
        dyn = elf.get_section_by_name(".dynamic")
        if dyn is None:
            fail(f"no .dynamic section: {path}")
        needed = []
        soname = None
        for tag in dyn.iter_tags():
            if tag.entry.d_tag == "DT_NEEDED":
                needed.append(tag.needed)
            elif tag.entry.d_tag == "DT_SONAME":
                soname = tag.soname
        info["needed"] = needed
        info["soname"] = soname
        symbols = set()
        for secname in (".dynsym", ".symtab"):
            sec = elf.get_section_by_name(secname)
            if sec is not None:
                symbols.update(sym.name for sym in sec.iter_symbols() if sym.name)
        info["symbols"] = sorted(symbols)
    return info


def resolve_link(path: pathlib.Path):
    if not path.is_symlink():
        fail(f"expected symlink: {path}")
    target = pathlib.Path(os.readlink(path))
    real = (path.parent / target).resolve()
    if not real.is_file():
        fail(f"broken symlink: {path} -> {target}")
    return real


def find_private_lib(stage: pathlib.Path):
    libdir = stage / "usr/lib/floe-opencl"
    link = libdir / "libfloe_clvk.so.1"
    if not link.exists():
        fail(f"missing ICD symlink: {link}")
    real = resolve_link(link)
    if real.parent != libdir.resolve():
        fail(f"ICD symlink escapes private libdir: {link} -> {real}")
    return link, real


def validate_producer_result(stage: pathlib.Path):
    p = stage / "usr/share/floe-opencl/PRODUCER_RESULT.json"
    if not p.is_file():
        fail(f"missing producer result: {p}")
    result = json.loads(p.read_text())
    checks = {
        "status": result.get("status") in (
            "runtime-stage-built-compiler-admitted",
            "runtime-stage-built-compiler-missing"),
        "profile": result.get("profile") in ("external-runtime", "external-runtime-il"),
        "buildTarget": result.get("buildTarget") == "OpenCL",
        "compilerAvailableCompileFlag": result.get("compilerAvailableCompileFlag") is True,
        "clvkCommit": result.get("clvkCommit") == PINS["components"]["clvk"]["commit"],
        "clspvHeaderCommit": result.get("clspvHeaderCommit") == PINS["components"]["clspv-header"]["commit"],
        "llvmNotConfigured": result.get("llvmConfigured") is False,
        "clspvTargetNotConfigured": result.get("clspvTargetConfigured") is False,
        "llvmSpirvNotConfigured": result.get("llvmSpirvTargetConfigured") is False,
    }
    failed = [k for k, ok in checks.items() if not ok]
    if failed:
        fail("PRODUCER_RESULT_INVALID: " + ", ".join(failed))
    if result.get("admission", {}).get("compilerAdmitted") is not True:
        fail("COMPILER_ADMISSION_MISSING: runtime stage has no admitted external clspv; packaging is refused")
    return result


def validate_stage(stage: pathlib.Path, producer, compiler_manifest_path, llvm_manifest_path):
    errors = []
    libdir = stage / "usr/lib/floe-opencl"
    if not libdir.is_dir():
        fail(f"missing payload dir: {libdir}")
    try:
        link, real = find_private_lib(stage)
    except SystemExit as exc:
        fail(str(exc))
    info = elf_info(real)
    if info["elfclass"] != 64 or info["machine"] != 183 or info["type"] != 3 or not info["little_endian"]:
        errors.append(f"ICD is not ELF64 LSB AArch64 ET_DYN: {info}")
    if info["soname"] != "libfloe_clvk.so.1":
        errors.append(f"ICD SONAME is {info['soname']!r}, expected 'libfloe_clvk.so.1'")
    if any("libOpenCL.so" in n for n in info["needed"]):
        errors.append(f"ICD must not depend on the system loader: {info['needed']}")
    missing = [s for s in REQUIRED_DYN_SYMBOLS if s not in info["symbols"]]
    if missing:
        errors.append(f"ICD missing dynamic symbols: {missing}")
    if "clIcdGetPlatformIDsKHR" not in info["symbols"]:
        errors.append("ICD symbol table lacks clIcdGetPlatformIDsKHR")
    if link.resolve() != real.resolve():
        errors.append("libfloe_clvk.so.1 does not resolve to the parsed real file")

    compiler = libdir / "clspv"
    if not compiler.is_file() or compiler.is_symlink():
        errors.append(f"missing/non-regular staged compiler: {compiler}")
    elif not os.access(compiler, os.X_OK):
        errors.append(f"staged compiler is not executable: {compiler}")
    else:
        cinfo = elf_info(compiler)
        if cinfo["elfclass"] != 64 or cinfo["machine"] != 183 or not cinfo["little_endian"]:
            errors.append(f"staged compiler is not ELF64 LSB AArch64: {cinfo}")
    compiler_info = elf_info(compiler) if compiler.is_file() and not compiler.is_symlink() else None

    llvm_spirv = libdir / "llvm-spirv"
    llvm_info = None
    if producer.get("spirvIl"):
        if not llvm_manifest_path:
            errors.append("producer reports SPIR-V IL but no llvm-spirv manifest was supplied")
        if not llvm_spirv.is_file() or llvm_spirv.is_symlink():
            errors.append(f"missing/non-regular staged llvm-spirv: {llvm_spirv}")
        elif not os.access(llvm_spirv, os.X_OK):
            errors.append(f"staged llvm-spirv is not executable: {llvm_spirv}")
        else:
            llvm_info = elf_info(llvm_spirv)
            if llvm_info["elfclass"] != 64 or llvm_info["machine"] != 183 or not llvm_info["little_endian"]:
                errors.append(f"staged llvm-spirv is not ELF64 LSB AArch64: {llvm_info}")
    else:
        if llvm_spirv.exists():
            errors.append("SPIR-V IL is disabled but a staged llvm-spirv exists")

    icd = stage / "usr/share/floe-opencl/vendors/floe-clvk.icd"
    expected_icd = b"/usr/lib/floe-opencl/libfloe_clvk.so.1\n"
    if not icd.is_file():
        errors.append(f"missing ICD file: {icd}")
    elif icd.read_bytes() != expected_icd:
        errors.append(f"ICD content is not the exact absolute one-line path: {icd.read_bytes()!r}")

    env = stage / "usr/share/floe-opencl/floe-opencl-env.sh"
    if not env.is_file():
        errors.append(f"missing env script: {env}")
    else:
        text = env.read_text()
        for needle in ("OCL_ICD_VENDORS=", "CLVK_CLSPV_PATH=", "VK_DRIVER_FILES=",
                       "VK_ICD_FILENAMES="):
            if needle not in text:
                errors.append(f"env script missing {needle}")
        if '[ -x "$FLOE_OPENCL_ROOT/clspv" ]' not in text:
            errors.append("env script must gate CLVK_CLSPV_PATH on an executable compiler")
        if producer.get("spirvIl") and "CLVK_LLVMSPIRV_BIN=" not in text:
            errors.append("IL profile env script missing CLVK_LLVMSPIRV_BIN=")
        if re.search(r"^\s*export\s+LD_LIBRARY_PATH=.*floe-opencl", text, re.M):
            errors.append("env script must not put the private ICD dir on LD_LIBRARY_PATH")
        if re.search(r"^\s*export\s+LIBGL_ALWAYS_SOFTWARE=", text, re.M):
            errors.append("env script must not force software GL")

    register = stage / "usr/bin/floe-opencl-register"
    if not register.is_file() or not os.access(register, os.X_OK):
        errors.append(f"missing/executable registration helper: {register}")

    doc = stage / "usr/share/doc/floe-opencl-clvk"
    for name in REQUIRED_LICENSE_FILES:
        p = doc / "licenses" / name
        if not p.is_file():
            errors.append(f"missing license: {p}")
        elif name in LICENSES and sha256(p) != LICENSES[name]["sha256"]:
            errors.append(f"license hash mismatch: {name}")
    if not (doc / "PINS.json").is_file():
        errors.append(f"missing source pins in package: {doc / 'PINS.json'}")
    for name in PATCH_FILES:
        if not (doc / name).is_file():
            errors.append(f"missing private patch in package docs: {name}")
    if not (doc / "EXTERNAL_TOOLCHAIN_CLSPV.json").is_file():
        errors.append("missing verified external compiler manifest in package docs")
    if producer.get("spirvIl") and not (doc / "EXTERNAL_TOOLCHAIN_LLVMSPIRV.json").is_file():
        errors.append("missing verified external llvm-spirv manifest in package docs")

    if errors:
        fail("STAGE_NOT_PACKAGEABLE:\n - " + "\n - ".join(errors))
    return {
        "icd_link": str(link.relative_to(stage)),
        "icd_real": str(real.relative_to(stage)),
        "icd_info": info,
        "compiler_info": compiler_info,
        "llvm_spirv_info": llvm_info,
    }


def add_bytes(tf: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    ti.mtime = 0
    tf.addfile(ti, io.BytesIO(data))


def add_link(tf: tarfile.TarFile, name: str, target: str):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.SYMTYPE
    ti.linkname = target
    ti.mode = 0o777
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    ti.mtime = 0
    tf.addfile(ti)


def build_tar_xz(stage: pathlib.Path):
    entries = []
    dirs = set()
    for p in sorted(stage.rglob("*")):
        rel = p.relative_to(stage).as_posix()
        parent = pathlib.PurePosixPath(rel).parent
        while str(parent) not in ("", "."):
            dirs.add(str(parent))
            parent = parent.parent
        entries.append(p)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for d in sorted(dirs):
            ti = tarfile.TarInfo(d)
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            ti.mtime = 0
            tf.addfile(ti)
        for p in entries:
            rel = p.relative_to(stage).as_posix()
            if p.is_symlink():
                add_link(tf, rel, os.readlink(p))
            elif p.is_file():
                mode = 0o755 if os.access(p, os.X_OK) else 0o644
                add_bytes(tf, rel, p.read_bytes(), mode)
    return lzma.compress(buf.getvalue(), preset=6)


def build_control_tar(control: str):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        add_bytes(tf, "./control", control.encode(), 0o644)
    return lzma.compress(buf.getvalue(), preset=6)


def ar_archive(members):
    out = bytearray(b"!<arch>\n")
    for name, data in members:
        hdr = (name + "/").ljust(16).encode()[:16]
        hdr += b"0".ljust(12)
        hdr += b"0".ljust(6)
        hdr += b"0".ljust(6)
        hdr += b"100644".ljust(8)
        hdr += str(len(data)).encode().ljust(10)
        hdr += b"`\n"
        out += hdr + data
        if len(data) & 1:
            out += b"\n"
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage-root", type=pathlib.Path, required=True)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--compiler-manifest", type=pathlib.Path, required=True)
    ap.add_argument("--llvm-spirv-manifest", type=pathlib.Path)
    ap.add_argument("--version", default=PINS["package"]["version"])
    ap.add_argument("--pins", type=pathlib.Path, default=ROOT / "PINS.json")
    ap.add_argument("--depends", default=("libc6 (>= 2.41), libstdc++6 (>= 14.2), "
                                          "libgcc-s1 (>= 14.2), libvulkan1 (>= 1.4.309), "
                                          "ocl-icd-libopencl1 (>= 2.3.3)"))
    args = ap.parse_args()
    if args.out.exists() or args.out.with_suffix(args.out.suffix + ".json").exists():
        fail("output/receipt already exists; preserve the earlier attempt")
    if not args.compiler_manifest.is_file():
        fail("COMPILER_ADMISSION_MISSING: --compiler-manifest is required and must exist")
    stage = args.stage_root.resolve()
    producer = validate_producer_result(stage)

    sys.path.insert(0, str(ROOT / "scripts"))
    import verify_external_toolchain as vet

    pins = json.loads(args.pins.read_text())
    compiler_admission = vet.validate(
        args.compiler_manifest, pins,
        artifact_override=stage / "usr/lib/floe-opencl/clspv",
        stage_root=stage, tool_override="clspv")
    if not compiler_admission["ok"]:
        fail("COMPILER_ADMISSION_INVALID: " + json.dumps(compiler_admission["errors"]))
    staged_compiler_sha = sha256(stage / "usr/lib/floe-opencl/clspv")
    if producer.get("externalCompiler", {}).get("sha256") != staged_compiler_sha:
        fail("COMPILER_HASH_MISMATCH: producer result, manifest and staged compiler disagree")

    llvm_admission = None
    if producer.get("spirvIl"):
        if not args.llvm_spirv_manifest or not args.llvm_spirv_manifest.is_file():
            fail("LLVMSPIRV_ADMISSION_MISSING: IL profile requires --llvm-spirv-manifest")
        llvm_admission = vet.validate(
            args.llvm_spirv_manifest, pins,
            artifact_override=stage / "usr/lib/floe-opencl/llvm-spirv",
            stage_root=stage, tool_override="llvm-spirv")
        if not llvm_admission["ok"]:
            fail("LLVMSPIRV_ADMISSION_INVALID: " + json.dumps(llvm_admission["errors"]))
        staged_llvm_sha = sha256(stage / "usr/lib/floe-opencl/llvm-spirv")
        if producer.get("externalLlvmSpirv", {}).get("sha256") != staged_llvm_sha:
            fail("LLVMSPIRV_HASH_MISMATCH: producer result, manifest and staged llvm-spirv disagree")

    proof = validate_stage(stage, producer, args.compiler_manifest, args.llvm_spirv_manifest)
    if proof["compiler_info"]["sha256"] != staged_compiler_sha:
        fail("staged compiler changed during validation")

    total = 0
    for p in stage.rglob("*"):
        if p.is_file() and not p.is_symlink():
            total += p.stat().st_size
    installed_kib = max(1, (total + 1023) // 1024)
    profile = producer.get("profile")
    control = (
        f"Package: {PINS['package']['name']}\n"
        f"Version: {args.version}\n"
        "Architecture: arm64\n"
        "Maintainer: Floe GPU Qualification <floe@localhost>\n"
        f"Installed-Size: {installed_kib}\n"
        f"Depends: {args.depends}\n"
        "Section: libs\n"
        "Priority: optional\n"
        f"X-Floe-OpenCL-Profile: {profile}\n"
        f"X-Floe-SPIRV-IL: {'external-llvm-spirv' if producer.get('spirvIl') else 'none'}\n"
        f"X-Floe-External-Compiler-SHA256: {staged_compiler_sha}\n"
        "Description: Private OpenCL 3.0 ICD over the Floe Venus Vulkan GPU\n"
        " A genuine kpet/clvk ICD assembled without LLVM or clspv in the runtime\n"
        " build. OpenCL C source builds use a separately supplied and verified\n"
        " ARM64 clspv process; SPIR-V IL is absent unless explicitly packaged with\n"
        " a verified external llvm-spirv. Applications opt in through\n"
        " /usr/share/floe-opencl/floe-opencl-env.sh or the reversible\n"
        " floe-opencl-register helper. Debian OpenCL/Vulkan libraries are not replaced.\n"
        " Actual ICD loading, kernel compilation and GPU execution are not claimed by\n"
        " this package installation.\n"
    )
    data_xz = build_tar_xz(stage)
    control_xz = build_control_tar(control)
    deb = ar_archive([
        ("debian-binary", b"2.0\n"),
        ("control.tar.xz", control_xz),
        ("data.tar.xz", data_xz),
    ])
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(deb)

    receipt = {
        "schema": 1,
        "status": "package-built-not-installed",
        "package": PINS["package"]["name"],
        "version": args.version,
        "architecture": "arm64",
        "profile": profile,
        "spirvIl": bool(producer.get("spirvIl")),
        "deb": {"path": str(args.out), "sha256": sha256(args.out), "bytes": len(deb)},
        "control": control,
        "depends": args.depends,
        "payloadProof": proof,
        "compilerAdmission": {
            "manifest": str(args.compiler_manifest),
            "artifactSHA256": staged_compiler_sha,
            "structuralStatus": compiler_admission["status"],
            "limitations": compiler_admission.get("limitations", []),
        },
        "llvmSpirvAdmission": (None if llvm_admission is None else {
            "manifest": str(args.llvm_spirv_manifest),
            "artifactSHA256": sha256(stage / "usr/lib/floe-opencl/llvm-spirv"),
            "structuralStatus": llvm_admission["status"],
        }),
        "icdFile": "/usr/share/floe-opencl/vendors/floe-clvk.icd",
        "icdLibrary": "/usr/lib/floe-opencl/libfloe_clvk.so.1",
        "compiler": "/usr/lib/floe-opencl/clspv",
        "envScript": "/usr/share/floe-opencl/floe-opencl-env.sh",
        "sourcePins": {
            "clvk": PINS["components"]["clvk"]["commit"],
            "clspv": PINS["components"]["clspv-header"]["commit"],
            "llvmCompilerProvenance": PINS["components"]["llvm"]["commit"],
            "privatePatches": PATCH_FILES,
        },
        "unrun": [
            "dpkg install into the actual guest",
            "ocl-icd dlopen of the private ICD",
            "clGetPlatformIDs through the system loader",
            "clspv execution and clBuildProgram",
            "numerical/lifetime fixture",
            "VM/App/device acceptance",
        ],
    }
    receipt_path = args.out.with_suffix(args.out.suffix + ".json")
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"status": receipt["status"], "deb": receipt["deb"],
                      "receipt": str(receipt_path)}, indent=2))


if __name__ == "__main__":
    main()
