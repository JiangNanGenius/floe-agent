# OpenCL runtime source (CLVK over Venus)

Status: **source and build inputs only; no compiler, ICD load, kernel or GPU
result is contained here.** The guest must not advertise OpenCL until a real
ICD load and kernel execution are recorded.

This directory contains the reviewed Floe-owned patches and the runtime/
packaging contract for the genuine `kpet/clvk` OpenCL 3.0 ICD. It deliberately
does not vendor the upstream clvk, OpenCL-Headers, SPIRV-Headers, SPIRV-Tools,
LLVM or clspv trees; the producer takes clean checkouts at the pins below.

## Upstream pins

| Component | Pin | License |
| --- | --- | --- |
| clvk | `399abf00c30b6d1d7a65d7ac06beee60b5991d7b` (kpet/clvk) | Apache-2.0 |
| OpenCL-Headers | `386ca390b2f52efeb3e1a55a500690eb8013f60e` | Apache-2.0 |
| SPIRV-Headers | `2b7475f6d664efbad4d4315c94ecec9640831e5b` | Apache-2.0/MIT |
| SPIRV-Tools | `ba9a9e32160e2500ce1e48cc563a8fedaf596e6e` | Apache-2.0 |
| clspv (header only, `include/clspv/Sampler.h`) | `7ee3a40e652b3649d175758f72d7af98b9450a68` | Apache-2.0 WITH LLVM-exception |
| ocl-icd runtime package | `ocl-icd-libopencl1 2.3.3-1` arm64 | BSD-2-Clause |

`PINS.json` records the complete component/submodule set and hashes. License
texts are retained under `licenses/`.

## Build profile

The default `external-runtime` profile builds only the genuine CLVK ICD and
pinned SPIRV-Tools:

```
CLVK_EXTERNAL_CLSPV=ON
CLVK_COMPILER_AVAILABLE=ON
CLVK_CLSPV_ONLINE_COMPILER=OFF
CLVK_ENABLE_SPIRV_IL=OFF
CLVK_EXTERNAL_CLSPV_PATH=/usr/lib/floe-opencl/clspv
```

It still supports `clCreateProgramWithSource`/`clBuildProgram` by executing a
separately supplied, manifest-verified ARM64 Linux `clspv` process. `LLVM`,
`llvm-spirv`, tablegen and libclc are not built. The optional
`external-runtime-il` profile requires a verified external `llvm-spirv`; it is
not the default.

```sh
sh scripts/build_clvk_runtime_aarch64.sh --plan-only \
  --work /tmp/opencl-work --build /tmp/opencl-build --stage /tmp/opencl-stage \
  --plan-out /tmp/opencl-plan.json

sh scripts/build_clvk_runtime_aarch64.sh --check-only \
  --clvk-source /src/clvk --opencl-headers /src/OpenCL-Headers \
  --spirv-headers /src/SPIRV-Headers --spirv-tools /src/SPIRV-Tools \
  --sysroot /sysroot/debian-trixie-arm64 \
  --cross-file scripts/toolchains/aarch64-linux-floe.cmake \
  --work /tmp/opencl-work --build /tmp/opencl-build --stage /tmp/opencl-stage \
  --plan-out /tmp/opencl-plan.json
```

`--execute` additionally requires the pinned source checkouts and a verified
compiler manifest; without them the producer exits non-zero and packaging is
refused. `scripts/package_opencl_runtime.py` enforces the same admission,
SONAME/symlink and payload checks.

## Installed contract

- `/usr/lib/floe-opencl/libfloe_clvk.so.1` with a unique SONAME
- `/usr/share/floe-opencl/vendors/floe-clvk.icd`
- `/usr/lib/floe-opencl/clspv` (verified external process)
- `OCL_ICD_VENDORS`/`VK_DRIVER_FILES` set by `runtime/floe-opencl-env.sh`

`CL_DEVICE_COMPILER_AVAILABLE` reports the actual executable presence, not a
compile-time default. IL APIs return `CL_INVALID_OPERATION` in the
IL-disabled profile.

## Guest probe

`tools/floe_opencl_probe.py` is the runtime probe used by
`floe-accel compute opencl status` and `floe-accel compute opencl probe`.
Install it as `/usr/local/bin/floe-opencl-probe` (0755,
`#!/usr/bin/env python3`). It loads the system `libOpenCL.so.1` (normally
ocl-icd), enumerates the real platforms and devices, and reports loader,
ICD-entry and device facts. `run` submits fill/copy/readback/map commands and
verifies the bytes; when `CL_DEVICE_COMPILER_AVAILABLE` is true it also builds
and runs a small kernel. A missing loader, ICD, device or compiler is an
explicit failure/limitation, never synthesized from a filename or a source
tree.

This probe does not install the CLVK/ocl-icd/clspv payload and does not make
the CLVK source build runnable. The image still needs the admitted runtime
package. On an image without it, `status` returns exit 3 (loader missing) or
exit 4 (no ICD platform); that is the expected missing-component path.

On the M5 Pro Venus device, Debian Rusticl 25.0.7-2+deb13u1 exposes a Zink
GPU but its compute path terminates the graphics host. The probe lists this
device with a diagnostic and selects another usable device for automatic
checks. An explicit request for the affected GPU returns the diagnostic
before creating a context. Vulkan BLAS and OpenGL use their own paths.

## Truth boundary

- The stock `v8` image does not contain this CLVK runtime. An installed
  toolkit may add a different ICD; OpenCL is declared only after a real
  loader/device/kernel run, never from a source tree or a filename.
  `FloeAgent/LinuxGuest/image/graphics/CAPABILITY-POLICY.json` gates the
  `openCL` capability on the installed library, ICD and `clspv`.
- No CLVK ARM64 compiler build, CLVK ICD load, CLVK kernel build, CLVK
  numerical result, OpenCL conformance or App/iPad acceptance is present.
  A separate guest probe run against a different ICD does not change these
  CLVK gates.
- Do not copy upstream trees or build artifacts into this directory; the
  producer is reproducible from the pins above and the retained patches.
