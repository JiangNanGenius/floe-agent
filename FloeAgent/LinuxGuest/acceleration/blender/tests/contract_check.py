#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Contract tests for the floe-blender wrapper.

These tests use a fake guest Blender, fake vulkaninfo/glxinfo and a fake
xdpyinfo. They prove argv construction, status parsing, staged output commit,
fail-closed GPU behavior and the absence of shell evaluation. They do not
execute real Blender, a VM, a GPU or a display server.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import textwrap
import traceback
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CLI = ROOT / "floe_blender.py"
LAUNCHER = ROOT / "floe-blender"
INSTALL = ROOT / "install.sh"
LINUX_RUN = HERE / "linux_run.py"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


FAKE_BLENDER = r'''#!{python}
import json
import os
import pathlib
import struct
import sys

args = sys.argv[1:]
log = os.environ.get("FAKE_BLENDER_LOG")
if log:
    with open(log, "a", encoding="utf-8") as stream:
        stream.write(json.dumps({{"argv": args, "env": {{
            "LIBGL_ALWAYS_SOFTWARE": os.environ.get("LIBGL_ALWAYS_SOFTWARE"),
            "GALLIUM_DRIVER": os.environ.get("GALLIUM_DRIVER"),
            "DISPLAY": os.environ.get("DISPLAY"),
            "__GLX_VENDOR_LIBRARY_NAME": os.environ.get("__GLX_VENDOR_LIBRARY_NAME"),
        }}}}) + "\n")
version = os.environ.get("FAKE_BLENDER_VERSION", "4.3.2")

if os.environ.get("FAKE_VULKAN_COMPILED", "1") != "1" and "--gpu-backend" in args:
    sys.stderr.write("Error: Unrecognized GPU backend for '--gpu-backend', expected one of [opengl, metal].\n")
    sys.exit(1)

if "--version" in args:
    print("Blender " + version)
    print("build date: 2026-01-01")
    sys.exit(0)

if "--gpu-device" in args and "help" in args:
    print("Blender GPU Device Listing (Vulkan):")
    print("Pass an Index or Device-ID to '--gpu-device'.")
    if os.environ.get("FAKE_GPU_HELP_SUPPORTED") == "1":
        print("  Index  Device-ID  Name")
        print("  0      106b/1b02020a  Virtio-GPU Venus (Apple M5 Pro)")
    else:
        print("  (no supported Vulkan devices found)")
        sys.stderr.write(
            "Device [Virtio-GPU Venus (Apple M5 Pro)] does not meet minimum requirements. "
            "Missing features are [geometry shaders, VK_EXT_provoking_vertex, "
            "VK_KHR_swapchain, ]\n")
    sys.exit(0)

if "--" not in args:
    sys.stderr.write("fake blender: missing -- phase separator\n")
    sys.exit(2)
phase = args[args.index("--") + 1]

def emit(value):
    print("FLOE_BLENDER_JSON " + json.dumps(value, sort_keys=True), flush=True)

def png(path):
    data = (b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" +
            struct.pack(">II", 16, 16) + b"\x08\x06\x00\x00\x00" + b"\x00\x00\x00\x00")
    pathlib_path = pathlib.Path(path)
    pathlib_path.parent.mkdir(parents=True, exist_ok=True)
    pathlib_path.write_bytes(data)

def glb(path):
    document = json.dumps({{"meshes": [{{}}], "nodes": [{{}}], "accessors": [{{}}]}}).encode("utf-8")
    while len(document) % 4:
        document += b" "
    length = 12 + 8 + len(document)
    data = struct.pack("<4sII", b"glTF", 2, length) + struct.pack("<I4s", len(document), b"JSON") + document
    pathlib_path = pathlib.Path(path)
    pathlib_path.parent.mkdir(parents=True, exist_ok=True)
    pathlib_path.write_bytes(data)

def blend(path):
    pathlib_path = pathlib.Path(path)
    pathlib_path.parent.mkdir(parents=True, exist_ok=True)
    pathlib_path.write_bytes(b"BLENDER-v403" + b"\x00" * 2048)

if phase == "probe":
    gpu = os.environ.get("FAKE_CYCLES_GPU") == "1"
    gpu_devices = [{{"name": "Fake CUDA", "type": "CUDA", "id": "0"}}] if gpu else []
    emit({{"phase": "probe", "completed": True, "blenderVersion": version,
           "versionTuple": [4, 3, 2],
           "buildOptions": {{"cycles": True, "cuda": gpu}},
           "engines": [{{"id": "BLENDER_EEVEE_NEXT", "name": "EEVEE"}},
                        {{"id": "CYCLES", "name": "Cycles"}}],
           "cycles": {{"available": True,
                       "compiledBackends": ["CPU", "CUDA"] if gpu else ["CPU"],
                       "devices": gpu_devices + [{{"name": "CPU", "type": "CPU", "id": "0"}}],
                       "gpuDevices": gpu_devices}},
           "gpuContext": {{"renderer": os.environ.get("FAKE_RENDERER", "zink (Virtio-GPU Venus (Apple M5 Pro))"),
                            "backend_type": "VULKAN"}},
           "display": os.environ.get("DISPLAY")}})
elif phase == "edit":
    save = args[args.index("--save") + 1] if "--save" in args else None
    export = args[args.index("--export-glb") + 1] if "--export-glb" in args else None
    if save:
        blend(save)
    if export:
        glb(export)
    emit({{"phase": "edit", "completed": True,
           "operations": [{{"operation": "test"}}],
           "geometry": {{"meshObjects": 14, "evaluatedVertices": 60000, "evaluatedTriangles": 120000}},
           "saved": {{"bytes": 2048}} if save else None,
           "exported": {{"bytes": 100}} if export else None,
           "elapsedSeconds": 0.01}})
elif phase == "export":
    glb(args[args.index("--output") + 1])
    emit({{"phase": "export", "completed": True,
           "geometry": {{"meshObjects": 1, "evaluatedVertices": 8, "evaluatedTriangles": 12}},
           "exported": {{"bytes": 100}}, "elapsedSeconds": 0.01}})
elif phase == "render":
    output = args[args.index("--output") + 1]
    engine = args[args.index("--engine") + 1]
    device = args[args.index("--device") + 1]
    png(output)
    if "--keep-cold" in args:
        png(args[args.index("--keep-cold") + 1])
    if device == "gpu":
        renderer = os.environ.get("FAKE_RENDERER", "zink (Virtio-GPU Venus (Apple M5 Pro))")
        backend = "VULKAN"
    elif device == "software":
        renderer = os.environ.get("FAKE_RENDERER", "llvmpipe (LLVM 19.1.7, 256 bits)")
        backend = "OPENGL"
    else:
        renderer = None
        backend = None
    renders = []
    for label, path in [("cold", args[args.index("--keep-cold") + 1])] if "--keep-cold" in args else []:
        renders.append({{"label": label, "path": path, "seconds": 0.01, "renderer": renderer,
                         "backend": backend, "image": {{"width": 16, "height": 16}}}})
    renders.append({{"label": "render" if not renders else "warm", "path": output,
                     "seconds": 0.02, "renderer": renderer, "backend": backend,
                     "image": {{"width": 16, "height": 16}}}})
    emit({{"phase": "render", "completed": True, "engine": engine, "device": device,
           "renders": renders, "totalRenderSeconds": 0.03, "elapsedSeconds": 0.03,
           "details": {{"engine": engine, "device": device}}}})
else:
    sys.stderr.write("fake blender: unknown phase " + str(phase) + "\n")
    sys.exit(7)
'''.replace("{python}", sys.executable).replace("{{", "{").replace("}}", "}")


