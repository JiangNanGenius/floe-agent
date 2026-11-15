#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""floe-blender: Linux-guest Blender workbench entry points.

This command runs the Blender executable that is installed *inside the
resolved Linux guest* (or a staged guest runtime root).  It never invokes a
native macOS Blender and never falls back to a host process.

Entries:
    floe-blender status --json
    floe-blender probe --json
    floe-blender edit ...
    floe-blender export ...
    floe-blender render ...
    floe-blender open --backend gpu|software

Design notes:
* The wrapper owns argv construction, staged output files, output validation
  and the final commit.  The Blender-side helper owns scene mutation and
  render validation.
* A GPU request is fail-closed: unsupported Vulkan/OpenGL features, an
  unexpected software renderer, or a backend mismatch never publish a file
  as a GPU result.  CPU/software fallback only happens when the caller chose
  --device software (EEVEE) or --device cpu (Cycles), and the result says so.
* The wrapper does not start an X server or a desktop.  Interactive launch
  uses the DISPLAY inherited from the existing Floe project/display owner.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

sys.dont_write_bytecode = True

WRAPPER_VERSION = "1.0.0"
STATUS_SCHEMA = "floe.blender.status.v1"
RESULT_SCHEMA = "floe.blender.result.v1"
OPEN_SCHEMA = "floe.blender.open.v1"
JSON_PREFIX = "FLOE_BLENDER_JSON "

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_GPU = 3
EXIT_DISPLAY = 4
EXIT_VALIDATION = 5
EXIT_BLENDER = 6
EXIT_HELPER = 7
EXIT_INTERRUPTED = 130

SOFTWARE_RENDER_MARKERS = ("llvmpipe", "softpipe", "swrast", "swiftshader", "lavapipe")
GPU_REQUIRED_FEATURES_43 = [
    "geometryShader",
    "logicOp",
    "dualSrcBlend",
    "imageCubeArray",
    "multiDrawIndirect",
    "multiViewport",
    "shaderClipDistance",
    "drawIndirectFirstInstance",
    "fragmentStoresAndAtomics",
    "dynamicRendering",
]
GPU_REQUIRED_EXTENSIONS_43 = ["VK_KHR_swapchain", "VK_KHR_dynamic_rendering"]
GPU_REQUIRED_FEATURES_52 = GPU_REQUIRED_FEATURES_43 + [
    "vertexPipelineStoresAndAtomics",
    "shaderDrawParameters",
    "timelineSemaphore",
    "bufferDeviceAddress",
]
GPU_REQUIRED_EXTENSIONS_52 = GPU_REQUIRED_EXTENSIONS_43 + ["VK_EXT_provoking_vertex"]
# Blender main (5.4 alpha) removed the logic-op check but still requires
# geometry shaders on non-Apple builds, and requires more Vulkan 1.2/1.1
# extensions explicitly.
GPU_REQUIRED_FEATURES_54 = [
    "geometryShader",
    "fragmentStoresAndAtomics",
    "dualSrcBlend",
    "imageCubeArray",
    "drawIndirectFirstInstance",
]
GPU_REQUIRED_EXTENSIONS_54 = [
    "VK_KHR_swapchain",
    "VK_KHR_dynamic_rendering",
    "VK_KHR_timeline_semaphore",
    "VK_KHR_buffer_device_address",
    "VK_KHR_depth_stencil_resolve",
    "VK_KHR_create_renderpass2",
    "VK_KHR_separate_depth_stencil_layouts",
]

FEATURE_LABELS = {
    "geometryShader": "geometry shaders",
    "logicOp": "logical operations",
    "dualSrcBlend": "dual source blending",
    "imageCubeArray": "image cube array",
    "multiDrawIndirect": "multi draw indirect",
    "multiViewport": "multi viewport",
    "shaderClipDistance": "shader clip distance",
    "drawIndirectFirstInstance": "draw indirect first instance",
    "fragmentStoresAndAtomics": "fragment stores and atomics",
    "dynamicRendering": "dynamic rendering",
    "vertexPipelineStoresAndAtomics": "vertex pipeline stores and atomics",
    "shaderDrawParameters": "shader draw parameters",
    "timelineSemaphore": "timeline semaphores",
    "bufferDeviceAddress": "buffer device address",
}

DISPLAY_SOCKET_DIR = "/tmp/.X11-unix"


class ToolError(Exception):
    """A local preflight/usage error with a stable exit code."""

    def __init__(self, message: str, code: int = EXIT_USAGE, **details: Any) -> None:
        super().__init__(message)
        self.code = code
        self.details = details


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tail_lines(path: Path, limit: int = 40) -> List[str]:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as stream:
            lines = stream.read().splitlines()
        return lines[-limit:]
    except OSError:
        return []


def find_tool(name: str) -> Optional[str]:
    return shutil.which(name)


def parse_version_tuple(text: str) -> Optional[Tuple[int, int, int]]:
    match = re.search(r"^Blender\s+(\d+)\.(\d+)\.(\d+)", text, re.MULTILINE)
    if not match:
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def version_short(text: str) -> Optional[str]:
    tuple_ = parse_version_tuple(text)
    if tuple_ is None:
        return None
    return "%d.%d.%d" % tuple_


def version_at_least(value: Optional[Tuple[int, int, int]], minimum: Tuple[int, int, int]) -> bool:
    return value is not None and value >= minimum


def admission_policy(version: Optional[Tuple[int, int, int]]) -> str:
    if version is None:
        return "unknown"
    if version < (4, 4):
        return "4.3"
    if version < (5, 0):
        return "4.5"
    if version < (5, 4):
        return "5.2"
    return "5.4"


def policy_requirements(version: Optional[Tuple[int, int, int]]) -> Tuple[List[str], List[str]]:
    policy = admission_policy(version)
    if policy in ("4.3", "4.5"):
        return GPU_REQUIRED_FEATURES_43, GPU_REQUIRED_EXTENSIONS_43
    if policy == "5.4":
        return GPU_REQUIRED_FEATURES_54, GPU_REQUIRED_EXTENSIONS_54
    return GPU_REQUIRED_FEATURES_52, GPU_REQUIRED_EXTENSIONS_52


def parse_gl_version(text: Optional[str]) -> Optional[Tuple[int, int]]:
    if not text:
        return None
    match = re.search(r"(\d+)\.(\d+)", text)
    if not match:
        return None
    return (int(match.group(1)), int(match.group(2)))


def is_software_renderer(renderer: Optional[str]) -> Optional[bool]:
    if not renderer:
        return None
    lowered = renderer.lower()
    return any(marker in lowered for marker in SOFTWARE_RENDER_MARKERS)


def parse_glxinfo(text: str) -> Dict[str, Any]:
    renderer = None
    version = None
    core_version = None
    for line in text.splitlines():
        if line.startswith("OpenGL renderer string:"):
            renderer = line.split(":", 1)[1].strip()
        elif line.startswith("OpenGL core profile version string:"):
            core_version = line.split(":", 1)[1].strip()
        elif line.startswith("OpenGL version string:"):
            version = line.split(":", 1)[1].strip()
    chosen = core_version or version
    tuple_ = parse_gl_version(chosen)
    software = is_software_renderer(renderer)
    meets = tuple_ is not None and tuple_ >= (4, 3)
    return {
        "renderer": renderer,
        "version": version,
        "coreVersion": core_version,
        "versionTuple": list(tuple_) if tuple_ else None,
        "software": software,
        "meetsBlenderMinimum": meets,
    }


def parse_vulkaninfo(text: str) -> Dict[str, Any]:
    lines = text.splitlines()
    instance_extensions: List[str] = []
    device_extensions: List[str] = []
    features: Dict[str, bool] = {}
    device_name = None
    api_version = None
    driver_name = None
    driver_info = None

    index = 0
    while index < len(lines):
        line = lines[index]
        if line.strip().startswith("Instance Extensions:"):
            index += 1
            while index < len(lines) and lines[index].strip():
                match = re.match(r"\s*(VK_[A-Za-z0-9_]+)\s*:", lines[index])
                if match:
                    instance_extensions.append(match.group(1))
                index += 1
            continue
        if line.strip().startswith("Device Extensions:"):
            index += 1
            while index < len(lines) and lines[index].strip():
                match = re.match(r"\s*(VK_[A-Za-z0-9_]+)\s*:", lines[index])
                if match:
                    device_extensions.append(match.group(1))
                index += 1
            continue
        stripped = line.strip()
        if device_name is None and stripped.startswith("deviceName"):
            match = re.match(r"deviceName\s*=\s*(.+)", stripped)
            if match:
                device_name = match.group(1).strip()
        elif api_version is None and stripped.startswith("apiVersion"):
            match = re.match(r"apiVersion\s*=\s*(.+)", stripped)
            if match:
                api_version = match.group(1).strip()
        elif driver_name is None and stripped.startswith("driverName"):
            match = re.match(r"driverName\s*=\s*(.+)", stripped)
            if match:
                driver_name = match.group(1).strip()
        elif driver_info is None and stripped.startswith("driverInfo"):
            match = re.match(r"driverInfo\s*=\s*(.+)", stripped)
            if match:
                driver_info = match.group(1).strip()
        match = re.match(r"([A-Za-z][A-Za-z0-9_]*)\s*=\s*(true|false)\s*$", stripped)
        if match:
            name = match.group(1)
            value = match.group(2) == "true"
            # Some feature names occur in both core/feature blocks.  A missing
            # capability in any block must win.
            features[name] = features.get(name, True) and value
        index += 1

    return {
        "deviceName": device_name,
        "apiVersion": api_version,
        "driverName": driver_name,
        "driverInfo": driver_info,
        "instanceExtensions": sorted(set(instance_extensions)),
        "deviceExtensions": sorted(set(device_extensions)),
        "features": features,
    }


