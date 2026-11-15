#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded, reproducible GLSL -> embedded SPIR-V asset builder.

The checked-in source is the GLSL file.  A real SPIR-V binary is a required
build input; it is deliberately not fabricated here.  Run this script with a
trusted glslangValidator or glslc from the pinned build sysroot to produce
``generated/*_spv.h``, then build the provider.  ``--source-check`` only reads
the shader text and is safe without a compiler.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SHADERS = (
    {
        "source": "shaders/floe_blas_matmul.comp",
        "symbol": "floe_blas_gemm_spv",
        "header": "generated/floe_blas_matmul_spv.h",
        "guard": "FLOE_BLAS_GEMM_SPV_H",
        "fields": (
            ("uint", "m"), ("uint", "n"), ("uint", "k"),
            ("uint", "a_row_stride"), ("uint", "a_col_stride"),
            ("uint", "b_row_stride"), ("uint", "b_col_stride"),
            ("uint", "c_row_stride"), ("uint", "c_col_stride"),
            ("float", "alpha"), ("float", "beta"),
        ),
        "bindings": ("A", "B", "C"),
        "local_size": (16, 8, 1),
    },
    {
        "source": "shaders/floe_blas_gemv.comp",
        "symbol": "floe_blas_gemv_spv",
        "header": "generated/floe_blas_gemv_spv.h",
        "guard": "FLOE_BLAS_GEMV_SPV_H",
        "fields": (
            ("uint", "n_out"), ("uint", "k"),
            ("uint", "a_row_stride"), ("uint", "a_col_stride"),
            ("float", "alpha"), ("float", "beta"),
        ),
        "bindings": ("A", "X", "Y"),
        "local_size": (64, 1, 1),
    },
)

SPV_MAGIC = 0x07230203
SPV_MAX_BYTES = 1024 * 1024
SOURCE_MAX_BYTES = 64 * 1024
SPIRV_VERSION_MAX = 0x00010600


def fail(message: str, code: int = 1) -> "NoReturn":
    print("build_spirv: error: " + message, file=sys.stderr)
    raise SystemExit(code)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def check_shader(spec: dict) -> list[str]:
    path = Path(__file__).resolve().parent.parent / spec["source"]
    problems: list[str] = []
    if not path.is_file():
        return ["missing shader: %s" % path]
    data = path.read_bytes()
    if len(data) == 0 or len(data) > SOURCE_MAX_BYTES:
        return ["shader size is outside 1..%d bytes: %s" % (SOURCE_MAX_BYTES, path)]
    text = strip_comments(data.decode("utf-8", "strict"))
    if not re.search(r"(?m)^\s*#version\s+450\s*$", text):
        problems.append("shader is not #version 450")
    if not re.search(r"\bvoid\s+main\s*\(", text):
        problems.append("shader has no main()")
    if "gl_GlobalInvocationID" not in text:
        problems.append("shader does not use gl_GlobalInvocationID")
    local = re.search(
        r"layout\s*\(\s*local_size_x\s*=\s*(\d+)\s*,\s*local_size_y\s*=\s*(\d+)"
        r"\s*,\s*local_size_z\s*=\s*(\d+)\s*\)\s*in", text)
    if not local:
        problems.append("missing explicit local_size layout")
    else:
        actual = tuple(int(value) for value in local.groups())
        if actual != spec["local_size"]:
            problems.append("local_size %r != %r" % (actual, spec["local_size"]))

    bindings = re.findall(
        r"layout\s*\(\s*set\s*=\s*(\d+)\s*,\s*binding\s*=\s*(\d+)\s*,"
        r"\s*std430\s*\)\s*(readonly\s+|writeonly\s+)?buffer\s+(\w+)\s*\{",
        text)
    if len(bindings) != 3:
        problems.append("expected 3 std430 storage buffers, found %d" % len(bindings))
    else:
        names = []
        for index, (set_number, binding, qualifier, name) in enumerate(bindings):
            if int(set_number) != 0:
                problems.append("buffer %s is not in descriptor set 0" % name)
            if int(binding) != index:
                problems.append("buffer %s binding %s != %d" % (name, binding, index))
            names.append(name)
        if tuple(names) != spec["bindings"]:
            problems.append("buffer names %r != %r" % (tuple(names), spec["bindings"]))
        if "readonly" not in bindings[0][2] or "readonly" not in bindings[1][2]:
            problems.append("A/X buffers must be readonly")
        if bindings[2][2] not in (None, ""):
            problems.append("C/Y output buffer must be read-write")

    push = re.search(
        r"layout\s*\(\s*push_constant\s*\)\s*uniform\s+Params\s*\{(.*?)\}\s*p\s*;",
        text, flags=re.S)
    if not push:
        problems.append("missing push_constant Params block")
    else:
        fields = re.findall(r"\b(uint|float)\s+(\w+)\s*;", push.group(1))
        actual = tuple((kind, name) for kind, name in fields)
        if actual != spec["fields"]:
            problems.append("push fields %r != %r" % (actual, spec["fields"]))
        expected_bytes = sum(4 for _ in fields)
        if expected_bytes not in (24, 44):
            problems.append("unexpected push block size %d" % expected_bytes)
    return problems


def run_source_check(as_json: bool) -> int:
    results = []
    for spec in SHADERS:
        problems = check_shader(spec)
        results.append({"source": spec["source"], "ok": not problems,
                        "problems": problems})
    if as_json:
        print(json.dumps({"ok": all(item["ok"] for item in results),
                          "shaders": results}, indent=2))
    else:
        for item in results:
            print("%s: %s" % (item["source"], "ok" if item["ok"] else
                              "; ".join(item["problems"])))
    return 0 if all(item["ok"] for item in results) else 1


def find_tool() -> tuple[str, str] | None:
    explicit = os.environ.get("FLOE_GLSLANG")
    if explicit:
        if not (os.path.isfile(explicit) and os.access(explicit, os.X_OK)):
            fail("FLOE_GLSLANG is not executable: " + explicit, 2)
        return explicit, ("glslc" if "glslc" in Path(explicit).name else
                          "glslangValidator")
    for name in ("glslc", "glslangValidator"):
        found = shutil.which(name)
        if found:
            return found, name
    return None


def compile_shader(tool: str, kind: str, source: Path, output: Path) -> None:
    if kind == "glslc":
        command = [tool, "--target-env=vulkan1.1", "-O", str(source), "-o",
                   str(output)]
    else:
        command = [tool, "-V", "--target-env", "vulkan1.1", str(source), "-o",
                   str(output)]
    try:
        completed = subprocess.run(command, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=120,
                                   check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        fail("shader compiler could not run: %s" % error, 2)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).decode("utf-8", "replace")
        fail("shader compilation failed for %s:\n%s" % (source, detail[-4000:]),
             2)
    if completed.stdout:
        # Compilers may print the output name; keep it out of the asset.
        pass


def validate_spirv(data: bytes, source: Path) -> None:
    if len(data) < 20 or len(data) % 4 != 0 or len(data) > SPV_MAX_BYTES:
        fail("invalid SPIR-V size for %s: %d" % (source, len(data)))
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    if words[0] != SPV_MAGIC:
        fail("bad SPIR-V magic for %s" % source)
    version = words[1]
    if version < 0x00010000 or version > SPIRV_VERSION_MAX:
        fail("unsupported SPIR-V version 0x%08x for %s" % (version, source))
    if words[3] > 1_000_000:
        fail("implausible SPIR-V id bound for %s" % source)
    if b"main\x00" not in data:
        fail("SPIR-V asset has no main entry point name for %s" % source)


def header_text(spec: dict, data: bytes, source_sha: str) -> str:
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    lines = []
    for start in range(0, len(words), 8):
        lines.append("    " + ", ".join("0x%08x" % word
                                        for word in words[start:start + 8]) + ",")
    digest = hashlib.sha256(data).hexdigest()
    return (
        "/* Generated by build/build_spirv.py from %s; Apache-2.0. */\n"
        "/* SPIR-V SHA256: %s; GLSL SHA256: %s */\n"
        "#ifndef %s\n#define %s\n\n#include <stdint.h>\n\n"
        "static const uint32_t %s[] = {\n%s\n};\n\n"
        "#define %s_WORDS (sizeof(%s) / sizeof(%s[0]))\n"
        "#define %s_SHA256 \"%s\"\n\n#endif\n"
        % (spec["source"], digest, source_sha, spec["guard"], spec["guard"],
           spec["symbol"], "\n".join(lines), spec["symbol"].upper(),
           spec["symbol"], spec["symbol"], spec["symbol"].upper(), digest))


