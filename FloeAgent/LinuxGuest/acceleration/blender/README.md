# Floe Linux Blender workbench (`floe-blender`)

Status: candidate source, not yet built into a guest image and not executed
against a real Linux VM. This package adds callable Blender entries for the
resolved Floe Linux guest; it does not add a native host renderer and does not
replace the existing `exec.shell`/job lifecycle.

## What it is

`floe-blender` is a small guest CLI plus a Blender-side Python helper. The CLI
resolves the Blender binary that is installed **inside the Linux environment**
(normally the Debian `blender` package, or a staged guest runtime selected with
`FLOE_BLENDER_ROOT`), builds argv without a shell, runs Blender in background
for editing/rendering, validates staged outputs, and only then commits them.

Interactive launch uses the `DISPLAY` inherited from the existing Floe
project/display owner. It never starts an X server, a VNC server or a desktop,
and never invokes native macOS Blender. Every handler (including `status` and
`open`) refuses to run when the runtime platform is not Linux; `--help` is
pure documentation. There is no environment or path-prefix bypass, so a
Mach-O Blender copied to an arbitrary temporary path cannot be executed by
this entry point.

## Commands

```sh
floe-blender status --json
floe-blender probe --json

# Headless deterministic edit: boolean, bevel, subdivision (applied),
# optional user Python, save and/or GLB export.
floe-blender edit \
  --input /workspace/in.blend \
  --object "Body" --boolean-difference "Cutter" \
  --bevel 0.05 --bevel-segments 3 --subdivide 1 \
  --save /workspace/out.blend --export-glb /workspace/out.glb --json

# Fixed smoke scene (real boolean/bevel/subdivision + 14 meshes).
floe-blender edit --new --demo-housing \
  --save /workspace/demo.blend --export-glb /workspace/demo.glb --json

# Export only.
floe-blender export --scene /workspace/in.blend --output /workspace/out.glb --json

# CPU Cycles render (cold/warm in one Blender process).
floe-blender render --scene /workspace/demo.blend --engine cycles --device cpu \
  --output /workspace/cycles.png --resolution 256 --samples 8 --repeat 2 --json

# Explicit EEVEE software fallback (llvmpipe; result is marked software).
floe-blender render --scene /workspace/demo.blend --engine eevee --device software \
  --output /workspace/eevee-software.png --resolution 256 --samples 8 --json

# GPU requests fail closed when the driver does not meet Blender's admission
# requirements. They never silently become CPU/software.
floe-blender render --scene /workspace/demo.blend --engine eevee --device gpu \
  --output /workspace/eevee-gpu.png --json

# Primary UI entries: default explicit GPU, software only as a user choice.
floe-blender open --backend gpu
floe-blender open --backend software
# Preflight without launching (used by the UI/tests):
floe-blender open --backend gpu --check --json
```

All scene/script/output paths are guest paths. They are passed as argv, never
through a shell or evaluated as command text. `edit --script` runs a guest
Blender Python file with Blender's normal Python privileges; it is not a
sandbox escape hatch and does not grant host access.

## Output and safety contract

- `edit`/`export`/`render` write to a temporary file in the destination
  directory, validate it, then `os.replace` it into place. Existing outputs
  are refused unless `--force` is given.
- `.blend` output must have the `BLENDER` magic and a non-trivial size. GLB
  output must have a valid `glTF` v2 header, JSON chunk, and scene
  meshes/nodes/accessors. PNG output is sampled by Blender and rejected if it
  is blank, non-finite, or lacks variation.
- A missing completion record from the Blender helper is a failure even if
  Blender exits zero. Blender Python errors use `--python-exit-code 7`.
- The wrapper does not impose a render/encoding deadline by default. The
  parent job owns timeout and cancellation; Ctrl-C/SIGTERM are forwarded to
  the Blender child in the same process group.
- Scratch/log files are created next to the output by default. A failed run
  keeps the log and reports its path and tail; a successful run removes the
  temporary log unless `--log` was supplied.
- `status` and `probe` are passive: they do not render. `status` may run
  `blender --version`, a short background probe, `vulkaninfo` and `glxinfo`.
  It does not start Blender's GUI.
- GPU EEVEE rendering is accepted only after the actual renderer string is
  non-software and the backend matches the requested Vulkan/OpenGL backend.
  Any mismatch discards the staged PNG. Cycles GPU is accepted only when a
  real CUDA/OptiX/HIP/oneAPI/Metal device is selected; the result records
  `hardwareVerified: false` because device selection alone is not proof of
  GPU submission. External GPU counters remain the acceptance evidence.

