# Floe Linux guest standard BLAS Vulkan provider

Status: **SOURCE-READY ONLY — not compiled, not installed, not runtime-tested.**
No native compiler, Vulkan runtime, VM or device was invoked while producing
this candidate.  The GLSL source is checked in; the required SPIR-V asset is
built by `build/build_spirv.py` and is intentionally absent until a trusted
`glslangValidator`/`glslc` runs.  The provider's build fails clearly until
that asset exists.

This package makes existing Linux `python3`/NumPy programs call the already
qualified Venus → virglrenderer → MoltenVK/Metal Vulkan compute path through
an `LD_PRELOAD` interposer.  It does **not** modify NumPy, OpenBLAS,
`libblas3` or any application source, and it does not claim a NumPy/OpenBLAS
speedup.  Only float32 GEMM/GEMV are intercepted; float64, complex and all
other BLAS symbols stay on the original guest library.

## Exact installed paths

| Purpose | Path |
| --- | --- |
| Provider library (interposer) | `/usr/local/lib/floe-acceleration/libfloe_blas.so` |
| Normal activation entry | `/usr/local/bin/floe-blas-run` |
| Explicit diagnostic entry | `/usr/local/bin/floe-blas-probe` |
| Shared shell policy | `/usr/local/lib/floe-acceleration/floe-blas-shell.sh` |
| Sourceable activation fragment | `/usr/local/share/floe-acceleration/floe-blas-activate.sh` |
| Environment/config defaults | `/usr/local/share/floe-acceleration/floe-blas.env` |
| Public stats header | `/usr/local/include/floe-acceleration/floe_blas.h` |
| Optional focused test binary | `/usr/local/libexec/floe-acceleration/floe-blas-tests` |

The proposed path from the primary dispatcher is preserved exactly:
`/usr/local/lib/floe-acceleration/libfloe_blas.so`.  The library's SONAME is
`libfloe_blas.so`.

## Normal entry and activation

The preferred integration is the primary-owned call:

```c
execv("/usr/local/bin/floe-blas-run",
      (char *const[]){ "floe-blas-run", "--", original_argv[0], ... NULL });
```

for new `EXEC`/`OPEN`/`SPAWN` task children, gated by the provider library,
`/dev/dri/renderD128` and the wrapper itself.  The wrapper's bare `--` form
uses the per-environment policy and preserves the caller's environment and
any existing `LD_PRELOAD`:

```sh
floe-blas-run -- python3 existing_script.py
floe-blas-run --status
floe-blas-run --mode off|auto|on -- COMMAND ARGS
floe-blas-run --set-mode off|auto|on
```

- `auto` (default): activate only when the trusted root-owned library, the
  virtio-gpu render node and the Venus ICD are all present; otherwise run the
  command untouched, with no broken preload warning.
- `on`: explicit preference.  The wrapper refuses with exit 3 if the provider
  is unavailable; a GPU failure inside an accepted call still falls back to
  the original BLAS.
- `off`: never preload the provider.

`--status` emits one-line JSON with: `ok`, `version`, `guest`, `mode`,
`modeSource`, `library`, `libraryPresent`, `libraryTrusted`, `gpuNode`,
`gpuNodePresent`, `icd`, `icdPresent`, `wouldActivate`, `preloadActive`,
`detail`, `configPath`, `configPathState`.  Because HOME/XDG may legally contain
quotes, backslashes or control bytes, a raw JSON string is emitted only for
printable ASCII without quote/backslash.  Other path bytes are explicitly
rejected: `configPath` is null and `configPathState` is
`unsupported-bytes` (or `unset`).  `--set-mode` refuses such a path before any
write and emits no success JSON.

The sourceable fragment is available for an existing shell entry, but it is
not required for the primary's wrapper route:

```sh
. /usr/local/share/floe-acceleration/floe-blas-activate.sh
```

It checks the same fixed guest paths, preserves `LD_PRELOAD`, and does nothing
on the macOS host.  The optional C helper
(`src/floe_blas_activate.{c,h}`) exposes the same lazy activation for a
trusted guest C runner; primary explicitly chose the wrapper route instead, so
no runner integration or duplicate policy implementation is required.

### Per-environment policy field

`--set-mode` writes atomically (mode 0600, temp file + `mv`) to:

```
$XDG_CONFIG_HOME/floe-acceleration/blas.conf
# or, when XDG_CONFIG_HOME is unset:
$HOME/.config/floe-acceleration/blas.conf
```

The only recognized line is:

```
mode=auto|on|off
```

Precedence is `FLOE_BLAS_MODE` environment → per-environment config → `auto`.
The provider itself reads the same file, so a direct preload without the
wrapper still observes the saved policy.  Unsafe files (wrong owner,
group/world-writable, non-regular) are ignored.

### Environment fields

| Field | Default | Meaning |
| --- | --- | --- |
| `FLOE_BLAS_MODE` | unset/auto | `off`, `auto`, `on` |
| `FLOE_BLAS_MIN_FLOPS` | `268435456` | auto GEMM threshold (2·M·N·K) |
| `FLOE_BLAS_GEMV_MIN_FLOPS` | `4194304` | auto GEMV threshold (2·M·N) |
| `FLOE_BLAS_MAX_GPU_BYTES` | `268435456` | per-call host-visible buffer budget |
| `FLOE_BLAS_TIMEOUT_MS` | `60000` | fence/backpressure timeout |
| `FLOE_BLAS_VERBOSE` | `0` | one-line initialization/device-loss diagnostics |
| `FLOE_BLAS_ACTIVE` | set by activation | `1` only when the wrapper preloaded |
| `FLOE_BLAS_DISABLE_ACTIVATION` | `0` | shell-fragment escape hatch |
| `FLOE_BLAS_ALLOW_UNTRUSTED` | not supported | never relax the root-owned library check |