FAKE_VULKANINFO = r'''#!{python}
import os
import sys

supported = os.environ.get("FAKE_VULKAN_SUPPORTED", "0") == "1"
print("VULKANINFO")
print("Vulkan Instance Version: 1.4.309")
print("")
print("Instance Extensions: count = 1")
print("\tVK_KHR_surface                         : extension revision 25")
print("")
print("Device Properties and Extensions:")
print("GPU0:")
print("VkPhysicalDeviceProperties:")
print("\tapiVersion        = 1.2.0 (4202496)")
print("\tdeviceName        = Virtio-GPU Venus (Apple M5 Pro)")
print("\tdriverName        = venus")
print("\tdriverInfo        = Mesa 25.0.7-2+deb13u1")
extensions = ["VK_KHR_dynamic_rendering", "VK_EXT_external_memory_dma_buf",
              "VK_EXT_image_drm_format_modifier", "VK_EXT_queue_family_foreign"]
if supported:
    extensions += ["VK_KHR_swapchain", "VK_KHR_external_semaphore_fd", "VK_EXT_provoking_vertex"]
print("")
print("Device Extensions: count = %d" % len(extensions))
for extension in extensions:
    print("\t%-45s : extension revision 1" % extension)
print("")
print("VkPhysicalDeviceFeatures:")
for name in ("geometryShader", "logicOp", "dualSrcBlend", "imageCubeArray",
             "multiDrawIndirect", "multiViewport", "shaderClipDistance",
             "drawIndirectFirstInstance", "fragmentStoresAndAtomics",
             "vertexPipelineStoresAndAtomics", "shaderDrawParameters",
             "timelineSemaphore", "bufferDeviceAddress", "dynamicRendering"):
    value = "true" if supported else ("false" if name in
             ("geometryShader", "logicOp") else "true")
    print("\t%-45s = %s" % (name, value))
print("")
'''.replace("{python}", sys.executable)


