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

## What remains unproven

- No native Mesa compile/link, no guest boot, no Vulkan/OpenGL/OpenCL pixel, no
  video node, no Blender render and no performance measurement.
- The private macOS-hosted Linux results remain their original artifacts; they
  are not iOS or iPad acceptance.
- A new guest image requires a separately scheduled build and installed-image
  qualification. The App's shipped `FloeGPU` binary is unchanged.