def parse_blender_gpu_device_help(stdout: str, stderr: str) -> Dict[str, Any]:
    supported = None
    devices: List[str] = []
    missing: List[str] = []
    if "no supported Vulkan devices found" in stdout:
        supported = False
    for line in stdout.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("Blender GPU Device Listing") \
                or stripped.startswith("Pass an Index") or stripped.startswith("Index ") \
                or stripped.startswith("(Vulkan backend not built)"):
            continue
        match = re.match(r"^\d+\s+[0-9a-fA-F/]+\s+(.+)$", stripped)
        if match:
            devices.append(match.group(1).strip())
    if devices:
        supported = True
    for match in re.finditer(r"Missing features are \[([^\]]*)\]", stderr):
        for item in match.group(1).split(","):
            item = item.strip()
            if item and item not in missing:
                missing.append(item)
    return {
        "supported": supported,
        "devices": devices,
        "missing": missing,
        "vulkanBackendNotBuilt": "Vulkan backend not built" in stdout,
    }


def mesa_version_from_driver(driver_info: Optional[str]) -> Optional[Tuple[int, int, int]]:
    if not driver_info:
        return None
    match = re.search(r"Mesa\s+(\d+)\.(\d+)\.(\d+)", driver_info)
    if not match:
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def compute_admission(version: Optional[Tuple[int, int, int]], facts: Optional[Dict[str, Any]],
                      blender_help: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    required_features, required_extensions = policy_requirements(version)
    policy = admission_policy(version)
    missing: List[str] = []
    unknown: List[str] = []
    if facts:
        features = facts.get("features") or {}
        extensions = set(facts.get("deviceExtensions") or [])
        for name in required_features:
            value = features.get(name)
            if value is False:
                missing.append(FEATURE_LABELS.get(name, name))
            elif value is None:
                unknown.append(name)
        for name in required_extensions:
            if name not in extensions:
                missing.append(name)
        supported: Optional[bool] = not missing and not unknown
    else:
        supported = None
        unknown = required_features + required_extensions

    if blender_help is not None:
        if blender_help.get("supported") is True:
            supported = True
            missing = []
            unknown = []
        elif blender_help.get("supported") is False:
            supported = False
            if blender_help.get("missing"):
                missing = list(blender_help["missing"])
            elif not missing:
                missing = ["Vulkan device did not pass Blender admission"]

    return {
        "policy": policy,
        "supported": supported,
        "missing": sorted(set(missing)),
        "unknown": sorted(set(unknown)),
        "requiredFeatures": required_features,
        "requiredExtensions": required_extensions,
    }


def render_node_present() -> bool:
    return Path("/dev/dri/renderD128").exists()


def swrast_present() -> bool:
    candidates = [
        Path("/usr/lib/aarch64-linux-gnu/dri/swrast_dri.so"),
        Path("/usr/lib/dri/swrast_dri.so"),
        Path("/usr/lib/aarch64-linux-gnu/libgallium.so"),
    ]
    return any(path.exists() for path in candidates)


class Install:
    def __init__(self, binary: Path, root: Optional[Path], source: str) -> None:
        self.binary = binary
        self.root = root
        self.source = source

    def library_path(self) -> str:
        parts: List[str] = []
        existing = os.environ.get("LD_LIBRARY_PATH", "")
        if existing:
            parts.extend(existing.split(":"))
        if self.root is not None:
            parts.extend([
                str(self.root / "usr/lib/aarch64-linux-gnu"),
                str(self.root / "lib/aarch64-linux-gnu"),
                str(self.root / "usr/lib"),
                str(self.root / "lib"),
            ])
        parts.extend(["/usr/lib/aarch64-linux-gnu", "/lib/aarch64-linux-gnu"])
        seen = set()
        ordered = []
        for part in parts:
            if not part or part in seen:
                continue
            seen.add(part)
            ordered.append(part)
        return ":".join(ordered)

    def argv_prefix(self) -> List[str]:
        if self.root is not None:
            loader = Path("/lib/ld-linux-aarch64.so.1")
            if not loader.exists():
                raise ToolError("Staged Blender root requires the guest AArch64 loader", EXIT_BLENDER,
                                loader=str(loader))
            return [str(loader), "--library-path", self.library_path(), str(self.binary)]
        return [str(self.binary)]

    def env(self) -> Dict[str, str]:
        env = dict(os.environ)
        if self.root is not None:
            env["LD_LIBRARY_PATH"] = self.library_path()
            scripts = self.root / "usr/share/blender/scripts"
            datafiles = self.root / "usr/share/blender/datafiles"
            if scripts.is_dir():
                env["BLENDER_SYSTEM_SCRIPTS"] = str(scripts)
            if datafiles.is_dir():
                env["BLENDER_SYSTEM_DATAFILES"] = str(datafiles)
        return env


def elf_machine(path: Path) -> Optional[int]:
    try:
        with path.open("rb") as stream:
            header = stream.read(20)
    except OSError:
        return None
    if len(header) < 20 or header[:4] != b"\x7fELF":
        return None
    if header[4] != 2 or header[5] != 1:  # ELF64 little-endian
        return None
    return struct.unpack("<H", header[18:20])[0]


def validate_guest_binary(path: Path) -> None:
    machine = elf_machine(path)
    if machine is not None and machine != 183:  # EM_AARCH64
        raise ToolError(
            "Resolved Blender is not an AArch64 Linux executable; host fallback is not allowed",
            EXIT_BLENDER,
            binary=str(path),
            elfMachine=machine,
        )


def resolve_install(args: argparse.Namespace) -> Install:
    root: Optional[Path] = None
    if getattr(args, "root", None):
        root = Path(str(args.root)).expanduser().resolve()
        if not root.is_dir():
            raise ToolError("Staged Blender root does not exist", EXIT_BLENDER, root=str(root))

    binary: Optional[Path] = None
    source = ""
    if getattr(args, "blender", None):
        binary = Path(str(args.blender)).expanduser().resolve()
        source = "explicit"
        if root is None:
            parent = binary.parent.parent
            if binary.name == "blender" and parent.name == "usr" and (parent.parent / "usr/share/blender").is_dir():
                root = parent.parent
                source = "explicit-staged"
    elif os.environ.get("FLOE_BLENDER_BIN"):
        binary = Path(os.environ["FLOE_BLENDER_BIN"]).expanduser().resolve()
        source = "env-FLOE_BLENDER_BIN"
    elif root is not None:
        binary = root / "usr/bin/blender"
        source = "staged-root"
    elif os.environ.get("FLOE_BLENDER_ROOT"):
        root = Path(os.environ["FLOE_BLENDER_ROOT"]).expanduser().resolve()
        binary = root / "usr/bin/blender"
        source = "env-FLOE_BLENDER_ROOT"
    else:
        candidates: List[Tuple[Path, Optional[Path], str]] = []
        located = shutil.which("blender")
        if located:
            candidates.append((Path(located).resolve(), None, "path"))
        candidates.extend([
            (Path("/usr/bin/blender"), None, "system"),
            (Path("/usr/local/bin/blender"), None, "system"),
            (Path("/opt/blender/blender"), None, "system"),
            (Path("/floe/cache/usr/bin/blender"), Path("/floe/cache"), "cache"),
        ])
        for candidate, candidate_root, candidate_source in candidates:
            if candidate.is_file() and os.access(candidate, os.X_OK):
                binary = candidate.resolve()
                root = candidate_root
                source = candidate_source
                break

    if binary is None or not binary.is_file() or not os.access(binary, os.X_OK):
        raise ToolError(
            "Blender is not installed in this Linux environment. Install the guest blender "
            "package or set FLOE_BLENDER_ROOT/FLOE_BLENDER_BIN.",
            EXIT_BLENDER,
            binary=str(binary) if binary else None,
            root=str(root) if root else None,
        )
    validate_guest_binary(binary)
    return Install(binary=binary, root=root, source=source)


def run_capture(argv: Sequence[str], env: Dict[str, str], timeout: float,
                cwd: Optional[Path] = None) -> Tuple[int, str, str, bool]:
    try:
        process = subprocess.Popen(
            list(argv),
            cwd=str(cwd) if cwd else None,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            start_new_session=True,
        )
    except OSError as error:
        return 127, "", str(error), False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return process.returncode, stdout, stderr, False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            stdout, stderr = "", ""
        return 124, stdout, stderr, True


def blender_version(install: Install, timeout: float = 30) -> Dict[str, Any]:
    code, stdout, stderr, timed_out = run_capture(install.argv_prefix() + ["--version"],
                                                  install.env(), timeout)
    text = (stdout + "\n" + stderr).strip()
    first_line = next((line.strip() for line in text.splitlines() if line.strip()), "")
    return {
        "exitCode": code,
        "timedOut": timed_out,
        "version": version_short(text),
        "versionTuple": list(parse_version_tuple(text)) if parse_version_tuple(text) else None,
        "versionFull": first_line,
        "text": text[-8000:],
    }


def run_helper_probe(install: Install, timeout: float = 45) -> Dict[str, Any]:
    helper = helper_script_path()
    argv = install.argv_prefix() + [
        "--background", "--factory-startup", "--disable-autoexec",
        "--python-exit-code", "7", "--python", str(helper), "--", "probe",
    ]
    code, stdout, stderr, timed_out = run_capture(argv, install.env(), timeout)
    records: List[Dict[str, Any]] = []
    for line in (stdout + "\n" + stderr).splitlines():
        if line.startswith(JSON_PREFIX):
            try:
                records.append(json.loads(line[len(JSON_PREFIX):]))
            except json.JSONDecodeError:
                pass
    completed = next((record for record in records if record.get("completed") is True), None)
    return {
        "exitCode": code,
        "timedOut": timed_out,
        "completed": completed is not None,
        "records": records[-20:],
        "completedRecord": completed,
        "stderrTail": "\n".join(stderr.splitlines()[-20:]),
    }


def helper_script_path() -> Path:
    here = Path(__file__).resolve().parent
    candidate = here / "blender_ops.py"
    if candidate.is_file():
        return candidate
    installed = Path("/usr/local/lib/floe/blender/blender_ops.py")
    if installed.is_file():
        return installed
    raise ToolError("Blender helper script blender_ops.py is missing", EXIT_HELPER,
                    expected=str(candidate))


def display_detail(env: Dict[str, str], timeout: float = 6) -> Dict[str, Any]:
    value = env.get("DISPLAY")
    if not value:
        return {"set": False, "value": None, "reachable": False,
                "reason": "DISPLAY is not set; start the Floe Linux screen first"}
    socket_reachable: Optional[bool] = None
    number = None
    local = value.startswith(":")
    if local:
        suffix = value[1:].split(".", 1)[0]
        if suffix.isdigit():
            number = int(suffix)
            socket_reachable = Path(DISPLAY_SOCKET_DIR, "X%d" % number).exists()
    xdpyinfo = find_tool("xdpyinfo")
    if xdpyinfo:
        code, stdout, stderr, timed_out = run_capture([xdpyinfo, "-display", value], env, timeout)
        if code == 0:
            return {"set": True, "value": value, "reachable": True, "reason": None,
                    "socket": socket_reachable, "probe": "xdpyinfo"}
        if socket_reachable:
            return {"set": True, "value": value, "reachable": True, "reason": None,
                    "socket": True, "probe": "x11-socket"}
        return {"set": True, "value": value, "reachable": False,
                "reason": (stderr.strip().splitlines()[-1] if stderr.strip() else
                           "display probe failed"),
                "socket": socket_reachable, "probe": "xdpyinfo", "timedOut": timed_out}
    if socket_reachable is not None:
        return {"set": True, "value": value, "reachable": socket_reachable,
                "reason": None if socket_reachable else "X11 socket not found",
                "socket": socket_reachable, "probe": "x11-socket"}
    return {"set": True, "value": value, "reachable": None,
            "reason": "no xdpyinfo and no local X11 socket to verify", "socket": None,
            "probe": "unavailable"}


def glxinfo_probe(env: Dict[str, str], label: str, timeout: float = 15) -> Dict[str, Any]:
    tool = find_tool("glxinfo")
    if not tool:
        return {"probe": "unavailable", "error": "glxinfo is not installed", "label": label}
    code, stdout, stderr, timed_out = run_capture([tool, "-B"], env, timeout)
    if code != 0:
        return {"probe": "failed", "exitCode": code, "timedOut": timed_out,
                "error": "\n".join(stderr.splitlines()[-8:]), "label": label}
    parsed = parse_glxinfo(stdout)
    parsed.update({"probe": "glxinfo", "label": label, "exitCode": code})
    return parsed


def software_env(env: Dict[str, str]) -> Dict[str, str]:
    result = dict(env)
    result.pop("__GLX_VENDOR_LIBRARY_NAME", None)
    library_path = result.get("LD_LIBRARY_PATH")
    if library_path:
        parts = [part for part in library_path.split(":") if part and "/floe-gpu" not in part]
        if parts:
            result["LD_LIBRARY_PATH"] = ":".join(parts)
        else:
            result.pop("LD_LIBRARY_PATH", None)
    drivers = result.get("LIBGL_DRIVERS_PATH")
    if drivers and "/floe-gpu" in drivers:
        result.pop("LIBGL_DRIVERS_PATH", None)
    result["LIBGL_ALWAYS_SOFTWARE"] = "1"
    result["GALLIUM_DRIVER"] = "llvmpipe"
    result["MESA_LOADER_DRIVER_OVERRIDE"] = "llvmpipe"
    if "LIBGL_DRIVERS_PATH" not in result:
        for path in ("/usr/lib/aarch64-linux-gnu/dri", "/usr/lib/dri"):
            if Path(path).is_dir():
                result["LIBGL_DRIVERS_PATH"] = path
                break
    return result


def vulkaninfo_probe(env: Dict[str, str], timeout: float = 25) -> Dict[str, Any]:
    tool = find_tool("vulkaninfo")
    if not tool:
        return {"probe": "unavailable", "error": "vulkaninfo is not installed"}
    code, stdout, stderr, timed_out = run_capture([tool], env, timeout)
    combined = stdout if stdout.strip() else stderr
    if not combined.strip():
        return {"probe": "failed", "exitCode": code, "timedOut": timed_out,
                "error": "vulkaninfo produced no output"}
    parsed = parse_vulkaninfo(combined)
    parsed.update({"probe": "vulkaninfo", "exitCode": code, "timedOut": timed_out})
    if not parsed.get("deviceName"):
        parsed["error"] = "\n".join((stderr or stdout).splitlines()[-10:])
    return parsed


def blender_gpu_help_probe(install: Install, version: Optional[Tuple[int, int, int]],
                           timeout: float = 25) -> Optional[Dict[str, Any]]:
    if not version_at_least(version, (5, 0)):
        return None
    argv = install.argv_prefix() + [
        "--factory-startup", "--log", "gpu.vulkan", "--log-level", "warning",
        "--gpu-device", "help",
    ]
    code, stdout, stderr, timed_out = run_capture(argv, install.env(), timeout)
    parsed = parse_blender_gpu_device_help(stdout, stderr)
    parsed.update({"exitCode": code, "timedOut": timed_out})
    return parsed


def vulkan_backend_compiled(install: Install, timeout: float = 20) -> Optional[bool]:
    code, stdout, stderr, timed_out = run_capture(
        install.argv_prefix() + ["--gpu-backend", "vulkan", "--version"], install.env(), timeout)
    if timed_out:
        return None
    if code == 0 and parse_version_tuple(stdout + stderr):
        return True
    if "Unrecognized GPU backend" in (stdout + stderr):
        return False
    return None


def build_swapchain_detail(facts: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not facts:
        return None
    extensions = set(facts.get("deviceExtensions") or [])
    advertised = "VK_KHR_swapchain" in extensions
    detail: Dict[str, Any] = {
        "advertised": advertised,
        "externalMemoryDmaBuf": "VK_EXT_external_memory_dma_buf" in extensions,
        "externalSemaphoreFd": "VK_KHR_external_semaphore_fd" in extensions,
        "drmFormatModifier": "VK_EXT_image_drm_format_modifier" in extensions,
        "queueFamilyForeign": "VK_EXT_queue_family_foreign" in extensions,
    }
    if not advertised:
        driver_name = (facts.get("driverName") or "").lower()
        mesa = mesa_version_from_driver(facts.get("driverInfo"))
        if "venus" in driver_name:
            if mesa is not None and mesa >= (26, 2, 0):
                detail["gate"] = (
                    "Mesa Venus is new enough to advertise VK_KHR_swapchain without host "
                    "sync-fd import, but this device did not expose it; inspect the host "
                    "renderer capability path."
                )
            else:
                detail["gate"] = (
                    "Mesa 25.0.x Venus gates VK_KHR_swapchain on renderer external memory "
                    "and importable sync-fd semaphores. MoltenVK does not provide those. "
                    "Mesa 26.2+ removes the gate (d11d7e2c); this is a host/image update, "
                    "not a launcher flag."
                )
        else:
            detail["gate"] = "VK_KHR_swapchain is not advertised by the current Vulkan device."
    return detail


def collect_status(args: argparse.Namespace, fast: bool = False) -> Dict[str, Any]:
    began = time.monotonic()
    status: Dict[str, Any] = {
        "schema": STATUS_SCHEMA,
        "wrapperVersion": WRAPPER_VERSION,
        "generatedAt": utc_now(),
        "available": False,
        "blender": {"available": False},
        "display": {"set": False, "value": None, "reachable": None},
        "gpu": {
            "renderNode": "/dev/dri/renderD128" if render_node_present() else None,
            "hardwareDevice": False,
            "vendor": None,
            "device": None,
            "driver": None,
            "vulkan": {"probe": "not-run", "supported": None, "missing": []},
            "opengl": {"probe": "not-run"},
            "cycles": {"available": False, "compiledBackends": [], "devices": [],
                       "gpuDevices": [], "gpuBackend": False},
        },
        "capabilities": {
            "headlessEdit": False,
            "headlessExport": False,
            "cyclesCpu": False,
            "cyclesGpu": False,
            "eeveeGpu": False,
            "eeveeSoftware": False,
            "interactiveGpu": False,
            "interactiveSoftware": False,
        },
        "backends": {
            "gpu": {"renderAvailable": False, "interactiveAvailable": False,
                    "api": None, "reason": "Blender is not available"},
            "software": {"renderAvailable": False, "interactiveAvailable": False,
                         "verified": False, "reason": "Blender is not available"},
        },
        "recommended": None,
        "limits": [
            "status probes capability only; it does not render or launch Blender",
            "a GPU request is never silently converted to a CPU/software render",
            "Vulkan API availability alone does not imply a Cycles GPU backend",
            "interactive launch uses the existing DISPLAY; it never starts an X server",
        ],
    }
    try:
        install = resolve_install(args)
    except ToolError as error:
        status["error"] = {"message": str(error), "code": error.code, **error.details}
        status["probeDurationSeconds"] = round(time.monotonic() - began, 3)
        return status

    version_info = blender_version(install)
    status["available"] = version_info["version"] is not None
    status["blender"] = {
        "available": status["available"],
        "binary": str(install.binary),
        "source": install.source,
        "root": str(install.root) if install.root else None,
        "version": version_info["version"],
        "versionTuple": version_info["versionTuple"],
        "versionFull": version_info["versionFull"],
        "vulkanBackendCompiled": None,
        "probe": None,
        "probeError": None,
    }
    version_tuple = tuple(version_info["versionTuple"]) if version_info["versionTuple"] else None
    status["display"] = display_detail(install.env())
    status["blender"]["vulkanBackendCompiled"] = vulkan_backend_compiled(install)

    probe = None
    if not fast:
        try:
            probe = run_helper_probe(install)
        except ToolError as error:
            status["blender"]["probeError"] = str(error)
    if probe is not None:
        status["blender"]["probe"] = probe.get("completedRecord")
        if not probe.get("completed"):
            status["blender"]["probeError"] = (
                probe.get("stderrTail") or "Blender helper probe did not complete"
            )
        record = probe.get("completedRecord") or {}
        cycles = record.get("cycles") or {}
        status["gpu"]["cycles"] = {
            "available": bool(cycles.get("available")),
            "compiledBackends": cycles.get("compiledBackends") or [],
            "devices": cycles.get("devices") or [],
            "gpuDevices": cycles.get("gpuDevices") or [],
            "gpuBackend": bool(cycles.get("gpuDevices")),
        }
        status["gpu"]["opengl"]["blenderBackendType"] = (record.get("gpuContext") or {}).get("backend")

    facts = None if fast else vulkaninfo_probe(install.env())
    help_info = None if fast else blender_gpu_help_probe(install, version_tuple)
    admission = compute_admission(version_tuple, facts, help_info)
    status["gpu"]["vulkan"] = {
        "probe": (facts or {}).get("probe", "unavailable"),
        "deviceName": (facts or {}).get("deviceName"),
        "apiVersion": (facts or {}).get("apiVersion"),
        "driverName": (facts or {}).get("driverName"),
        "driverInfo": (facts or {}).get("driverInfo"),
        "extensions": {
            name: name in set((facts or {}).get("deviceExtensions") or [])
            for name in sorted(set(GPU_REQUIRED_EXTENSIONS_43 + GPU_REQUIRED_EXTENSIONS_52 +
                                   GPU_REQUIRED_EXTENSIONS_54))
        },
        "features": {
            name: ((facts or {}).get("features") or {}).get(name)
            for name in sorted(set(GPU_REQUIRED_FEATURES_43 + GPU_REQUIRED_FEATURES_52 +
                                   GPU_REQUIRED_FEATURES_54))
        },
        "swapchain": build_swapchain_detail(facts),
        "blenderAdmission": admission,
        "backendCompiled": status["blender"].get("vulkanBackendCompiled"),
        "supported": (admission["supported"] is True and
                      status["blender"].get("vulkanBackendCompiled") is not False),
        "missing": admission["missing"],
        "blenderGpuDeviceHelp": help_info,
        "error": (facts or {}).get("error"),
    }
    if facts:
        status["gpu"]["device"] = facts.get("deviceName")
        status["gpu"]["driver"] = facts.get("driverInfo") or facts.get("driverName")
        lowered = (facts.get("deviceName") or "").lower()
        status["gpu"]["vendor"] = ("Apple" if "apple" in lowered else
                                   "Virtio" if "venus" in lowered or "virtio" in lowered else None)
        status["gpu"]["hardwareDevice"] = bool(facts.get("deviceName")) and render_node_present()

    display_reachable = status["display"].get("reachable") is True
    normal_gl = None if fast else glxinfo_probe(install.env(), "normal")
    software_gl = None if fast else glxinfo_probe(software_env(install.env()), "software")
    status["gpu"]["opengl"] = {
        "probe": (normal_gl or {}).get("probe", "unavailable"),
        "renderer": (normal_gl or {}).get("renderer"),
        "version": (normal_gl or {}).get("version"),
        "coreVersion": (normal_gl or {}).get("coreVersion"),
        "versionTuple": (normal_gl or {}).get("versionTuple"),
        "software": (normal_gl or {}).get("software"),
        "meetsBlenderMinimum": (normal_gl or {}).get("meetsBlenderMinimum"),
        "minimum": "4.3",
        "error": (normal_gl or {}).get("error"),
    }
    software_meets = (software_gl or {}).get("meetsBlenderMinimum") is True
    software_verified = software_meets and (software_gl or {}).get("software") is True
    swrast = swrast_present()
    status["gpu"]["opengl"]["softwareProbe"] = {
        "probe": (software_gl or {}).get("probe", "unavailable"),
        "renderer": (software_gl or {}).get("renderer"),
        "version": (software_gl or {}).get("version"),
        "meetsBlenderMinimum": (software_gl or {}).get("meetsBlenderMinimum"),
        "software": (software_gl or {}).get("software"),
        "error": (software_gl or {}).get("error"),
    }

    vulkan_compiled = status["blender"].get("vulkanBackendCompiled")
    vulkan_supported = (admission.get("supported") is True and vulkan_compiled is not False)
    vulkan_unknown = admission.get("supported") is None or vulkan_compiled is None
    opengl_hardware = ((normal_gl or {}).get("meetsBlenderMinimum") is True and
                       (normal_gl or {}).get("software") is False)
    gpu_render = vulkan_supported or opengl_hardware
    gpu_api = "vulkan" if vulkan_supported else ("opengl" if opengl_hardware else None)
    software_render = software_verified or swrast

    engines = (status["blender"].get("probe") or {}).get("engines") or []
    engine_ids = {item.get("id") for item in engines if isinstance(item, dict)}
    has_eevee = any(name in engine_ids for name in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE")) \
        if engine_ids else version_at_least(version_tuple, (4, 2))
    has_cycles = "CYCLES" in engine_ids if engine_ids else bool(
        status["gpu"]["cycles"].get("available"))
    cycles_cpu = bool(has_cycles and status["gpu"]["cycles"].get("available"))
    cycles_gpu = bool(has_cycles and status["gpu"]["cycles"].get("gpuDevices"))

    status["capabilities"] = {
        "headlessEdit": status["available"],
        "headlessExport": status["available"],
        "cyclesCpu": cycles_cpu,
        "cyclesGpu": cycles_gpu,
        "eeveeGpu": bool(has_eevee and gpu_render),
        "eeveeSoftware": bool(has_eevee and software_render),
        "interactiveGpu": bool(has_eevee and gpu_render and display_reachable),
        "interactiveSoftware": bool(has_eevee and software_render and display_reachable),
    }

    if gpu_render:
        gpu_reason = None
    elif vulkan_unknown:
        gpu_reason = ("GPU capability could not be verified; install vulkaninfo/mesa-utils or "
                      "run floe-blender probe")
    else:
        missing = admission.get("missing") or []
        gpu_reason = "Blender GPU requirements are not met"
        if missing:
            gpu_reason += ": " + ", ".join(missing)
    software_reason = None
    if not software_render:
        software_reason = ("No software OpenGL 4.3+ renderer was verified and swrast/llvmpipe "
                          "was not found in the guest")

    status["backends"] = {
        "gpu": {
            "renderAvailable": gpu_render,
            "interactiveAvailable": bool(gpu_render and display_reachable),
            "api": gpu_api,
            "reason": gpu_reason,
            "vulkanSupported": vulkan_supported,
            "openglHardware": opengl_hardware,
        },
        "software": {
            "renderAvailable": bool(software_render),
            "interactiveAvailable": bool(software_render and display_reachable),
            "verified": bool(software_verified),
            "reason": software_reason,
            "swrastPresent": swrast,
        },
    }
    if status["capabilities"]["interactiveGpu"]:
        status["recommended"] = "gpu"
    elif status["capabilities"]["interactiveSoftware"]:
        status["recommended"] = "software"
    else:
        status["recommended"] = None
    if status["display"].get("reachable") is not True:
        status["backends"]["gpu"]["interactiveAvailable"] = False
        status["backends"]["software"]["interactiveAvailable"] = False
    status["probeDurationSeconds"] = round(time.monotonic() - began, 3)
    return status


def status_human(status: Dict[str, Any]) -> str:
    lines: List[str] = []
    blender = status.get("blender") or {}
    if status.get("available"):
        lines.append("Blender: %s at %s (%s)" % (blender.get("version"), blender.get("binary"),
                                                  blender.get("source")))
    else:
        error = status.get("error") or {}
        lines.append("Blender: unavailable - %s" % (error.get("message") or "not installed"))
    display = status.get("display") or {}
    lines.append("Display: %s (%s)" % (display.get("value"), "reachable" if display.get("reachable")
                                       else display.get("reason") or "unknown"))
    gpu = status.get("gpu") or {}
    if gpu.get("device"):
        lines.append("GPU: %s; %s" % (gpu.get("device"), gpu.get("driver") or "unknown driver"))
    vulkan = gpu.get("vulkan") or {}
    admission = vulkan.get("blenderAdmission") or {}
    lines.append("Vulkan: %s%s" % (
        "supported" if admission.get("supported") is True else
        "unsupported" if admission.get("supported") is False else "unknown",
        (" - " + ", ".join(admission.get("missing") or [])) if admission.get("missing") else "",
    ))
    opengl = gpu.get("opengl") or {}
    lines.append("OpenGL: %s (%s)" % (opengl.get("coreVersion") or opengl.get("version") or "unknown",
                                      opengl.get("renderer") or "unknown"))
    backends = status.get("backends") or {}
    for name in ("gpu", "software"):
        item = backends.get(name) or {}
        state = "available" if item.get("interactiveAvailable") else "unavailable"
        line = "Backend %s: %s" % (name, state)
        if item.get("reason"):
            line += " - " + str(item["reason"])
        lines.append(line)
    lines.append("Recommended: %s" % (status.get("recommended") or "none"))
    return "\n".join(lines)


def run_streaming(argv: Sequence[str], env: Dict[str, str], log_path: Path,
                  verbose: bool = False) -> Tuple[int, List[Dict[str, Any]]]:
    records: List[Dict[str, Any]] = []
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        try:
            process = subprocess.Popen(
                list(argv),
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
                bufsize=1,
            )
        except OSError as error:
            log.write("failed to start Blender: %r\n" % (error,))
            return 127, records

        def reader() -> None:
            assert process.stdout is not None
            for line in process.stdout:
                log.write(line)
                log.flush()
                if line.startswith(JSON_PREFIX):
                    try:
                        records.append(json.loads(line[len(JSON_PREFIX):]))
                    except json.JSONDecodeError:
                        pass
                if verbose:
                    sys.stderr.write(line)
            process.stdout.close()

        thread = threading.Thread(target=reader, name="floe-blender-log", daemon=True)
        thread.start()
        previous_int = signal.getsignal(signal.SIGINT)
        previous_term = signal.getsignal(signal.SIGTERM)

        def forward(signum: int, _frame: Any) -> None:
            if process.poll() is None:
                try:
                    process.terminate()
                except OSError:
                    pass
            if signum == signal.SIGINT:
                raise KeyboardInterrupt()
            raise SystemExit(128 + signum)

        signal.signal(signal.SIGINT, forward)
        signal.signal(signal.SIGTERM, forward)
        try:
            code = process.wait()
        except KeyboardInterrupt:
            try:
                process.terminate()
            except OSError:
                pass
            try:
                code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    process.kill()
                except OSError:
                    pass
                code = 130
            code = 130
        finally:
            signal.signal(signal.SIGINT, previous_int)
            signal.signal(signal.SIGTERM, previous_term)
            thread.join(timeout=3)
    if code < 0:
        code = 128 + (-code)
    return code, records


def validate_png(path: Path) -> None:
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ToolError("Render output is not a valid PNG", EXIT_VALIDATION, path=str(path))
    width, height = struct.unpack(">II", data[16:24])
    if width < 1 or height < 1 or width > 16384 or height > 16384:
        raise ToolError("Render output has invalid dimensions", EXIT_VALIDATION,
                        path=str(path), width=width, height=height)


def validate_glb(path: Path) -> None:
    size = path.stat().st_size
    with path.open("rb") as stream:
        header = stream.read(12)
        if len(header) != 12 or struct.unpack("<4sII", header) != (b"glTF", 2, size):
            raise ToolError("Export is not a valid GLB", EXIT_VALIDATION, path=str(path))
        length, kind = struct.unpack("<I4s", stream.read(8))
        if kind != b"JSON" or length > size - 20:
            raise ToolError("GLB has an invalid JSON chunk", EXIT_VALIDATION, path=str(path))
        document = json.loads(stream.read(length))
    if not document.get("meshes") or not document.get("accessors") or not document.get("nodes"):
        raise ToolError("GLB has no exported scene geometry", EXIT_VALIDATION, path=str(path))


def validate_blend(path: Path) -> None:
    data = path.read_bytes()[:7]
    if data != b"BLENDER" or path.stat().st_size < 1024:
        raise ToolError("Saved .blend file is invalid", EXIT_VALIDATION, path=str(path))


class StagedOutput:
    def __init__(self, final: Path, kind: str, force: bool) -> None:
        self.final = final
        self.kind = kind
        self.force = force
        self.temp: Optional[Path] = None

    def prepare(self) -> Path:
        parent = self.final.parent
        if not parent.is_dir():
            raise ToolError("Output directory does not exist", EXIT_USAGE,
                            path=str(self.final), directory=str(parent))
        if self.final.exists() and not self.force:
            raise ToolError("Output already exists; pass --force to replace it", EXIT_USAGE,
                            path=str(self.final))
        descriptor, name = tempfile.mkstemp(prefix=".floe-blender-", suffix=".tmp", dir=str(parent))
        os.close(descriptor)
        self.temp = Path(name)
        return self.temp

    def validate(self) -> None:
        assert self.temp is not None
        if self.kind == "png":
            validate_png(self.temp)
        elif self.kind == "glb":
            validate_glb(self.temp)
        elif self.kind == "blend":
            validate_blend(self.temp)
        elif self.kind == "json":
            json.loads(self.temp.read_text(encoding="utf-8"))
        else:
            raise ToolError("Unknown staged output kind", EXIT_VALIDATION, kind=self.kind)

    def commit(self) -> Dict[str, Any]:
        assert self.temp is not None
        os.replace(self.temp, self.final)
        os.chmod(self.final, 0o644)
        return {
            "path": str(self.final),
            "kind": self.kind,
            "bytes": self.final.stat().st_size,
            "sha256": sha256_file(self.final),
        }

    def cleanup(self) -> None:
        if self.temp is not None:
            try:
                self.temp.unlink()
            except FileNotFoundError:
                pass
            self.temp = None


def commit_all(staged: Sequence[StagedOutput]) -> List[Dict[str, Any]]:
    committed: List[Dict[str, Any]] = []
    try:
        for item in staged:
            item.validate()
        for item in staged:
            committed.append(item.commit())
        return committed
    except BaseException:
        for item in staged:
            item.cleanup()
        # If a later commit failed, remove only files we just created.
        for item in committed:
            try:
                Path(item["path"]).unlink()
            except OSError:
                pass
        raise


def helper_result(records: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    completed = [record for record in records if record.get("completed") is True]
    if not completed:
        error_records = [record for record in records if record.get("error")]
        message = error_records[-1].get("error") if error_records else \
            "Blender helper did not report completion"
        raise ToolError(str(message), EXIT_HELPER)
    return completed[-1]


def base_result(command: str, install: Install, version: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "schema": RESULT_SCHEMA,
        "ok": False,
        "command": command,
        "wrapperVersion": WRAPPER_VERSION,
        "blender": {
            "binary": str(install.binary),
            "source": install.source,
            "version": version.get("version"),
            "versionFull": version.get("versionFull"),
        },
        "generatedAt": utc_now(),
    }


def fail_payload(command: str, message: str, code: int, **extra: Any) -> Dict[str, Any]:
    payload = {
        "schema": RESULT_SCHEMA,
        "ok": False,
        "command": command,
        "generatedAt": utc_now(),
        "error": {"message": message, "code": code},
    }
    payload["error"].update(extra)
    return payload


def emit_failure(args: argparse.Namespace, command: str, error: ToolError,
                 staged: Optional[Sequence[StagedOutput]] = None,
                 log_path: Optional[Path] = None, records: Optional[Sequence[Dict[str, Any]]] = None,
                 result: Optional[Dict[str, Any]] = None) -> int:
    if staged:
        for item in staged:
            item.cleanup()
    payload = result or fail_payload(command, str(error), error.code, **error.details)
    payload["ok"] = False
    if log_path is not None:
        payload["diagnostics"] = {"log": str(log_path), "tail": tail_lines(log_path)}
    if records:
        payload["helperRecords"] = list(records[-10:])
    if getattr(args, "json", False):
        print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
    else:
        sys.stderr.write("floe-blender: %s\n" % str(error))
        if log_path is not None:
            for line in tail_lines(log_path, 20):
                sys.stderr.write("  " + line + "\n")
    return error.code


def helper_base_argv(install: Install, threads: Optional[int] = None,
                     gpu_backend: Optional[str] = None) -> List[str]:
    argv = install.argv_prefix() + [
        "--background", "--factory-startup", "--disable-autoexec",
        "--python-exit-code", "7",
    ]
    if threads is not None:
        argv.extend(["--threads", str(threads)])
    if gpu_backend:
        argv.extend(["--gpu-backend", gpu_backend])
    argv.extend(["--python", str(helper_script_path()), "--"])
    return argv


def command_status(args: argparse.Namespace) -> int:
    status = collect_status(args, fast=args.fast)
    if args.json:
        print(json.dumps(status, indent=2, sort_keys=True, ensure_ascii=False))
    else:
        print(status_human(status))
    return EXIT_OK


def command_probe(args: argparse.Namespace) -> int:
    status = collect_status(args, fast=False)
    payload = {
        "schema": "floe.blender.probe.v1",
        "generatedAt": status.get("generatedAt"),
        "available": status.get("available"),
        "blender": status.get("blender"),
        "display": status.get("display"),
        "gpu": status.get("gpu"),
        "capabilities": status.get("capabilities"),
        "backends": status.get("backends"),
        "limits": [
            "probe does not render; use render for actual output validation",
            "missing feature lists are derived from the installed Blender version policy",
        ],
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
    else:
        print(status_human(status))
        blender = status.get("blender") or {}
        probe = blender.get("probe") or {}
        if probe:
            print("Cycles: %s" % json.dumps(probe.get("cycles") or {}, sort_keys=True))
    return EXIT_OK


def command_edit(args: argparse.Namespace) -> int:
    command = "edit"
    install: Optional[Install] = None
    staged: List[StagedOutput] = []
    log_path: Optional[Path] = None
    records: List[Dict[str, Any]] = []
    try:
        install = resolve_install(args)
        version = blender_version(install)
        if not version.get("version"):
            raise ToolError("Blender could not report its version", EXIT_BLENDER)
        if not args.save and not args.export_glb:
            raise ToolError("edit requires --save and/or --export-glb", EXIT_USAGE)
        if args.input and (args.new or args.demo_housing):
            raise ToolError("--input cannot be combined with --new/--demo-housing", EXIT_USAGE)
        if not args.input and not args.new and not args.demo_housing:
            raise ToolError("edit requires --input or --new/--demo-housing", EXIT_USAGE)
        helper_args = ["edit"]
        if args.input:
            helper_args.extend(["--input", str(Path(args.input).expanduser())])
        if args.new:
            helper_args.append("--new")
        if args.demo_housing:
            helper_args.append("--demo-housing")
        for name in args.object:
            helper_args.extend(["--object", name])
        if args.boolean_difference:
            helper_args.extend(["--boolean-difference", args.boolean_difference])
        if args.bevel is not None:
            helper_args.extend(["--bevel", str(args.bevel)])
            helper_args.extend(["--bevel-segments", str(args.bevel_segments)])
        if args.subdivide is not None:
            helper_args.extend(["--subdivide", str(args.subdivide)])
        if args.script:
            helper_args.extend(["--script", str(Path(args.script).expanduser())])
        if args.delete_cutters:
            helper_args.append("--delete-cutters")
        save_stage = None
        export_stage = None
        if args.save:
            save_stage = StagedOutput(Path(args.save).expanduser(), "blend", args.force)
            temp = save_stage.prepare()
            helper_args.extend(["--save", str(temp)])
            staged.append(save_stage)
        if args.export_glb:
            export_stage = StagedOutput(Path(args.export_glb).expanduser(), "glb", args.force)
            temp = export_stage.prepare()
            helper_args.extend(["--export-glb", str(temp)])
            if args.selection_only:
                helper_args.append("--selection-only")
            staged.append(export_stage)
        log_path = Path(args.log).expanduser() if args.log else _default_log_path(args, command)
        argv = helper_base_argv(install, threads=args.threads) + helper_args
        code, records = run_streaming(argv, install.env(), log_path, verbose=args.verbose)
        if code != 0:
            raise ToolError("Blender exited with code %d" % code, EXIT_HELPER if code == 7 else EXIT_BLENDER)
        completed = helper_result(records)
        for item in staged:
            item.validate()
        outputs = commit_all(staged)
        staged = []
        payload = base_result(command, install, version)
        payload.update({
            "ok": True,
            "result": completed,
            "outputs": outputs,
            "elapsedSeconds": completed.get("elapsedSeconds"),
        })
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
        else:
            print("Edited scene with Blender %s" % version.get("version"))
            for item in outputs:
                print("  %s %s (%d bytes)" % (item["kind"], item["path"], item["bytes"]))
        return EXIT_OK
    except ToolError as error:
        return emit_failure(args, command, error, staged, log_path, records)
    except KeyboardInterrupt:
        return emit_failure(args, command, ToolError("interrupted", EXIT_INTERRUPTED), staged, log_path)
    finally:
        for item in staged:
            item.cleanup()


def command_export(args: argparse.Namespace) -> int:
    command = "export"
    install: Optional[Install] = None
    staged: List[StagedOutput] = []
    log_path: Optional[Path] = None
    records: List[Dict[str, Any]] = []
    try:
        install = resolve_install(args)
        version = blender_version(install)
        if not version.get("version"):
            raise ToolError("Blender could not report its version", EXIT_BLENDER)
        scene = Path(args.scene).expanduser()
        if not scene.is_file():
            raise ToolError("Scene file does not exist", EXIT_USAGE, path=str(scene))
        out = StagedOutput(Path(args.output).expanduser(), "glb", args.force)
        temp = out.prepare()
        staged.append(out)
        helper_args = ["export", "--scene", str(scene), "--output", str(temp)]
        if args.selection_only:
            helper_args.append("--selection-only")
        if not args.apply_modifiers:
            helper_args.append("--no-apply-modifiers")
        log_path = Path(args.log).expanduser() if args.log else _default_log_path(args, command)
        argv = helper_base_argv(install, threads=args.threads) + helper_args
        code, records = run_streaming(argv, install.env(), log_path, verbose=args.verbose)
        if code != 0:
            raise ToolError("Blender exited with code %d" % code, EXIT_HELPER if code == 7 else EXIT_BLENDER)
        completed = helper_result(records)
        outputs = commit_all(staged)
        staged = []
        payload = base_result(command, install, version)
        payload.update({"ok": True, "result": completed, "outputs": outputs})
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
        else:
            print("Exported %s" % outputs[0]["path"])
        return EXIT_OK
    except ToolError as error:
        return emit_failure(args, command, error, staged, log_path, records)
    except KeyboardInterrupt:
        return emit_failure(args, command, ToolError("interrupted", EXIT_INTERRUPTED), staged, log_path)
    finally:
        for item in staged:
            item.cleanup()


def command_render(args: argparse.Namespace) -> int:
    command = "render"
    install: Optional[Install] = None
    staged: List[StagedOutput] = []
    log_path: Optional[Path] = None
    records: List[Dict[str, Any]] = []
    try:
        install = resolve_install(args)
        version = blender_version(install)
        if not version.get("version"):
            raise ToolError("Blender could not report its version", EXIT_BLENDER)
        scene = Path(args.scene).expanduser()
        if not scene.is_file():
            raise ToolError("Scene file does not exist", EXIT_USAGE, path=str(scene))
        engine = {"eevee": "eevee", "cycles": "cycles"}[args.engine]
        device = args.device
        if engine == "eevee" and device == "cpu":
            raise ToolError("EEVEE requires --device gpu or --device software", EXIT_USAGE)
        backend: Optional[str] = None
        env = install.env()
        status = None
        if engine == "eevee" and device == "gpu":
            status = collect_status(args, fast=False)
            gpu_info = (status.get("backends") or {}).get("gpu") or {}
            if not gpu_info.get("renderAvailable"):
                raise ToolError(
                    "GPU render unavailable; no silent CPU fallback",
                    EXIT_GPU,
                    missing=(status.get("gpu", {}).get("vulkan", {}).get("missing") or []),
                    reason=gpu_info.get("reason"),
                )
            backend = gpu_info.get("api")
            if backend not in ("vulkan", "opengl"):
                raise ToolError("GPU backend could not be selected", EXIT_GPU)
            if args.gpu_backend:
                if args.gpu_backend == "vulkan":
                    admitted = (status.get("gpu", {}).get("vulkan", {})
                                .get("blenderAdmission", {}).get("supported") is True)
                    if not admitted:
                        raise ToolError("Requested Vulkan backend is not admitted by this driver",
                                        EXIT_GPU)
                elif args.gpu_backend == "opengl":
                    opengl = status.get("gpu", {}).get("opengl") or {}
                    if opengl.get("meetsBlenderMinimum") is not True or opengl.get("software") is not False:
                        raise ToolError("Requested OpenGL backend does not meet Blender's minimum",
                                        EXIT_GPU, opengl=opengl)
                backend = args.gpu_backend
            if backend == "opengl":
                opengl = status.get("gpu", {}).get("opengl") or {}
                if opengl.get("meetsBlenderMinimum") is not True or opengl.get("software") is not False:
                    raise ToolError("OpenGL GPU requirement is not actually met", EXIT_GPU,
                                    opengl=opengl)
        elif engine == "eevee" and device == "software":
            env = software_env(env)
            backend = "opengl"
        elif engine == "cycles" and device == "gpu":
            status = collect_status(args, fast=False)
            cycles = status.get("gpu", {}).get("cycles") or {}
            if not cycles.get("gpuDevices"):
                raise ToolError(
                    "Cycles GPU is unavailable: no CUDA/OptiX/HIP/oneAPI/Metal device; "
                    "Cycles has no Vulkan backend",
                    EXIT_GPU,
                    cycles=cycles,
                )
        out = StagedOutput(Path(args.output).expanduser(), "png", args.force)
        temp = out.prepare()
        staged.append(out)
        cold_stage = None
        helper_args = [
            "render", "--scene", str(scene), "--engine", engine, "--device", device,
            "--output", str(temp), "--resolution", str(args.resolution),
            "--samples", str(args.samples), "--repeat", str(args.repeat),
        ]
        if args.keep_cold:
            cold_stage = StagedOutput(Path(args.keep_cold).expanduser(), "png", args.force)
            cold_temp = cold_stage.prepare()
            helper_args.extend(["--keep-cold", str(cold_temp)])
            staged.append(cold_stage)
        if args.film_transparent:
            helper_args.append("--film-transparent")
        if backend and engine == "eevee":
            helper_args.extend(["--expect-backend", backend.upper()])
        log_path = Path(args.log).expanduser() if args.log else _default_log_path(args, command)
        argv = helper_base_argv(install, threads=args.threads, gpu_backend=backend) + helper_args
        code, records = run_streaming(argv, env, log_path, verbose=args.verbose)
        if code != 0:
            raise ToolError("Blender exited with code %d" % code, EXIT_HELPER if code == 7 else EXIT_BLENDER)
        completed = helper_result(records)
        renders = completed.get("renders") or []
        if not renders:
            raise ToolError("Blender did not report a completed render", EXIT_HELPER)
        if engine == "eevee" and device == "gpu":
            expected = (backend or "").upper()
            for render in renders:
                renderer = render.get("renderer")
                actual_backend = (render.get("backend") or "").upper()
                if is_software_renderer(renderer) is not False:
                    raise ToolError(
                        "GPU render was not performed by a hardware renderer; output discarded",
                        EXIT_GPU, renderer=renderer, backend=actual_backend)
                if expected and actual_backend and actual_backend != expected:
                    raise ToolError(
                        "Blender used a different GPU backend than requested; output discarded",
                        EXIT_GPU, requested=expected, actual=actual_backend)
        if engine == "eevee" and device == "software":
            for render in renders:
                if is_software_renderer(render.get("renderer")) is not True:
                    raise ToolError(
                        "Explicit software render could not be verified; output discarded",
                        EXIT_VALIDATION, renderer=render.get("renderer"))
        outputs = commit_all(staged)
        staged = []
        payload = base_result(command, install, version)
        payload.update({
            "ok": True,
            "request": {
                "engine": engine,
                "device": device,
                "gpuBackend": backend,
                "resolution": args.resolution,
                "samples": args.samples,
                "repeat": args.repeat,
            },
            "result": completed,
            "outputs": outputs,
            "elapsedSeconds": completed.get("elapsedSeconds"),
            "deviceClass": ("gpu" if device == "gpu" else
                            "software" if device == "software" else "cpu"),
            "hardwareVerified": bool(device == "gpu" and engine == "eevee" and
                                     all(is_software_renderer(render.get("renderer")) is False
                                         for render in renders)),
        })
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
        else:
            print("Rendered %s with %s/%s" % (args.output, engine, device))
            for render in renders:
                print("  %-5s %.3fs %s" % (render.get("label"), render.get("seconds", 0),
                                           render.get("renderer") or render.get("device") or ""))
        return EXIT_OK
    except ToolError as error:
        return emit_failure(args, command, error, staged, log_path, records)
    except KeyboardInterrupt:
        return emit_failure(args, command, ToolError("interrupted", EXIT_INTERRUPTED), staged, log_path)
    finally:
        for item in staged:
            item.cleanup()


def command_open(args: argparse.Namespace) -> int:
    command = "open"
    try:
        install = resolve_install(args)
        version = blender_version(install)
        status = collect_status(args, fast=False)
        backend_name = args.backend
        backends = status.get("backends") or {}
        selected = backends.get(backend_name) or {}
        api = selected.get("api")
        if backend_name == "gpu":
            if not selected.get("interactiveAvailable"):
                raise ToolError(
                    "GPU interactive launch unavailable; no silent software fallback",
                    EXIT_GPU,
                    missing=(status.get("gpu", {}).get("vulkan", {}).get("missing") or []),
                    reason=selected.get("reason"),
                )
            if api not in ("vulkan", "opengl"):
                raise ToolError("GPU backend could not be selected", EXIT_GPU)
        else:
            if not selected.get("interactiveAvailable"):
                raise ToolError(
                    "Software interactive launch unavailable",
                    EXIT_GPU,
                    reason=selected.get("reason"),
                )
            api = "opengl"
        display = status.get("display") or {}
        if display.get("reachable") is not True:
            raise ToolError(
                "No reachable Linux display. Start the Floe Screen and run this command "
                "from that guest session; floe-blender never starts a second X server.",
                EXIT_DISPLAY,
                display=display,
            )
        argv = install.argv_prefix()
        if args.factory_startup:
            argv.append("--factory-startup")
        if not args.enable_autoexec:
            argv.append("--disable-autoexec")
        argv.extend(["--gpu-backend", api])
        if args.threads is not None:
            argv.extend(["--threads", str(args.threads)])
        if args.scene:
            scene = Path(args.scene).expanduser()
            if not scene.is_file():
                raise ToolError("Scene file does not exist", EXIT_USAGE, path=str(scene))
            argv.append(str(scene))
        extra = list(args.blender_args)
        if extra and extra[0] == "--":
            extra = extra[1:]
        argv.extend(extra)
        env = software_env(install.env()) if backend_name == "software" else install.env()
        if args.check or args.dry_run:
            payload = {
                "schema": OPEN_SCHEMA,
                "ok": True,
                "backend": backend_name,
                "api": api,
                "display": display,
                "blender": {"binary": str(install.binary), "version": version.get("version")},
                "command": argv,
                "envOverrides": ({key: env[key] for key in
                                  ("LIBGL_ALWAYS_SOFTWARE", "GALLIUM_DRIVER",
                                   "MESA_LOADER_DRIVER_OVERRIDE", "LIBGL_DRIVERS_PATH")
                                  if key in env and env.get(key) != os.environ.get(key)}),
                "note": "GUI launch is not started in check mode",
            }
            if args.json:
                print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
            else:
                print("OK: %s (%s)" % (backend_name, api))
                print("Command: %s" % " ".join(argv))
            return EXIT_OK
        sys.stderr.write("floe-blender: launching Blender %s on %s (%s)\n" % (
            version.get("version"), display.get("value"), backend_name))
        sys.stderr.flush()
        os.execvpe(argv[0], argv, env)
        return EXIT_OK
    except ToolError as error:
        return emit_failure(args, command, error)
    except KeyboardInterrupt:
        return emit_failure(args, command, ToolError("interrupted", EXIT_INTERRUPTED))


def _default_log_path(args: argparse.Namespace, command: str) -> Path:
    directory = None
    for name in ("save", "export_glb", "output", "keep_cold"):
        value = getattr(args, name, None)
        if value:
            directory = Path(str(value)).expanduser().parent
            break
    if directory is None:
        directory = Path(tempfile.gettempdir())
    descriptor, name = tempfile.mkstemp(prefix=".floe-blender-%s-" % command, suffix=".log",
                                        dir=str(directory))
    os.close(descriptor)
    return Path(name)


def command_version(args: argparse.Namespace) -> int:
    payload: Dict[str, Any] = {"wrapperVersion": WRAPPER_VERSION}
    try:
        install = resolve_install(args)
        version = blender_version(install)
        payload.update({"blender": {"binary": str(install.binary), "source": install.source,
                                    "version": version.get("version"),
                                    "versionFull": version.get("versionFull")}})
    except ToolError as error:
        payload["blender"] = {"available": False, "error": str(error)}
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
    else:
        print("floe-blender %s" % WRAPPER_VERSION)
        blender = payload.get("blender") or {}
        if blender.get("version"):
            print("Blender %s at %s (%s)" % (blender["version"], blender["binary"],
                                             blender.get("source")))
        else:
            print("Blender unavailable: %s" % (blender.get("error") or "not installed"))
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="floe-blender",
        description="Linux-guest Blender workbench (never native macOS Blender)",
    )
    parser.add_argument("--blender", help="explicit guest Blender binary")
    parser.add_argument("--root", help="staged guest runtime root containing usr/bin/blender")
    parser.add_argument("--log", help="Blender log file (default: temporary next to output)")
    parser.add_argument("--verbose", action="store_true", help="stream Blender output to stderr")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="report installed Blender and GPU capability")
    status.add_argument("--json", action="store_true")
    status.add_argument("--fast", action="store_true", help="skip Vulkan/OpenGL capability probes")
    status.set_defaults(handler=command_status)

    probe = sub.add_parser("probe", help="detailed passive capability probe")
    probe.add_argument("--json", action="store_true")
    probe.set_defaults(handler=command_probe)

    edit = sub.add_parser("edit", help="headless scene edit and optional save/export")
    edit.add_argument("--input", help="input .blend (guest path)")
    edit.add_argument("--new", action="store_true", help="start from factory startup")
    edit.add_argument("--demo-housing", action="store_true", help="build the fixed smoke housing")
    edit.add_argument("--object", action="append", default=[], help="target mesh object (repeatable)")
    edit.add_argument("--boolean-difference", help="cutter object name for a boolean difference")
    edit.add_argument("--bevel", type=float, help="bevel width")
    edit.add_argument("--bevel-segments", type=int, default=3)
    edit.add_argument("--subdivide", type=int, help="subdivision surface levels (applied)")
    edit.add_argument("--script", help="user Blender Python script (guest path, argv-safe)")
    edit.add_argument("--delete-cutters", action="store_true")
    edit.add_argument("--save", help="output .blend")
    edit.add_argument("--export-glb", help="output .glb")
    edit.add_argument("--selection-only", action="store_true")
    edit.add_argument("--threads", type=int)
    edit.add_argument("--force", action="store_true")
    edit.add_argument("--json", action="store_true")
    edit.set_defaults(handler=command_edit)

    export = sub.add_parser("export", help="export an existing scene to GLB")
    export.add_argument("--scene", required=True, help="input .blend (guest path)")
    export.add_argument("--output", required=True, help="output .glb")
    export.add_argument("--selection-only", action="store_true")
    export.add_argument("--no-apply-modifiers", action="store_true")
    export.add_argument("--threads", type=int)
    export.add_argument("--force", action="store_true")
    export.add_argument("--json", action="store_true")
    export.set_defaults(handler=command_export)

    render = sub.add_parser("render", help="render a scene with an explicit device")
    render.add_argument("--scene", required=True, help="input .blend (guest path)")
    render.add_argument("--engine", choices=["eevee", "cycles"], required=True)
    render.add_argument("--device", choices=["gpu", "software", "cpu"], required=True)
    render.add_argument("--output", required=True, help="output PNG")
    render.add_argument("--resolution", type=int, default=512)
    render.add_argument("--samples", type=int, default=16)
    render.add_argument("--repeat", type=int, default=1, choices=[1, 2, 3])
    render.add_argument("--keep-cold", help="optional cold-render PNG when --repeat > 1")
    render.add_argument("--gpu-backend", choices=["vulkan", "opengl"],
                        help="override the probed GPU backend (still fail-closed)")
    render.add_argument("--film-transparent", action="store_true")
    render.add_argument("--threads", type=int)
    render.add_argument("--force", action="store_true")
    render.add_argument("--log")
    render.add_argument("--json", action="store_true")
    render.set_defaults(handler=command_render)

    open_parser = sub.add_parser("open", help="launch the Blender GUI on the existing DISPLAY")
    open_parser.add_argument("--backend", choices=["gpu", "software"], required=True)
    open_parser.add_argument("--scene", help="optional .blend to open")
    open_parser.add_argument("--factory-startup", action="store_true")
    open_parser.add_argument("--enable-autoexec", action="store_true")
    open_parser.add_argument("--threads", type=int)
    open_parser.add_argument("--check", action="store_true", help="preflight only; do not launch")
    open_parser.add_argument("--dry-run", action="store_true", help=argparse.SUPPRESS)
    open_parser.add_argument("--json", action="store_true", help="with --check")
    open_parser.add_argument("blender_args", nargs=argparse.REMAINDER,
                             help="extra Blender arguments after --")
    open_parser.set_defaults(handler=command_open)

    version = sub.add_parser("version", help="print wrapper and Blender versions")
    version.add_argument("--json", action="store_true")
    version.set_defaults(handler=command_version)
    return parser


def require_linux_host() -> None:
    """Refuse every handler/probe outside the Linux guest.

    argparse handles ``--help`` before this point, so help remains pure
    documentation.  There is deliberately no environment or path-prefix
    bypass: a Mach-O Blender copied to an arbitrary path must never be
    invoked by this command.
    """
    if sys.platform != "linux":
        raise ToolError(
            "floe-blender is a Linux-guest command; native non-Linux hosts are not supported. "
            "Run it inside the resolved Floe Linux environment.",
            EXIT_BLENDER,
            platform=sys.platform,
        )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "open" and args.json and not (args.check or args.dry_run):
        parser.error("open --json requires --check")
    if args.command == "render":
        if args.resolution < 16 or args.resolution > 4096:
            parser.error("--resolution must be 16..4096")
        if args.samples < 1 or args.samples > 4096:
            parser.error("--samples must be 1..4096")
        if args.repeat == 1 and args.keep_cold:
            parser.error("--keep-cold requires --repeat 2 or 3")
    try:
        require_linux_host()
        return int(args.handler(args))
    except ToolError as error:
        payload = fail_payload(args.command, str(error), error.code, **error.details)
        if getattr(args, "json", False):
            print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
        else:
            sys.stderr.write("floe-blender: %s\n" % str(error))
        return error.code
    except KeyboardInterrupt:
        return EXIT_INTERRUPTED


if __name__ == "__main__":
    raise SystemExit(main())
