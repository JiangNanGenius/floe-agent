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

## Truth boundary

- The existing `v8` image does not contain this runtime and must not declare
  OpenCL. `FloeAgent/LinuxGuest/image/graphics/CAPABILITY-POLICY.json` gates
  the `openCL` capability on the installed library, ICD and `clspv`.
- No ARM64 compiler build, ICD load, kernel build, numerical result, OpenCL
  conformance or App/iPad acceptance is present. Those are separate native
  and installed-image gates.
- Do not copy upstream trees or build artifacts into this directory; the
  producer is reproducible from the pins above and the retained patches.