## Backend selection and current limits

`status --json` separates:

- `blender`: resolved binary/source/version; whether the Vulkan backend is
  compiled; the background probe result.
- `gpu.vulkan`: raw device name/driver, relevant extensions/features, the
  installed Blender version's admission policy, missing capabilities, and the
  swapchain advertisement/gate.
- `gpu.opengl`: `glxinfo -B` renderer/version and whether it meets Blender's
  OpenGL 4.3 minimum.
- `gpu.cycles`: compiled Cycles backends and enumerated devices.
- `backends.gpu` / `backends.software`: `renderAvailable` and
  `interactiveAvailable` (the latter also requires a reachable `DISPLAY`).

The current verified Venus/Mesa 25.0.7 stack on the Apple host exposes
Vulkan 1.2 with `geometryShader=false`, `logicOp=false`, and no
`VK_KHR_swapchain`, while OpenGL is 2.1/GLSL 1.20 through Zink. Stock
Blender 4.3.2 requires geometry shaders, logical operations and
`VK_KHR_swapchain` on Linux, so GPU EEVEE/viewport and GPU interactive launch
are expected to fail closed. Cycles has no Vulkan backend in 4.3/5.2, so
Cycles GPU is unavailable regardless of Vulkan. These are driver/version
gaps, not wrapper gaps; see the private compatibility note delivered with this
candidate for the exact source lines and the separate Mesa/Blender patch
targets. CPU Cycles and explicit llvmpipe EEVEE remain available when the
guest actually provides them.

The missing swapchain extension is not a simple Meson toggle: Venus compiles
the WSI frontend, but Mesa 25.0.7 only advertises `VK_KHR_swapchain` when the
host renderer provides external-memory and importable sync-fd semaphores.
Mesa 26.2+ removes that gate; this requires a newer guest Mesa image, not a
launcher flag. It would still not make Blender pass its geometry-shader
admission check.

## Resolution and environment

Order: `--blender` > `FLOE_BLENDER_BIN` > `--root`/`FLOE_BLENDER_ROOT` >
`blender` in `PATH` > `/usr/bin/blender` > `/usr/local/bin/blender` >
`/opt/blender/blender` > `/floe/cache/usr/bin/blender`.

A staged root (`--root`, `FLOE_BLENDER_ROOT`) must contain
`usr/bin/blender`, `usr/share/blender/scripts`, `usr/share/blender/datafiles`,
and the runtime libraries. The wrapper uses the guest AArch64 loader with an
explicit library path, matching the existing prepared-runtime launcher. It
rejects an ELF binary whose machine is not AArch64, so a macOS/iOS binary
cannot be used by mistake.

The wrapper inherits the project environment, including `DISPLAY`,
`VK_DRIVER_FILES`, `VN_PERF` and the private Floe GLVND/Zink variables. It
does not synthesize a display or override GPU variables for a GPU request.
For explicit software mode it removes the private `floe-gpu` GLVND/DRI
variables and sets `LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`,
`MESA_LOADER_DRIVER_OVERRIDE=llvmpipe`.

## Install

```sh
# Live Linux image/build user:
./install.sh --prefix /usr/local
# Host-side offline image staging (explicit owned prefix; labeled as staging):
./install.sh --stage /owned/image/root
# Read-only source and dependency check (allowed on any host):
./install.sh --check
```

A non-Linux host cannot perform a live `/usr/local` install; the script
refuses it unless `--stage` names an explicit owned image root. The staging
mode copies files only and does not install packages or run Blender.

Installed files:

| Host source | Guest path | Mode |
| --- | --- | --- |
| `floe-blender` | `/usr/local/bin/floe-blender` | 0755 |
| `floe_blender.py` | `/usr/local/lib/floe/blender/floe_blender.py` | 0644 |
| `blender_ops.py` | `/usr/local/lib/floe/blender/blender_ops.py` | 0644 |

Requirements: guest Python 3, Blender 4.3+ arm64 (Debian `blender` package or
staged runtime), and optionally `mesa-utils`/`vulkan-tools` for `status`
diagnostics. The script does not install packages.

## Integration ownership

The common `floe-accel` dispatcher, Terminal UI, App source, central
`Package.swift`/`project.yml`/PBX, image composition and release/version work
belong to the primary owner. This candidate only adds the guest-side command
and its documentation/tests. `status --json` and `open --backend gpu|software`
are the stable UI-facing entries; the UI should default to an explicit GPU
request and offer software only as a user-selected fallback.