FAKE_GLXINFO = r'''#!{python}
import os
if os.environ.get("LIBGL_ALWAYS_SOFTWARE") == "1":
    print("OpenGL renderer string: llvmpipe (LLVM 19.1.7, 256 bits)")
    print("OpenGL core profile version string: 4.5 (Core Profile) Mesa 25.0.7")
else:
    renderer = os.environ.get("FAKE_GL_RENDERER", "zink (Virtio-GPU Venus (Apple M5 Pro))")
    version = os.environ.get("FAKE_GL_CORE", "2.1")
    print("OpenGL renderer string: " + renderer)
    if version.startswith("4."):
        print("OpenGL core profile version string: " + version + " (Core Profile) Mesa 25.0.7")
    else:
        print("OpenGL version string: " + version + " Mesa 25.0.7")
'''.replace("{python}", sys.executable)


FAKE_XDPYINFO = r'''#!{python}
import os
import sys
if os.environ.get("FAKE_DISPLAY_OK") == "1":
    print("name of display: " + os.environ.get("DISPLAY", ""))
    sys.exit(0)
sys.stderr.write("Error: Can't open display\n")
sys.exit(1)
'''.replace("{python}", sys.executable)


class TestFailure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise TestFailure(message)


def run(argv: List[str], env: Dict[str, str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(argv, env=env, text=True, capture_output=True, timeout=timeout)


def parse_json(process: subprocess.CompletedProcess) -> Dict[str, Any]:
    try:
        return json.loads(process.stdout)
    except json.JSONDecodeError as error:
        raise TestFailure("stdout is not JSON: %r\nstdout=%s\nstderr=%s" %
                          (error, process.stdout[:4000], process.stderr[:4000]))


def log_entries(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return entries


def main() -> int:
    if not CLI.is_file() or not LAUNCHER.is_file() or not INSTALL.is_file():
        print("missing candidate files", file=sys.stderr)
        return 2
    failures = 0
    total = 0
    temp = Path(tempfile.mkdtemp(prefix="floe-blender-contract-"))
    try:
        fakebin = temp / "bin"
        fakebin.mkdir()
        fake_log = temp / "fake-blender.log"
        write_executable(fakebin / "blender", FAKE_BLENDER)
        write_executable(fakebin / "vulkaninfo", FAKE_VULKANINFO)
        write_executable(fakebin / "glxinfo", FAKE_GLXINFO)
        write_executable(fakebin / "xdpyinfo", FAKE_XDPYINFO)
        # The shell launcher resolves python3 from PATH.  This fake python3
        # runs the real CLI through linux_run.py so the unconditional Linux
        # guard sees a Linux platform without launching a native Blender.
        write_executable(fakebin / "python3", textwrap.dedent("""\
            #!/bin/sh
            if [ "${1:-}" = "-I" ]; then shift; fi
            if [ "${1:-}" = "-" ]; then shift; exec "__PYTHON__" - "$@"; fi
            exec "__PYTHON__" -I "__LINUX_RUN__" "$@"
            """).replace("__PYTHON__", sys.executable).replace("__LINUX_RUN__", str(LINUX_RUN)))
        base_env = dict(os.environ)
        base_env.update({
            "PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", ""),
            "HOME": str(temp / "home"),
            "XDG_CACHE_HOME": str(temp / "cache"),
            "DISPLAY": ":99",
            "FAKE_BLENDER_LOG": str(fake_log),
            "FAKE_DISPLAY_OK": "1",
        })
        (temp / "home").mkdir()
        (temp / "cache").mkdir()

        def invoke(args: List[str], extra: Optional[Dict[str, str]] = None,
                   use_launcher: bool = False) -> subprocess.CompletedProcess:
            env = dict(base_env)
            if extra:
                env.update(extra)
            if use_launcher:
                command = [str(LAUNCHER)] + args
            else:
                command = [sys.executable, "-I", str(LINUX_RUN), str(CLI)] + args
            return run(command, env)

        def case(name: str, function) -> None:
            nonlocal failures, total
            total += 1
            try:
                function()
                print("ok %d %s" % (total, name))
            except BaseException as error:
                failures += 1
                print("not ok %d %s: %s" % (total, name, error))
                traceback.print_exc()

        def status_unsupported() -> None:
            process = invoke(["status", "--json"], {"FAKE_VULKAN_SUPPORTED": "0"})
            check(process.returncode == 0, "status exit %d: %s" % (process.returncode, process.stderr))
            data = parse_json(process)
            check(data["available"] is True, "Blender not available")
            check(data["blender"]["version"] == "4.3.2", "version mismatch")
            admission = data["gpu"]["vulkan"]["blenderAdmission"]
            check(admission["supported"] is False, "Vulkan admission should fail")
            for name in ("geometry shaders", "logical operations", "VK_KHR_swapchain"):
                check(name in admission["missing"], "missing %s in %r" % (name, admission["missing"]))
            check(data["display"]["reachable"] is True, "display should be reachable")
            check(data["backends"]["gpu"]["renderAvailable"] is False, "GPU must be unavailable")
            check(data["backends"]["software"]["renderAvailable"] is True, "software should be available")
            check(data["recommended"] == "software", "expected software recommendation")
            check(data["capabilities"]["cyclesCpu"] is True, "Cycles CPU should be available")

        def status_supported() -> None:
            process = invoke(["status", "--json"], {"FAKE_VULKAN_SUPPORTED": "1"})
            check(process.returncode == 0, "status exit %d" % process.returncode)
            data = parse_json(process)
            admission = data["gpu"]["vulkan"]["blenderAdmission"]
            check(admission["supported"] is True, "Vulkan admission should pass: %r" % admission)
            check(data["backends"]["gpu"]["renderAvailable"] is True, "GPU render should be available")
            check(data["backends"]["gpu"]["api"] == "vulkan", "expected Vulkan API")
            check(data["recommended"] == "gpu", "expected GPU recommendation")

        def status_52_help() -> None:
            process = invoke(["status", "--json"], {
                "FAKE_VULKAN_SUPPORTED": "1",
                "FAKE_BLENDER_VERSION": "5.2.3",
                "FAKE_GPU_HELP_SUPPORTED": "0",
            })
            check(process.returncode == 0, "status exit %d" % process.returncode)
            data = parse_json(process)
            check(data["blender"]["version"] == "5.2.3", "5.2.3 version missing")
            admission = data["gpu"]["vulkan"]["blenderAdmission"]
            check(admission["supported"] is False, "help result should override raw facts")
            check("geometry shaders" in admission["missing"], "help missing list not parsed")
            check("VK_EXT_provoking_vertex" in admission["missing"], "provoking vertex missing")

        def render_gpu_unsupported() -> None:
            before = len(log_entries(fake_log))
            output = temp / "gpu-unsupported.png"
            process = invoke(["render", "--scene", str(fake_scene(temp)), "--engine", "eevee",
                              "--device", "gpu", "--output", str(output), "--json"],
                             {"FAKE_VULKAN_SUPPORTED": "0"})
            check(process.returncode == 3, "expected exit 3, got %d" % process.returncode)
            data = parse_json(process)
            check(data["ok"] is False, "GPU failure must not be ok")
            check(not output.exists(), "failed GPU render must not publish output")
            entries = log_entries(fake_log)[before:]
            check(all("render" not in entry.get("argv", []) for entry in entries),
                  "GPU preflight must fail before invoking render: %r" % entries)

        def render_cycles_cpu() -> None:
            output = temp / "cycles.png"
            process = invoke(["render", "--scene", str(fake_scene(temp)), "--engine", "cycles",
                              "--device", "cpu", "--output", str(output), "--resolution", "32",
                              "--samples", "1", "--json"])
            check(process.returncode == 0, "render exit %d: %s" % (process.returncode, process.stderr))
            data = parse_json(process)
            check(data["ok"] is True, "CPU render should be ok")
            check(data["deviceClass"] == "cpu", "expected cpu device class")
            check(output.is_file(), "CPU render output missing")
            check(not list(output.parent.glob(".floe-blender-*.tmp")), "temporary output leaked")

        def edit_paths() -> None:
            directory = temp / "out dir"
            directory.mkdir()
            save = directory / "out blend.blend"
            export = directory / "$NOT_EXPANDED 'quote'.glb"
            process = invoke(["edit", "--new", "--object", "Body", "--bevel", "0.05",
                              "--save", str(save), "--export-glb", str(export), "--json"])
            check(process.returncode == 0, "edit exit %d: %s" % (process.returncode, process.stderr))
            data = parse_json(process)
            check(data["ok"] is True, "edit should be ok")
            check(save.is_file(), "save output missing")
            check(export.is_file(), "literal export path missing (shell expansion?)")
            check(len(data["outputs"]) == 2, "expected two outputs")
            entries = log_entries(fake_log)
            check(any("--save" in entry.get("argv", []) for entry in entries),
                  "save argv not observed")


        def render_cycles_gpu_unavailable() -> None:
            output = temp / "cycles-gpu-unavailable.png"
            process = invoke(["render", "--scene", str(fake_scene(temp)), "--engine", "cycles",
                              "--device", "gpu", "--output", str(output), "--json"],
                             {"FAKE_CYCLES_GPU": "0"})
            check(process.returncode == 3, "expected exit 3, got %d" % process.returncode)
            data = parse_json(process)
            check(data["ok"] is False, "Cycles GPU failure must not be ok")
            check("no CUDA" in json.dumps(data).lower() or "gpu" in json.dumps(data).lower(),
                  "Cycles GPU reason missing")
            check(not output.exists(), "failed Cycles GPU render must not publish output")

        def render_cycles_gpu_selected() -> None:
            output = temp / "cycles-gpu.png"
            process = invoke(["render", "--scene", str(fake_scene(temp)), "--engine", "cycles",
                              "--device", "gpu", "--output", str(output), "--json"],
                             {"FAKE_CYCLES_GPU": "1", "FAKE_VULKAN_SUPPORTED": "1"})
            check(process.returncode == 0, "Cycles GPU exit %d: %s" %
                  (process.returncode, process.stderr))
            data = parse_json(process)
            check(data["ok"] is True, "Cycles GPU selection should complete")
            check(data["deviceClass"] == "gpu", "expected gpu device class")
            check(data["hardwareVerified"] is False,
                  "Cycles selection alone must not claim hardware verification")
            check(output.is_file(), "Cycles GPU output missing")

        def open_gpu_check_unsupported() -> None:
            process = invoke(["open", "--backend", "gpu", "--check", "--json"],
                             {"FAKE_VULKAN_SUPPORTED": "0"})
            check(process.returncode == 3, "expected exit 3, got %d" % process.returncode)
            data = parse_json(process)
            check(data["ok"] is False, "open check should fail")
            check("geometry shaders" in json.dumps(data), "missing reason not included")

        def open_software_check() -> None:
            process = invoke(["open", "--backend", "software", "--check", "--json"],
                             {"FAKE_VULKAN_SUPPORTED": "0"})
            check(process.returncode == 0, "software check exit %d: %s" %
                  (process.returncode, process.stderr))
            data = parse_json(process)
            check(data["ok"] is True, "software check should pass")
            check(data["backend"] == "software", "expected software backend")
            check(data["api"] == "opengl", "expected OpenGL API")
            check(data["envOverrides"].get("LIBGL_ALWAYS_SOFTWARE") == "1",
                  "software env override missing")
            check("--gpu-backend" in data["command"], "GPU backend argv missing")

        def no_blender() -> None:
            process = invoke(["--blender", str(temp / "missing-blender"), "status", "--json"])
            check(process.returncode == 0, "status without Blender must exit 0")
            data = parse_json(process)
            check(data["available"] is False, "available should be false")
            check("not installed" in (data.get("error", {}).get("message", "")).lower(),
                  "missing actionable error")

        def launcher_help() -> None:
            process = invoke(["--help"], use_launcher=True)
            check(process.returncode == 0, "launcher help exit %d" % process.returncode)
            check("floe-blender" in process.stdout, "help output missing")

        def launcher_status() -> None:
            process = invoke(["status", "--json"], {"FAKE_VULKAN_SUPPORTED": "0"},
                             use_launcher=True)
            check(process.returncode == 0, "launcher status exit %d" % process.returncode)
            data = parse_json(process)
            check(data["available"] is True, "launcher status Blender unavailable")

        def render_eevee_software() -> None:
            output = temp / "eevee-software.png"
            process = invoke(["render", "--scene", str(fake_scene(temp)), "--engine", "eevee",
                              "--device", "software", "--output", str(output), "--json"],
                             {"FAKE_VULKAN_SUPPORTED": "0"})
            check(process.returncode == 0, "software render exit %d: %s" %
                  (process.returncode, process.stderr))
            data = parse_json(process)
            check(data["deviceClass"] == "software", "expected software class")
            check(output.is_file(), "software output missing")
            check(any(entry.get("env", {}).get("LIBGL_ALWAYS_SOFTWARE") == "1"
                      for entry in log_entries(fake_log)), "software env not passed")

        def render_gpu_software_renderer_rejected() -> None:
            output = temp / "gpu-fake-software.png"
            process = invoke(["render", "--scene", str(fake_scene(temp)), "--engine", "eevee",
                              "--device", "gpu", "--output", str(output), "--json"],
                             {"FAKE_VULKAN_SUPPORTED": "1",
                              "FAKE_RENDERER": "llvmpipe (LLVM 19.1.7, 256 bits)"})
            check(process.returncode == 3, "expected exit 3, got %d" % process.returncode)
            check(not output.exists(), "software pixels must not be published as GPU")

        def status_52_help_failure_does_not_hide_other_errors() -> None:
            process = invoke(["probe", "--json"], {"FAKE_VULKAN_SUPPORTED": "1"})
            check(process.returncode == 0, "probe exit %d" % process.returncode)
            data = parse_json(process)
            check(data["schema"] == "floe.blender.probe.v1", "probe schema mismatch")
            check(data["gpu"]["vulkan"]["blenderAdmission"]["supported"] is True,
                  "probe admission failed")

        def linux_only_guard() -> None:
            if sys.platform == "linux":
                return
            before = len(log_entries(fake_log))
            process = run([sys.executable, "-I", str(CLI), "status", "--json"], base_env)
            check(process.returncode == 6, "expected Linux-only guard exit 6, got %d" %
                  process.returncode)
            data = parse_json(process)
            check(data["ok"] is False and data["error"]["code"] == 6, "guard JSON error missing")
            check(len(log_entries(fake_log)) == before,
                  "Linux-only guard must not probe or launch Blender")

        def install_non_linux_guard() -> None:
            live = temp / "live-prefix"
            process = run([str(INSTALL), "--prefix", str(live)], base_env)
            if sys.platform == "linux":
                check(process.returncode == 0, "Linux install should succeed")
            else:
                check(process.returncode == 3, "non-Linux live install must refuse")
                check(not live.exists(), "refused install must not create a prefix")
            stage = temp / "stage-prefix"
            process = run([str(INSTALL), "--stage", str(stage)], base_env)
            check(process.returncode == 0, "staging install exit %d: %s" %
                  (process.returncode, process.stderr))
            check((stage / "bin/floe-blender").is_file(), "staged launcher missing")
            check((stage / "lib/floe/blender/floe_blender.py").is_file(), "staged CLI missing")

        def install_check() -> None:
            env = dict(base_env)
            env["PATH"] = str(fakebin) + os.pathsep + os.environ.get("PATH", "")
            process = run([str(INSTALL), "--check"], env)
            check(process.returncode == 0, "install --check exit %d: %s" %
                  (process.returncode, process.stderr))

        case("status unsupported", status_unsupported)
        case("status supported", status_supported)
        case("status 5.2 gpu-device help", status_52_help)
        case("render GPU fail-closed", render_gpu_unsupported)
        case("render Cycles CPU", render_cycles_cpu)
        case("render Cycles GPU unavailable", render_cycles_gpu_unavailable)
        case("render Cycles GPU selected", render_cycles_gpu_selected)
        case("edit paths and staged outputs", edit_paths)
        case("open GPU check fail-closed", open_gpu_check_unsupported)
        case("open software check", open_software_check)
        case("no Blender", no_blender)
        case("launcher help", launcher_help)
        case("launcher status", launcher_status)
        case("render EEVEE software", render_eevee_software)
        case("render GPU rejects software pixels", render_gpu_software_renderer_rejected)
        case("probe JSON", status_52_help_failure_does_not_hide_other_errors)
        case("Linux-only guard", linux_only_guard)
        case("install non-Linux guard", install_non_linux_guard)
        case("install --check", install_check)
    finally:
        shutil.rmtree(temp, ignore_errors=True)
    print("%d/%d passed" % (total - failures, total))
    return 0 if failures == 0 else 1


def fake_scene(directory: Path) -> Path:
    path = directory / "scene.blend"
    if not path.exists():
        path.write_bytes(b"BLENDER-v403" + b"\x00" * 2048)
    return path


if __name__ == "__main__":
    raise SystemExit(main())
