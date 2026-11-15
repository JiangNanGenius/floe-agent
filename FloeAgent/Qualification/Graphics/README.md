# Graphics source qualification

Focused, no-device checks for the Linux graphics intake. They compile and run
the real production FloeVirtualGPU budget/ledger sources and exercise the
`FloeLinuxGPU` capability types. They do not open a renderer, GPU, VM,
Simulator, App or physical device, and they do not prove a graphics image.

Run:

```sh
bash FloeAgent/Qualification/Graphics/run_source_checks.sh
```

To additionally dry-run the guest Mesa 25.0.7 WSI patch against an extracted
pristine tree:

```sh
bash FloeAgent/Qualification/Graphics/run_source_checks.sh --mesa-tree /path/to/mesa-25.0.7
```

## What passes and what it means

- `FVGpuBudgetTests.c` covers the real `fvgpu_budget.c` / `fvgpu_ledger.c`:
  lowering never reclaims live resources, pending targets converge only after
  real releases, aliased imports are reported but not charged, an unmatched
  release faults the ledger and refuses all later admission, and an overflowing
  alias counter never wraps.
- The same source with assertions enabled must still abort at the original
  invariant assertion, after emitting the bounded fault trace. That expected
  non-zero exit is checked explicitly.
- The shm backing test covers the HOST3D export-length guard: the requested
  blob bytes, not the page-rounded length, must be backed.
- `FloeLinuxGPU` tests require evidence for every available capability,
  enforce the `venusVulkan → openGL → shaderCache` and `venusVulkan → openCL`
  gates, keep stopped/CPU-only/reset devices unavailable, and reject software
  Vulkan/OpenGL probe reports.
- `verify_graphics_sources.py` verifies every source-selection and patch digest.
- `check_acceleration_services.py` verifies the dispatcher's additive schema-1
  inventory (including non-fixed DRM/V4L2 discovery), the App's fixed
  `install-tools` routing and dispatcher fallback, the two Python probes, and
  compiles the actual `LinuxAccelerationInventory` struct to decode both the
  old body and the new additive body.
- `acceleration_guest_checks.sh` is the Linux behavior test. It uses fake
  tools/nodes and a real POSIX shell to check status JSON, missing-component
  exit 69, OpenGL/OpenCL routing, installer-independent probing and the
  `DISPLAY` clearing boundary. It does not touch a GPU, display server, package
  manager or network. Run it inside a disposable guest (root enables the fake
  node-count check).

## What remains unproven

- No native Mesa compile/link, no guest boot in these host checks, no
  Vulkan/OpenGL/OpenCL pixel, no video node, no Blender render and no
  performance measurement. Real private v8 evidence is separate: GLX via
  Xvnc/llvmpipe with an exact readback and the dispatcher/old-new-dispatcher
  compatibility run; those are not GPU or App acceptance.
- The private macOS-hosted Linux results remain their original artifacts; they
  are not iOS or iPad acceptance.
- A new guest image requires a separately scheduled build and installed-image
  qualification. The App's shipped `FloeGPU` binary is unchanged.
