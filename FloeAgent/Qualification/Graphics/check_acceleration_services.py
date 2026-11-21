#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Read-only contracts for the Linux acceleration services and App routing.

Runs on the development host without a Linux guest, GPU or App build. It
compiles the actual inventory struct extracted from the Terminal owner (when
Swift is available) and decodes both the old schemaVersion 1 body and the new
additive body. Dispatcher and probe checks are static; the behavioral Linux
checks live in acceleration_guest_checks.sh.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ACCEL = REPO / "FloeAgent" / "LinuxGuest" / "acceleration"
DISPATCHER = ACCEL / "floe-accel"
GL_PROBE = ACCEL / "graphics" / "floe_gl_probe.py"
OPENCL_PROBE = ACCEL / "opencl" / "tools" / "floe_opencl_probe.py"
OWNER = REPO / "FloeAgent" / "FloeApp" / "Terminal" / "LocalLinuxAccelerationOwner.swift"
VIEW = REPO / "FloeAgent" / "FloeApp" / "Terminal" / "LocalLinuxAccelerationView.swift"
GUEST_CHECKS = REPO / "FloeAgent" / "Qualification" / "Graphics" / "acceleration_guest_checks.sh"

OLD_STATUS = {
    "schemaVersion": 1,
    "graphics": {"deviceNodePresent": False, "inspectorInstalled": True},
    "video": {"clientInstalled": True, "decoderNodePresent": False, "encoderNodePresent": True},
    "compute": {"runnerInstalled": True, "probeInstalled": True, "providerInstalled": True},
    "blender": {"launcherInstalled": True, "applicationInstalled": False},
}
NEW_STATUS = {
    "schemaVersion": 1,
    "graphics": {
        "deviceNodePresent": True, "inspectorInstalled": True,
        "renderNodePresent": True, "cardNodePresent": True, "renderNodeCount": 2,
        "glxInspectorInstalled": True, "eglInspectorInstalled": False, "glProbeInstalled": True,
    },
    "video": {"clientInstalled": True, "decoderNodePresent": True, "encoderNodePresent": True,
              "videoNodeCount": 3},
    "compute": {"runnerInstalled": True, "probeInstalled": True, "providerInstalled": True,
                "openCLLoaderInstalled": True, "openCLICDCount": 1,
                "openCLProbeInstalled": True, "openCLCompilerInstalled": False},
    "blender": {"launcherInstalled": True, "applicationInstalled": True},
}

SWIFT_HARNESS = r"""
import Foundation

{inventory}

func decode(_ text: String) throws -> LinuxAccelerationInventory {{
    try JSONDecoder().decode(LinuxAccelerationInventory.self, from: Data(text.utf8))
}}

let old = try decode(#OLD#)
precondition(old.schemaVersion == 1)
precondition(old.graphics.deviceNodePresent == false)
precondition(old.graphics.inspectorInstalled == true)
precondition(old.graphics.renderNodePresent == nil)
precondition(old.graphics.glxInspectorInstalled == nil)
precondition(old.video.videoNodeCount == nil)
precondition(old.compute.openCLLoaderInstalled == nil)
precondition(old.compute.openCLICDCount == nil)
precondition(old.blender.launcherInstalled == true)

let new = try decode(#NEW#)
precondition(new.graphics.renderNodePresent == true)
precondition(new.graphics.renderNodeCount == 2)
precondition(new.graphics.eglInspectorInstalled == false)
precondition(new.video.videoNodeCount == 3)
precondition(new.compute.openCLLoaderInstalled == true)
precondition(new.compute.openCLICDCount == 1)
precondition(new.compute.openCLCompilerInstalled == false)

var rejected = false
do {{ _ = try decode(#"{{"schemaVersion":1}}"#) }} catch {{ rejected = true }}
precondition(rejected)
print("INVENTORY_DECODE_OK")
"""


