# Focused BLAS provider tests

No test listed here has been executed in the current source-only candidate.
The shared native/VM window is withheld, so all commands below are future
instructions for the primary or an explicitly granted window.

## 1. Source/interface checks (safe without a compiler)

```sh
cd FloeAgent/LinuxGuest/acceleration/blas
make check
```

`tests/run_source_checks.py` verifies:
- C delimiter balance, exported symbol set, no unsupported `dgemm`/complex
  exports, recursion guard, `RTLD_NEXT` + loaded-object scan, no
  `RTLD_DEFAULT`, float32 reference accumulation and finite guards.
- Shader GLSL interface and host push-constant field order/size.
- Every C source/header, shell syntax, activation/config paths, `--status`
  JSON on a non-guest host, no host `LD_PRELOAD` mutation.
- Makefile's fail-closed missing-SPIR-V rule and exact install paths.
- `tests/hostile_path_fixture.py`: hostile-but-valid HOME/XDG path text
  (quote, backslash, newline, tab, DEL, UTF-8) must not corrupt status JSON;
  safe paths with spaces remain normal strings.  This is a source-level shell
  fixture, not a guest runtime test.

`python3 build/build_spirv.py --source-check` validates the GLSL declarations
without invoking a shader compiler.

## 2. Native compile / focused ABI tests (future)

After generating the real SPIR-V headers and building in the approved window:

```sh
make tests
./build/floe-blas-tests
```

The binary links the provider directly.  Its matrix covers:

- row-major and column-major GEMM;
- `NoTrans`, `Trans` and `ConjTrans` combinations;
- padded leading dimensions (`lda`/`ldb`/`ldc`) and no C-padding clobber;
- `alpha`/`beta` including `beta=0` and `beta!=0`;
- `m=0`/`n=0`, `k=0`, `alpha=0`, invalid `lda` and bad Fortran transpose
  (C must remain untouched on rejected work);
- in-place `C == A` / aliased GEMM;
- Fortran `sgemm_`;
- GEMV row/column, transposed, positive/negative increments, `alpha`/`beta`;
- four concurrent threads;
- a real 512×512 float32 GEMM counter assertion:
  `gpu_submitted >= 1`, `gpu_completed >= 1`, `gpu_dispatches >= 1` and exact
  or tolerant output agreement.

Exit codes: 0 = pass; 77 = all non-GPU checks passed but no Venus device was
available (skip, not a GPU pass); 1 = failure.

## 3. Real NumPy same-process comparison (future guest)

```sh
floe-blas-run -- python3 tests/numpy_blas_compare.py --size 512
```

It requires `LD_PRELOAD` to name the installed provider.  It records actual
stats deltas through `floe_blas_stats_get` and asserts:

- `A @ B` float32 produces a positive `gpu_completed` delta;
- a small float32 product produces zero GPU delta (threshold/fast path);
- a float64 `A @ B` produces zero GPU delta (dgemm is untouched);
- maximum absolute/relative error against a float64 CPU reference is within
  tolerance;
- elapsed time includes provider upload/dispatch/readback after a separate
  warmup.

It is not a NumPy/OpenBLAS speed benchmark and does not assert a speedup.

## 4. Explicit probe and mode checks (future guest)

```sh
floe-blas-probe --activation-json
floe-blas-probe --size 512
floe-blas-run --status
floe-blas-run --set-mode off
floe-blas-run --status          # mode=off, preloadActive=false
floe-blas-run --set-mode auto
floe-blas-run --status          # mode=auto, ready iff assets/device exist
floe-blas-run --mode off -- python3 tests/numpy_blas_compare.py
```

`floe-blas-probe --size 512` performs a real GPU GEMM and fails nonzero if no
provider submission/completion occurred.  It reports the device and actual
counters, not a simulated count.

## 5. Unrun evidence

- No shader was compiled or validated by SPIR-V tools.
- No provider/library/test/probe binary was compiled or linked.
- No Vulkan loader/device was opened; no VM/guest/NumPy run occurred.
- No installation into a guest root occurred.
- No performance result is claimed; the previously measured 2.52× number was
  a naive-C comparison from the existing proof, not NumPy/OpenBLAS.