These fields are for the resolved Linux guest only.  The wrapper and fragment
must never be sourced or installed on the native macOS host.

## What is intercepted

LP64 (32-bit index) symbols only:

- `cblas_sgemm`, `sgemm_`, `sgemm`
- `cblas_sgemv`, `sgemv_`, `sgemv`

The provider preserves row-major/column-major order, `NoTrans`/`Trans`/
`ConjTrans` (real matrices), leading dimensions, `alpha`/`beta`, GEMV
increments (including negative strides), in-place `C`/`Y` and aliased input
semantics by copying inputs before execution.  Bad dimensions/leading
dimensions/transpose enums/zero increments return without overwriting the
output.  `m == 0`/`n == 0` quick-return, `k == 0` and `alpha == 0` are handled
as scale-only operations.

Not intercepted or advertised: `dgemm`, `sgemm` ILP64 `*64_` variants,
complex BLAS, other BLAS routines, multi-GPU, sparse operations, any Python
API.  `double` is never cast to `float`; float64 calls continue through the
original library.

Fallback order for a valid float32 call:

1. If policy allows and limits pass, Vulkan compute.
2. On unsupported/small/budget/non-finite/device failure, the original guest
   `cblas_sgemm`/`cblas_sgemv` found via `RTLD_NEXT` or a loaded-object scan.
3. If only Fortran `sgemm_`/`sgemv_` exists, an ABI-compatible adapter.
4. Last resort: portable float32 reference loops (never used to claim GPU).

The interposer never calls itself recursively; a thread-local guard forces the
reference path during an original-provider callback.

## Vulkan backend

- Headless only: no surface, swapchain, display or X server.
- Accepts only a non-CPU device whose reported name contains `Venus`; rejects
  CPU/lavapipe/swiftshader devices.
- Caches instance, device, descriptor set, pipeline layout and both compute
  pipelines.  Input/output buffers are host-visible and cached in a small
  bounded pool.  Non-coherent memory uses explicit flush/invalidate.
- General runtime `M/N/K`, strides, transpose, `alpha`/`beta`; the shader has
  no fixed matrix size.
- A failed submit, fence timeout or device loss marks the context faulted and
  returns to the original CPU BLAS **before any output is published**.  A
  submitted/timeout context is deliberately not destroyed under a live driver
  reference; later calls stay on CPU.
- Limits: spans ≤ 2^30 floats, per-call bytes ≤ `FLOE_BLAS_MAX_GPU_BYTES`,
  dispatch counts ≤ device limits, output/all inputs checked with `isfinite`.
- Actual counters: `gpu_submitted` only after `vkQueueSubmit` succeeds,
  `gpu_completed` only after fence + finite readback + publication, plus
  dispatch/fallback/budget/threshold/device-loss counters.  No synthetic
  GPU count and no CPU compute labelled GPU.

## Stats API and probe

`include/floe_blas.h` defines the optional C stats API:
`floe_blas_stats_get`, `floe_blas_stats_reset`, `floe_blas_warmup`,
`floe_blas_version`, `floe_blas_policy_set`.

```sh
floe-blas-probe --size 512
floe-blas-probe --activation-json
```

`--size 512` performs one real row-major float32 GEMM through the provider,
compares it with a CPU reference, and prints JSON including device,
`gpuSubmitted`, `gpuCompleted`, `gpuDispatches`, fallbacks, error and elapsed
time.  It exits nonzero if no GPU result was produced.  This is a diagnostic
of one GEMM, not a NumPy/OpenBLAS performance result.

## Build

The exact recipe and inputs are in `build/BUILD-RECIPE.txt`.  The short form:

```sh
python3 build/build_spirv.py     # trusted glslangValidator/glslc required
make CC=<cross-cc> TARGET_FLAGS="<target/sysroot flags>" -j2
make check                       # source/interface checks, no compiler? see below
```

`make check` currently invokes Python source checks and the shader source
check; it does not invoke a native compiler.  `make` requires the generated
SPIR-V headers and fails with a clear message if they are absent.

## Future verification (not run here)

```sh
# install into a prepared Debian ARM64 root
scripts/install-floe-blas.sh --root /path/to/base --build build

# inside the real guest
floe-blas-run --status
floe-blas-probe --size 512
floe-blas-run -- python3 tests/numpy_blas_compare.py --size 512
floe-blas-run --set-mode off
floe-blas-run --status
floe-blas-run --set-mode auto
/usr/local/libexec/floe-acceleration/floe-blas-tests
```

See `tests/README.md` for the focused test matrix and exit-code contract.
These checks require the actual Linux guest; source presence or compilation
alone is not runtime qualification.

## Process lifetime

The GNU Linux provider registers explicit Vulkan buffer, pipeline, device and
instance cleanup after successful initialization, before loader finalization.
Successful calls already wait their fences; exit adds no unbounded device-idle
wait. A faulted queue stays with kernel/context teardown. Fork children cannot
use or destroy copied parent GPU handles; an exec loads a fresh provider.