def parse_header(path: Path, spec: dict) -> tuple[bytes, str]:
    if not path.is_file():
        fail("SPIR-V asset is missing: %s\nRun: python3 build/build_spirv.py "
             "(requires a trusted glslangValidator or glslc)" % path, 3)
    text = path.read_text(encoding="utf-8")
    if spec["symbol"] not in text or spec["guard"] not in text:
        fail("generated header is not for %s" % spec["symbol"], 3)
    match = re.search(
        r"static const uint32_t %s\[\]\s*=\s*\{(.*?)\};" % re.escape(spec["symbol"]),
        text, flags=re.S)
    if not match:
        fail("generated header has no %s array" % spec["symbol"], 3)
    try:
        words = [int(token, 16) for token in re.findall(r"0x([0-9a-fA-F]+)",
                                                        match.group(1))]
    except ValueError:
        fail("generated header contains an invalid word", 3)
    if not words:
        fail("generated header array is empty", 3)
    return struct.pack("<%dI" % len(words), *words), text


def build_one(tool: str, kind: str, spec: dict) -> tuple[bytes, str]:
    root = Path(__file__).resolve().parent.parent
    source = root / spec["source"]
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="floe-blas-spv-") as directory:
        output = Path(directory) / "shader.spv"
        compile_shader(tool, kind, source, output)
        data = output.read_bytes()
    validate_spirv(data, source)
    return data, source_sha


