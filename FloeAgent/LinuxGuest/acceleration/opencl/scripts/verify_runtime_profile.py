#!/usr/bin/env python3
"""Static contract check for the runtime-only CLVK profile.

This does not run CMake. It applies the private patch series to copies of the
pinned source in a temporary directory, then checks the actual CMake/text
boundary: external mode must not reach add_subdirectory(clspv) or the
SPIRV-LLVM-Translator, while the original full profile must keep both and the
offline compiler path must remain implemented.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = ROOT.parents[3]
DEFAULT_SOURCE = None
PATCH_ORDER = [
    "0001-floe-private-icd-output-name.patch",
    "0002-floe-external-clspv-runtime.patch",
    "0003-floe-runtime-compiler-admission.patch",
    "0004-floe-il-disabled-api-honesty.patch",
]


def apply_patches(source: pathlib.Path, temp: pathlib.Path):
    for rel in ("CMakeLists.txt", "src/CMakeLists.txt", "src/device.hpp", "src/api.cpp",
                "src/program.cpp", "src/device.cpp", "src/config.def", "src/program.hpp"):
        dest = temp / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / rel, dest)
    for name in PATCH_ORDER:
        patch = ROOT / "patches" / name
        p = subprocess.run(["patch", "-p1", "--batch", "--forward", "-i", str(patch)],
                           cwd=temp, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
        if p.returncode != 0:
            raise SystemExit(f"patch {name} failed: {p.stdout}")
    return {rel: (temp / rel).read_text() for rel in
            ("CMakeLists.txt", "src/CMakeLists.txt", "src/device.hpp", "src/api.cpp",
             "src/program.cpp", "src/device.cpp", "src/config.def", "src/program.hpp")}


def cmake_block(text, header, after=None):
    lines = text.splitlines()
    start = None
    floor = -1
    if after is not None:
        for i, line in enumerate(lines):
            if after in line:
                floor = i
                break
    for i, line in enumerate(lines):
        if i > floor and line.strip() == header:
            start = i
            break
    if start is None:
        raise SystemExit(f"missing CMake block: {header}")
    depth = 0
    else_index = None
    end = None
    for i in range(start, len(lines)):
        s = lines[i].strip()
        if s.startswith("if (") or s.startswith("if("):
            depth += 1
        elif s.startswith("endif()"):
            depth -= 1
            if depth == 0:
                end = i
                break
        elif depth == 1 and s.startswith("else()"):
            else_index = i
    if end is None:
        raise SystemExit(f"unterminated CMake block: {header}")
    if else_index is None:
        return "\n".join(lines[start:end + 1]), None
    return ("\n".join(lines[start:else_index + 1]),
            "\n".join(lines[else_index:end + 1]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clvk-source", type=pathlib.Path, required=True,
                    help="clean kpet/clvk checkout at the pinned commit")
    ap.add_argument("--out", type=pathlib.Path, default=ROOT / "RUNTIME_PROFILE.json")
    args = ap.parse_args()
    if not (args.clvk_source / "CMakeLists.txt").is_file():
        print(f"missing clvk source: {args.clvk_source}", file=sys.stderr)
        return 2
    src_text = {
        rel: (args.clvk_source / rel).read_text()
        for rel in ("CMakeLists.txt", "src/CMakeLists.txt", "src/device.hpp", "src/api.cpp",
                    "src/program.cpp", "src/device.cpp", "src/config.def", "src/program.hpp")
    }
    with tempfile.TemporaryDirectory(prefix="floe-profile-", dir=ROOT) as tmp:
        patched = apply_patches(args.clvk_source, pathlib.Path(tmp))

    checks = []

    def check(name, condition, detail=None):
        entry = {"check": name, "ok": bool(condition)}
        if detail is not None:
            entry["detail"] = detail
        checks.append(entry)

    top = patched["CMakeLists.txt"]
    src = patched["src/CMakeLists.txt"]
    check("option.external.default-off",
          'option(CLVK_EXTERNAL_CLSPV "Use an externally supplied clspv process instead of building the clspv toolchain" OFF)' in top)
    check("option.compiler.default-on",
          'option(CLVK_COMPILER_AVAILABLE "Enable compiler support" ON)' in top)
    check("option.il.external-default-off",
          "set(_clvk_spirv_il_default OFF)" in top and "set(_clvk_spirv_il_default ON)" in top)
    check("option.il.full-default-on",
          "option(CLVK_ENABLE_SPIRV_IL \"Enable SPIR-V as an intermediate language\" ${_clvk_spirv_il_default})" in top)
    check("option.external.fatal-with-compiler-off",
          "CLVK_EXTERNAL_CLSPV requires CLVK_COMPILER_AVAILABLE=ON" in top)
    check("option.external.fatal-with-online-compiler",
          "CLVK_EXTERNAL_CLSPV requires the offline compiler path" in top)

    external, full = cmake_block(top, "if (CLVK_EXTERNAL_CLSPV)", after="# clspv")
    check("external.branch.found", full is not None)
    if full is not None:
        check("external.branch.no-clspv-subdir",
              "add_subdirectory(${CLSPV_SOURCE_DIR}" not in external)
        check("external.branch.no-llvm-projects",
              "LLVM_ENABLE_PROJECTS" not in external and "add_subdirectory(${LLVM_SPIRV_SOURCE}" not in external)
        check("external.branch.header-only",
              "CLSPV_INCLUDE_DIR" in external and "clspv/Sampler.h" in external)
        check("external.branch.compiler-path",
              "CLVK_EXTERNAL_CLSPV_PATH" in external)
        check("external.branch.il-external-path",
              "CLVK_EXTERNAL_LLVMSPIRV_PATH" in external)
        check("full.branch.clspv-subdir",
              "add_subdirectory(${CLSPV_SOURCE_DIR}" in full)
        check("full.branch.llvm-projects", "LLVM_ENABLE_PROJECTS" in full)

    trans_ext, trans_full = cmake_block(
        top, "if (CLVK_EXTERNAL_CLSPV)", after="# SPIRV-LLVM-Translator")
    check("translator.external.no-llvm-spirv-subdir",
          "add_subdirectory(${LLVM_SPIRV_SOURCE}" not in trans_ext)
    check("translator.full.llvm-spirv-subdir",
          trans_full is not None and "add_subdirectory(${LLVM_SPIRV_SOURCE}" in trans_full)

    # The full-profile branch in src/CMakeLists is the else() of the online
    # compiler if. The external condition must split the executable path.
    check("src.external.default-clspv-path",
          'DEFAULT_CLSPV_BINARY_PATH="${CLVK_EXTERNAL_CLSPV_PATH}"' in src)
    check("src.full.default-clspv-path",
          'DEFAULT_CLSPV_BINARY_PATH="$<TARGET_FILE:clspv>"' in src)
    check("src.full.clspv-dependency", "add_dependencies(OpenCL-objects clspv)" in src)
    check("src.no-unconditional-clspv-dependency",
          src.count("add_dependencies(OpenCL-objects clspv)") == 1)
    check("src.install-clspv-guarded",
          "if (NOT CLVK_EXTERNAL_CLSPV AND NOT CLVK_CLSPV_ONLINE_COMPILER AND CLVK_COMPILER_AVAILABLE)" in src)
    check("src.header-include", 'target_include_directories(OpenCL-objects PRIVATE\n  "${CLSPV_INCLUDE_DIR}")' in src)

    prog = patched["src/program.cpp"]
    exports = (args.clvk_source / "src/exports.map").read_text()
    check("route.exported-source-compile",
          "clCreateProgramWithSource" in exports and "clBuildProgram" in exports)
    check("route.source-compile-present",
          "clCreateProgramWithSource" in patched["src/api.cpp"] and "clBuildProgram" in patched["src/api.cpp"])
    check("route.offline-build-present", "do_build_inner_offline" in prog)
    check("route.real-clspv-process", "config.clspv_path" in prog and "cvk_exec(cmd" in prog)
    check("route.cl-program-build", "cl_build_status cvk_program::do_build_inner" in prog)
    check("route.sampler-header", '#include "clspv/Sampler.h"' in prog)
    check("route.il-optional",
          "#ifndef CLSPV_ONLINE_COMPILER" in prog and "ENABLE_SPIRV_IL" in prog)
    check("route.il-disabled-build-error",
          "Could not build from il because clvk has been built with" in prog)

    dev = patched["src/device.cpp"]
    check("il.extension-guarded",
          '#ifdef ENABLE_SPIRV_IL\n        MAKE_NAME_VERSION(1, 0, 0, "cl_khr_il_program"),\n#endif' in dev.replace("\r", ""))
    check("il.device-list-guarded", '#ifdef ENABLE_SPIRV_IL\n        MAKE_NAME_VERSION(1, 0, 0, "SPIR-V"),\n#endif' in dev.replace("\r", ""))
    check("il.api-honest-off",
          "CL_INVALID_OPERATION" in patched["src/api.cpp"] and
          "#if !ENABLE_SPIRV_IL" in patched["src/api.cpp"])
    check("compiler.runtime-admission",
          "access(path.c_str(), X_OK)" in patched["src/device.hpp"] and
          "std::string path = config.clspv_path" in patched["src/device.hpp"])
    check("compiler.compile-flag-still-on",
          "CLVK_COMPILER_AVAILABLE=OFF" not in top and "COMPILER_AVAILABLE=0" not in top)

    check("pins.clvk", "399abf00c30b6d1d7a65d7ac06beee60b5991d7b" in json.dumps(
        json.loads((ROOT / "PINS.json").read_text())))
    check("pins.clspv", "7ee3a40e652b3649d175758f72d7af98b9450a68" in json.dumps(
        json.loads((ROOT / "PINS.json").read_text())))
    check("pins.llvm", "71a85ef89fc1997205104b72447e0dc2c4ad83da" in json.dumps(
        json.loads((ROOT / "PINS.json").read_text())))
    check("patch.order.exact", len(PATCH_ORDER) == 4 and
          all((ROOT / "patches" / p).is_file() for p in PATCH_ORDER))

    result = {
        "schema": 1,
        "status": "pass" if all(c["ok"] for c in checks) else "fail",
        "source": str(args.clvk_source),
        "patchOrder": PATCH_ORDER,
        "cmakeConfigureRun": False,
        "nativeOrCrossCompilationRun": False,
        "checks": checks,
        "failures": [c["check"] for c in checks if not c["ok"]],
        "note": "Text/CMake contract only. No configure, compile or link was run.",
    }
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text)
    print(text, end="")
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
