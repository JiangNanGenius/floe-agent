#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Source-level checks for the Floe guest BLAS provider candidate.

No compiler, Vulkan runtime, VM or device is invoked.  The script verifies
the ABI/interface contracts, shader/host push layouts, fallback discipline,
activation paths and shell syntax that can be checked from source.
"""
from __future__ import annotations

import importlib.util
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILURES: list[str] = []
CHECKS = 0


def check(condition: bool, message: str) -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        FAILURES.append(message)


def read(path: str) -> str:
    candidate = ROOT / path
    check(candidate.is_file(), "missing file: " + path)
    return candidate.read_text(encoding="utf-8") if candidate.is_file() else ""


def strip_c(text: str) -> str:
    """Remove comments and replace string/char literals in one lexical pass."""
    output: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        character = text[index]
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = length if end < 0 else end + 2
            continue
        if text.startswith("//", index):
            end = text.find("\n", index + 2)
            index = length if end < 0 else end
            continue
        if character in ('"', "'"):
            quote = character
            index += 1
            while index < length:
                if text[index] == "\\":
                    index += 2
                    continue
                if text[index] == quote:
                    index += 1
                    break
                index += 1
            output.append('""' if quote == '"' else "''")
            continue
        output.append(character)
        index += 1
    return "".join(output)


def balanced(text: str) -> bool:
    stack: list[str] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for character in text:
        if character in "([{":
            stack.append(character)
        elif character in ")]}":
            if not stack or stack.pop() != pairs[character]:
                return False
    return not stack


def exported_functions(text: str) -> set[str]:
    return set(re.findall(
        r"FLOE_BLAS_EXPORT\s+[^;{]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*\(",
        strip_c(text), flags=re.S))


def check_shell_syntax(path: Path) -> None:
    shell = shutil.which("bash") or shutil.which("sh")
    check(shell is not None, "no shell available for syntax checks")
    if shell is None:
        return
    result = subprocess.run([shell, "-n", str(path)], capture_output=True,
                            text=True)
    check(result.returncode == 0,
          "shell syntax failed for %s: %s" % (path.name, result.stderr.strip()))


def check_python_syntax(path: Path) -> None:
    try:
        compile(path.read_text(encoding="utf-8"), str(path), "exec")
    except SyntaxError as error:
        check(False, "Python syntax failed for %s: %s" % (path.name, error))


def check_shader_contracts() -> None:
    spec = importlib.util.spec_from_file_location(
        "floe_blas_build_spirv", ROOT / "build/build_spirv.py")
    check(spec is not None and spec.loader is not None,
          "cannot import build_spirv.py")
    if spec is None or spec.loader is None:
        return
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for shader in module.SHADERS:
        problems = module.check_shader(shader)
        check(not problems, "%s: %s" % (shader["source"], "; ".join(problems)))

    vk_raw = read("src/floe_blas_vk.c")
    vk = strip_c(vk_raw)
    gemm_struct = re.search(
        r"typedef struct floe_gemm_push\s*\{(.*?)\}\s*floe_gemm_push\s*;",
        vk, flags=re.S)
    gemv_struct = re.search(
        r"typedef struct floe_gemv_push\s*\{(.*?)\}\s*floe_gemv_push\s*;",
        vk, flags=re.S)
    check(gemm_struct is not None, "host GEMM push struct is missing")
    check(gemv_struct is not None, "host GEMV push struct is missing")
    if gemm_struct and gemv_struct:
        def fields(block: str) -> list[tuple[str, str]]:
            found = re.findall(r"\b(uint32_t|float)\s+(\w+)\s*;", block)
            return [("uint" if kind == "uint32_t" else "float", name)
                    for kind, name in found]
        check(tuple(fields(gemm_struct.group(1))) == module.SHADERS[0]["fields"],
              "host GEMM push fields do not match the shader")
        check(tuple(fields(gemv_struct.group(1))) == module.SHADERS[1]["fields"],
              "host GEMV push fields do not match the shader")
        check(len(fields(gemm_struct.group(1))) * 4 == 44,
              "host GEMM push size is not 44 bytes")
        check(len(fields(gemv_struct.group(1))) * 4 == 24,
              "host GEMV push size is not 24 bytes")
    check("FLOE_VK_PUSH_BYTES 44" in vk, "push constant maximum is not 44")
    check("floe_blas_matmul_spv.h" in vk_raw, "GEMM SPIR-V header is not included")
    check("floe_blas_gemv_spv.h" in vk_raw, "GEMV SPIR-V header is not included")
    check("_Static_assert(sizeof(floe_gemm_push) == FLOE_VK_PUSH_BYTES" in vk,
          "GEMM push static assert is missing")
    check("_Static_assert(sizeof(floe_gemv_push) == 24" in vk,
          "GEMV push static assert is missing")


def check_sources() -> None:
    files = [
        "Makefile", "README.md", "LICENSE", "NOTICE",
        "include/floe_blas.h", "include/floe_blas_cblas.h",
        "src/floe_blas.c", "src/floe_blas_internal.h",
        "src/floe_blas_policy.c", "src/floe_blas_policy.h",
        "src/floe_blas_activate.c", "src/floe_blas_activate.h",
        "src/floe_blas_vk.c",
        "tools/floe_blas_probe.c",
        "build/build_spirv.py", "build/BUILD-RECIPE.txt",
        "shaders/floe_blas_matmul.comp", "shaders/floe_blas_gemv.comp",
        "scripts/floe-blas-run", "scripts/floe-blas-shell.sh",
        "scripts/floe-blas-activate.sh", "scripts/install-floe-blas.sh",
        "tests/run_source_checks.py", "tests/test_provider_abi.c",
        "tests/numpy_blas_compare.py", "tests/hostile_path_fixture.py", "tests/README.md",
    ]
    for name in files:
        read(name)

    for path in sorted((ROOT / "scripts").glob("*")):
        if path.is_file():
            check_shell_syntax(path)
    check_shell_syntax(ROOT / "scripts/floe-blas-run")
    for path in sorted((ROOT / "tests").glob("*.py")):
        check_python_syntax(path)
    check_python_syntax(ROOT / "build/build_spirv.py")

    c_files = ["src/floe_blas.c", "src/floe_blas_vk.c",
               "src/floe_blas_policy.c", "src/floe_blas_activate.c",
               "tools/floe_blas_probe.c", "tests/test_provider_abi.c"]
    for name in c_files:
        text = strip_c(read(name))
        check(balanced(text), "unbalanced C delimiters in " + name)

    provider = read("src/floe_blas.c")
    provider_exports = exported_functions(provider)
    expected_abi = {"cblas_sgemm", "sgemm_", "sgemm", "cblas_sgemv",
                    "sgemv_", "sgemv", "floe_blas_version",
                    "floe_blas_policy_set", "floe_blas_stats_reset",
                    "floe_blas_stats_get", "floe_blas_warmup"}
    check(expected_abi <= provider_exports,
          "provider is missing exports: " + ", ".join(sorted(expected_abi - provider_exports)))
    forbidden = {"dgemm", "dgemm_", "cblas_dgemm", "cgemm", "cgemm_",
                 "cblas_cgemm", "saxpy", "cblas_saxpy", "sdot", "cblas_sdot"}
    check(not (provider_exports & forbidden),
          "provider advertises unsupported symbols: " + ", ".join(sorted(provider_exports & forbidden)))
    check("RTLD_NEXT" in provider, "RTLD_NEXT fallback is missing")
    check("dl_iterate_phdr" in provider, "loaded-provider scan is missing")
    check("RTLD_DEFAULT" not in provider,
          "RTLD_DEFAULT can resolve the interposer itself and is forbidden")
    check("g_in_fallback" in provider, "recursion guard is missing")
    check("g_in_fallback) policy = FLOE_BLAS_POLICY_OFF" in provider,
          "recursive calls still attempt GPU work")
    check("copy_input_floats" in read("src/floe_blas_vk.c"),
          "finite/input copy check is missing")
    check("isfinite" in provider and "isfinite" in read("src/floe_blas_vk.c"),
          "non-finite guards are missing")
    check("double" not in strip_c(provider).replace("double precision", ""),
          "float32 provider must not use double arithmetic")
    check("float sum = 0.0f" in provider,
          "reference accumulation is not float32")
    check("RTLD_NEXT" in provider and "sgemm_" in provider,
          "Fortran fallback symbol is incomplete")
    check("gpu_submitted" in provider or "gpu_submitted" in read("src/floe_blas_vk.c"),
          "submitted counter is missing")
    check("gpu_completed" in read("src/floe_blas_vk.c"),
          "accepted counter is missing")
    vk = read("src/floe_blas_vk.c")
    submit = vk.find("result = vkQueueSubmit")
    submitted = vk.find("gpu_submitted", submit if submit >= 0 else 0)
    check(submit >= 0 and submitted > submit,
          "gpu_submitted is not recorded after VkQueueSubmit")
    check(re.search(r"if \(properties\.deviceType != VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU &&\s*"
                    r"properties\.deviceType != VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU &&\s*"
                    r"properties\.deviceType != VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU\) continue;", vk) is not None,
          "Vulkan device selection must reject CPU and unknown devices")
    check("vkGetPhysicalDeviceProperties2" in vk and "VK_DRIVER_ID_MESA_VENUS" in vk,
          "the Venus device identity check is missing")
    check("lavapipe" not in vk.lower() and "swiftshader" not in vk.lower() and
          "llvmpipe" not in vk.lower(),
          "no software Vulkan device may be selected")
    check("vkFlushMappedMemoryRanges" in vk and
          "vkInvalidateMappedMemoryRanges" in vk,
          "non-coherent memory flush/invalidate is missing")
    check("VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT" in vk,
          "host-visible memory selection is missing")
    stats = read("src/floe_blas.c")
    check("output.gpu_present = floe_blas_vk_state() == 1 ? 1u : 0u;" in stats,
          "gpu_present is not tied to the actual Vulkan state")

    header = read("include/floe_blas.h")
    for field in ("gpu_submitted", "gpu_completed", "fallback_cpu",
                  "fallback_reference", "invalid_args", "device_lost",
                  "gpu_present", "device_name", "last_error"):
        check(field in header, "stats field missing: " + field)
    check("FLOE_BLAS_API_VERSION" in header, "stats API version is missing")

    policy_header = read("src/floe_blas_policy.h")
    check('FLOE_BLAS_CONFIG_SUFFIX "/floe-acceleration/blas.conf"' in policy_header,
          "per-environment config path suffix is wrong")
    shell = read("scripts/floe-blas-shell.sh")
    check("floe-acceleration/blas.conf" in shell, "shell config path is missing")
    check("FLOE_BLAS_LIBRARY_PATH=/usr/local/lib/floe-acceleration/libfloe_blas.so" in shell,
          "shell library path does not match the install plan")
    check("FLOE_BLAS_LIBRARY_PATH \"/usr/local/lib/floe-acceleration/libfloe_blas.so\"" in read("src/floe_blas_activate.h"),
          "C activation library path does not match the install plan")
    check("FLOE_BLAS_RENDER_NODE" in shell and "/dev/dri/renderD128" in shell,
          "render-node guard is missing")
    check("floe_blas_is_guest" in shell, "guest check is missing")
    check("LD_PRELOAD" in shell and ":$LD_PRELOAD" in shell,
          "existing LD_PRELOAD is not preserved")
    check("nativehost" in shell, "native-host rejection is missing")

    wrapper = read("scripts/floe-blas-run")
    for token in ("--status", "--set-mode", "--mode", "exec \"$@\"",
                  "floe_blas_activate_shell", "mktemp", "mv -f"):
        check(token in wrapper, "wrapper missing: " + token)
    check("eval " not in wrapper, "wrapper must not eval command arguments")

    activation = read("scripts/floe-blas-activate.sh")
    check("floe_blas_activate_shell" in activation,
          "sourceable activation does not call the shared policy")
    check("FLOE_BLAS_ACTIVATION_SOURCED" in activation,
          "sourceable activation lacks a re-source guard")
    check("set -e" not in activation, "sourced fragment must not change shell options")

    makefile = read("Makefile")
    check("generated SPIR-V asset is missing" in makefile,
          "Makefile does not fail clearly on a missing SPIR-V asset")
    check("exit 2" in makefile, "Makefile missing-asset rule does not fail closed")
    check("-soname,libfloe_blas.so" in makefile, "SONAME is not libfloe_blas.so")
    check("src/floe_blas_activate.c" in makefile,
          "activation helper is not part of the library build")

    install = read("scripts/install-floe-blas.sh")
    for path in ("/usr/local/bin/floe-blas-run",
                 "/usr/local/bin/floe-blas-probe",
                 "/usr/local/lib/floe-acceleration/libfloe_blas.so",
                 "/usr/local/share/floe-acceleration/floe-blas-activate.sh"):
        check(path in install, "install path missing: " + path)

    probe = read("tools/floe_blas_probe.c")
    check("--size" in probe and "gpu_completed > 0" in probe,
          "probe lacks the real GPU counter assertion")
    check("cpuReferenceNs" in probe, "probe lacks the CPU reference measurement")

    if (ROOT / "generated/floe_blas_matmul_spv.h").exists():
        generated = read("generated/floe_blas_matmul_spv.h")
        check("0x07230203" in generated or "floe_blas_gemm_spv" in generated,
              "generated GEMM SPIR-V header looks empty")
    if (ROOT / "generated/floe_blas_gemv_spv.h").exists():
        generated = read("generated/floe_blas_gemv_spv.h")
        check("floe_blas_gemv_spv" in generated,
              "generated GEMV SPIR-V header looks empty")

    # The wrapper's read-only status path must remain usable and must not
    # activate anything on this macOS source host.
    shell_path = shutil.which("sh")
    if shell_path is not None:
        result = subprocess.run([shell_path, str(ROOT / "scripts/floe-blas-run"),
                                 "--status"], capture_output=True, text=True)
        check(result.returncode == 0,
              "floe-blas-run --status failed on the source host: " + result.stderr.strip())
        if result.returncode == 0:
            try:
                status = json.loads(result.stdout)
                check(status.get("guest") is False,
                      "--status did not identify this source host as a non-guest")
                check(status.get("mode") in ("auto", "on", "off"),
                      "--status mode is invalid")
                check("configPath" in status, "--status lacks configPath")
            except json.JSONDecodeError as error:
                check(False, "--status did not emit valid JSON: %s" % error)
        if (ROOT / "scripts/floe-blas-activate.sh").is_file():
            probe = subprocess.run(
                [shell_path, "-c",
                 '. "$1"; printf "%s" "${LD_PRELOAD:-none}"',
                 "sh", str(ROOT / "scripts/floe-blas-activate.sh")],
                capture_output=True, text=True)
            check(probe.returncode == 0,
                  "activation fragment failed on the source host: " + probe.stderr.strip())
            check(probe.stdout == "none",
                  "activation fragment changed LD_PRELOAD on a non-guest host")


def main() -> int:
    check_shader_contracts()
    check_sources()
    if FAILURES:
        print("source checks: FAIL (%d checks, %d failures)" %
              (CHECKS, len(FAILURES)), file=sys.stderr)
        for failure in FAILURES:
            print("  - " + failure, file=sys.stderr)
        return 1
    print("source checks: PASS (%d checks)" % CHECKS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