class Failures:
    def __init__(self) -> None:
        self.items: list[str] = []
        self.checks = 0

    def add(self, condition: bool, message: str) -> None:
        self.checks += 1
        if not condition:
            self.items.append(message)


def extract_inventory(source: str) -> str:
    start = source.index("struct LinuxAccelerationInventory")
    depth = 0
    for index in range(start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError("inventory struct is not balanced")


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_probe_logic_checks(failures: Failures) -> None:
    gl = load_module("floe_gl_probe_check", GL_PROBE)
    failures.add(gl.classify("llvmpipe (LLVM 19)") == (False, True),
                 "software GL renderer classification changed")
    failures.add(gl.classify("Virtio-GPU Venus (Apple M5 Pro)") == (True, False),
                 "hardware GL renderer classification changed")
    failures.add(gl.classify("zink (Mesa)") == (None, None),
                 "unknown GL renderer must stay unknown")
    opencl = load_module("floe_opencl_probe_check", OPENCL_PROBE)
    failures.add(opencl._device_type_name(opencl.CL_DEVICE_TYPE_CPU) == "cpu",
                 "OpenCL CPU type classification changed")
    failures.add(opencl._device_type_name(opencl.CL_DEVICE_TYPE_GPU) == "gpu",
                 "OpenCL GPU type classification changed")
    options = opencl.Options(["--device", "gpu", "--size", "128", "--kernel", "off"])
    failures.add(options.device == "gpu" and options.size == 128 and options.kernel == "off",
                 "OpenCL option parsing changed")
    gpu = {"_id": 1, "type": "gpu", "name": "zink Vulkan 1.2(Virtio-GPU Venus (Apple M5 Pro) (MESA_VENUS))",
           "driverVersion": "25.0.7-2+deb13u1"}
    limitation = opencl.compute_probe_limitation("rusticl", gpu)
    failures.add(bool(limitation) and opencl.compute_probe_limitation("CLVK", gpu) is None
                 and opencl.compute_probe_limitation("rusticl", dict(
                     gpu, name="zink Vulkan 1.2(Apple M5 Pro (MESA_VENUS))")) == limitation
                 and opencl.compute_probe_limitation("rusticl", dict(gpu, driverVersion="26.0")) is None,
                 "Rusticl compatibility check must stay specific to the observed driver and device")
    gpu["computeProbeLimitation"] = limitation
    cpu = {"_id": 2, "type": "cpu"}
    platforms = [{"index": 0, "devices": [gpu, cpu]}]
    failures.add(opencl.select_device(platforms, "any")[1] is cpu,
                 "A working OpenCL device should be selected when available")
    from types import SimpleNamespace
    report, code = opencl.command_run_with(options, SimpleNamespace(name="test"), platforms)
    failures.add(code == opencl.EXIT_DEVICE and report["compute"]["operations"] == []
                 and report["errors"] == [limitation] and report["selectedDevice"]["type"] == "gpu",
                 "The affected GPU must remain identifiable without creating an OpenCL context")
    for invalid in ([], ["--device", "tpu"], ["--size", "0"], ["--size", str(2 ** 20 + 1)]):
        rejected = False
        try:
            opencl.Options(invalid)
        except ValueError:
            rejected = True
        failures.add(rejected, f"OpenCL options accepted invalid input {invalid}")
    failures.add(opencl._verify("same", b"abc", b"abc")["match"] is True,
                 "OpenCL verification no longer accepts equal bytes")
    mismatch = opencl._verify("mismatch", b"abc", b"abd")
    failures.add(mismatch["match"] is False and mismatch["firstMismatch"] == 2,
                 "OpenCL verification no longer reports the first mismatch")


def run_swift_inventory_check(failures: Failures) -> None:
    source = OWNER.read_text()
    inventory = extract_inventory(source)
    failures.add("var renderNodePresent: Bool?" in inventory, "renderNodePresent must be optional")
    failures.add("var videoNodeCount: Int?" in inventory, "videoNodeCount must be optional")
    failures.add("var openCLLoaderInstalled: Bool?" in inventory,
                 "openCLLoaderInstalled must be optional")
    failures.add("var openCLICDCount: Int?" in inventory, "openCLICDCount must be optional")
    failures.add("var cardNodeCount: Int?" in inventory, "cardNodeCount must be optional")
    failures.add("var eglLibraryInstalled: Bool?" in inventory,
                 "eglLibraryInstalled must be optional")
    failures.add("private var queryToken" in source, "query token missing")

    swift = Path("/usr/bin/xcrun")
    if not swift.exists():
        failures.add(False, "xcrun is unavailable; cannot compile the inventory decode harness")
        return
    harness = SWIFT_HARNESS.format(inventory=inventory)
    harness = harness.replace("#OLD#", json.dumps(json.dumps(OLD_STATUS)))
    harness = harness.replace("#NEW#", json.dumps(json.dumps(NEW_STATUS)))
    with tempfile.TemporaryDirectory(prefix="floe-inventory-") as work:
        path = Path(work) / "main.swift"
        binary = Path(work) / "inventory-check"
        path.write_text(harness)
        compilation = subprocess.run(
            [str(swift), "swiftc", "-swift-version", "6", str(path), "-o", str(binary)],
            capture_output=True, text=True)
        failures.add(compilation.returncode == 0,
                     "inventory Swift harness did not compile: " + compilation.stderr.strip()[:500])
        if compilation.returncode != 0:
            return
        execution = subprocess.run([str(binary)], capture_output=True, text=True)
        failures.add(execution.returncode == 0,
                     "inventory decode failed: " + (execution.stderr or execution.stdout).strip()[:500])


def run_source_checks(failures: Failures) -> None:
    for path in (DISPATCHER, GL_PROBE, OPENCL_PROBE, OWNER, VIEW, GUEST_CHECKS):
        failures.add(path.is_file(), f"missing required source {path.relative_to(REPO)}")
    dispatcher = DISPATCHER.read_text()
    gl_probe = GL_PROBE.read_text()
    opencl_probe = OPENCL_PROBE.read_text()
    owner = OWNER.read_text()
    view = VIEW.read_text()

    syntax = subprocess.run(["/bin/sh", "-n", str(DISPATCHER)], capture_output=True, text=True)
    failures.add(syntax.returncode == 0, "floe-accel is not valid POSIX shell: " + syntax.stderr)
    for source, label in ((gl_probe, "floe_gl_probe.py"), (opencl_probe, "floe_opencl_probe.py")):
        try:
            compile(source, label, "exec")
        except SyntaxError as error:
            failures.add(False, f"{label} syntax error: {error}")

    failures.add('"schemaVersion":1' in dispatcher, "status must keep schemaVersion 1")
    for key in ('"graphics"', '"deviceNodePresent"', '"inspectorInstalled"', '"video"',
                '"clientInstalled"', '"decoderNodePresent"', '"encoderNodePresent"',
                '"compute"', '"runnerInstalled"', '"probeInstalled"', '"providerInstalled"',
                '"blender"', '"launcherInstalled"', '"applicationInstalled"'):
        failures.add(key in dispatcher, f"status lost old key {key}")
    for key in ('"renderNodeCount"', '"cardNodeCount"', '"glxInspectorInstalled"',
                '"eglInspectorInstalled"', '"eglLibraryInstalled"', '"glProbeInstalled"',
                '"videoNodeCount"', '"openCLLoaderInstalled"',
                '"openCLICDCount"', '"openCLProbeInstalled"', '"openCLCompilerInstalled"'):
        failures.add(key in dispatcher, f"status is missing additive key {key}")
    failures.add("/dev/dri/renderD128" not in dispatcher, "status still hardcodes renderD128")
    failures.add("/dev/video0" not in dispatcher and "/dev/video1" not in dispatcher,
                 "status still hardcodes V4L2 indexes")
    failures.add("unset DISPLAY WAYLAND_DISPLAY" in dispatcher,
                 "graphics status does not clear the display environment")
    failures.add(dispatcher.index("unset DISPLAY WAYLAND_DISPLAY")
                 < dispatcher.index("exec vulkaninfo --summary"),
                 "display clearing is not before vulkaninfo --summary")
    failures.add("info)" in dispatcher and "exec floe-gl-probe glx" in dispatcher,
                 "graphics info lost the real-display GLX path")
    for entry in ("graphics info", "graphics egl", "compute opencl status",
                  "compute opencl probe", "floe-gl-probe", "floe-opencl-probe"):
        failures.add(entry in dispatcher, f"dispatcher is missing {entry}")
    failures.add("grep -F -- \"$token\"" in owner, "App dispatcher feature detection is missing")
    failures.add("--capabilities" in owner and "floe-accel-api: 2" in owner,
                 "App does not require the current dispatcher contract")
    failures.add("floe-accel-api: 2" in dispatcher,
                 "dispatcher does not advertise its current contract")
    failures.add("LocalLinuxAccelerationInstaller.command()" in owner,
                 "owner does not route the installer command")
    failures.add("standardInput: install?.standardInput" in owner,
                 "owner does not feed installer stdin")
    failures.add('arguments == ["install-tools"]' in owner, "installer argument is not fixed")
    failures.add("installTools(environmentID:" in owner, "install entry point is missing")
    failures.add('t("安装加速工具", "Install Acceleration Tools")' in view,
                 "view is missing the install action")
    failures.add("openCLProbeInstalled" in view, "view does not gate OpenCL on its probe")

    failures.add("glGetString" in gl_probe and "glReadPixels" in gl_probe,
                 "GL probe does not read renderer/pixels")
    failures.add("EGL_PLATFORM_SURFACELESS_MESA" in gl_probe, "GL probe lacks headless EGL")
    failures.add("rendered" in gl_probe and "readback" in gl_probe,
                 "GL probe does not report the actual render")
    failures.add("clGetPlatformIDs" in opencl_probe and "clGetDeviceIDs" in opencl_probe,
                 "OpenCL probe does not enumerate ICD platforms/devices")
    failures.add("clEnqueueFillBuffer" in opencl_probe and "clEnqueueCopyBuffer" in opencl_probe
                 and "clEnqueueReadBuffer" in opencl_probe,
                 "OpenCL probe lacks a verifiable device operation")
    failures.add("clBuildProgram" in opencl_probe, "OpenCL probe lacks the optional kernel path")
    failures.add("CL_DEVICE_COMPILER_AVAILABLE" in opencl_probe,
                 "OpenCL probe does not honor compiler availability")
    for forbidden in ("subprocess", "urllib", "http.client", "socket"):
        failures.add(forbidden not in gl_probe and forbidden not in opencl_probe,
                     f"probe unexpectedly imports {forbidden}")

    private = re.compile(r"/(?:Volumes|Users|home)/[A-Za-z0-9_.-]+/|job-[0-9a-f]{6,}")
    for path in (DISPATCHER, GL_PROBE, OPENCL_PROBE, OWNER, VIEW, GUEST_CHECKS):
        match = private.search(path.read_text())
        failures.add(match is None, f"private path/worker marker in {path.relative_to(REPO)}")


def main() -> int:
    failures = Failures()
    try:
        run_source_checks(failures)
        run_probe_logic_checks(failures)
        run_swift_inventory_check(failures)
    except Exception as error:  # noqa: BLE001 - a check failure is the result
        failures.add(False, f"unexpected check failure: {error}")
    if failures.items:
        for item in failures.items:
            print("FAIL:", item, file=sys.stderr)
        print(f"ACCELERATION_SERVICE_CHECKS_FAILED {len(failures.items)}/{failures.checks}",
              file=sys.stderr)
        return 1
    print(f"ACCELERATION_SERVICE_CHECKS_OK {failures.checks}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