def build_all(tool: str, kind: str, check_only: bool) -> int:
    root = Path(__file__).resolve().parent.parent
    for spec in SHADERS:
        problems = check_shader(spec)
        if problems:
            fail("; ".join(problems), 1)
        data, source_sha = build_one(tool, kind, spec)
        header_path = root / spec["header"]
        if check_only:
            existing, _ = parse_header(header_path, spec)
            if existing != data:
                fail("generated header is stale for %s" % spec["source"], 1)
        else:
            header_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = header_path.with_suffix(header_path.suffix + ".tmp")
            temporary.write_text(header_text(spec, data, source_sha),
                                 encoding="utf-8")
            os.replace(temporary, header_path)
        print("%s: %s (%d bytes, sha256 %s)" % (
            "verified" if check_only else "built", spec["header"], len(data),
            hashlib.sha256(data).hexdigest()))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-check", action="store_true",
                        help="validate GLSL interface only; invoke no compiler")
    parser.add_argument("--json", action="store_true",
                        help="JSON output for --source-check")
    parser.add_argument("--check", action="store_true",
                        help="compile and compare against generated headers")
    arguments = parser.parse_args()
    if arguments.source_check:
        return run_source_check(arguments.json)
    found = find_tool()
    if found is None:
        fail("no glslangValidator or glslc found; set FLOE_GLSLANG to the "
             "pinned build-sysroot tool", 2)
    return build_all(found[0], found[1], arguments.check)


if __name__ == "__main__":
    sys.exit(main())
