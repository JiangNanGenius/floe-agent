# MLXSwiftLM — Floe in-repo vendored package

English | [中文](#中文说明)

## What this is

A local Swift package copy of [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm)
pinned to the immutable revision already present in this repository's SwiftPM
checkouts:

| Field | Value |
| --- | --- |
| Upstream | `https://github.com/ml-explore/mlx-swift-lm` |
| Revision | `d5d8b290e601ac1bf11f24635f8f811a83b98bf8` |
| License | MIT (`LICENSE`, Copyright (c) 2024 ml-explore) — retained verbatim |
| Content | full package tree minus `.git` and build artifacts |
| Local patches | `patches/0001-gdn-prefill-t1-ops-route.patch` (Floe), `patches/0002-llmmodel-prefill-window-error-fail-fast.patch` (Floe) |

It exists so the app can depend on the package with
`.package(path: "FloeAgent/ThirdParty/MLXSwiftLM")` without a network resolve to
a floating revision. `Package.swift` is upstream's file, unmodified.

## Why this copy exists (Build227 GDN prefill hotfix)

Build227 reported that Qwen3.8/Qwen3.5 GDN (gated delta net) **multi-token
prefill** could async-crash in the fused Metal kernel path of
`Libraries/MLXLMCommon/GatedDelta.swift` (`gated_delta_step`). This is a
**suspicion**, not device-proven here.

The hotfix keeps the upstream `Dk % 32 == 0` kernel gate and changes only the
routing in `gatedDeltaUpdate`:

- `T == 1` (single-token decode) → fused Metal kernel (unchanged fast path);
- `T > 1` (multi-token prefill) → the pre-existing `gatedDeltaOps` per-step
  recurrence (already upstream, correct for any `Dk`; slower but no fused
  single-dispatch T-loop);
- any `Dk % 32 != 0` → `gatedDeltaOps` (upstream guard retained).

No other upstream code is modified. Remove patch `0001` and re-sync to return
to pristine upstream behavior.

## Why patch 0002 exists (Build229 prefill crash repair)

Build229 (physical iPad, TestFlight) reported an `EXC_BREAKPOINT` abort
symbolicated to `getItemND` via the `Qwen35GatedDeltaNet.generalConv`
conv-state tail slice, ~54s into a 5,314-token batch-8 chunked prefill under
~280MB memory headroom (MLX active 2.21 GiB vs 2.47 GiB available). The
windowed prefill in `Libraries/MLXLLM/LLMModel.swift` never checked the MLX
error handler between windows: an MLX error (e.g. a transient Metal
command-buffer failure under memory pressure) was captured by the task-local
`withError` box while graph construction continued on the degenerate 0-dim
arrays the C API returns after an error, and the next three-slice subscript
on such an array traps in `getItemND` (`starts[axis]` on an empty array).
Host reproduction: inject an MLX error, keep building graphs, slice a
degenerate array → `Index out of range` at `MLXArray+Indexing.swift:695`.

Patch 0002 runs the windowed prefill under a scoped `MLX.withError` and
checks the box between every window and once after the final `eval(cache)`,
so the first MLX error throws (as `MLXError.caught`, original message
preserved) instead of aborting the process. Callers already map that throw to
a retryable `decodeFailed`. Successful prefills are unchanged — a clean box
is a no-op check. Tests: `LLMModelPrepareFailFastTests` (throw, not trap,
including a final-flush-only error) and `Qwen35GDNPrefillShapeTests`
(production conv/recurrent state shapes at S = 8/48/96 bf16 and chunk
boundaries, proving the indexing path itself is correct).

## Contents and checksums (SHA-256)

`FLOE_SHA256SUMS` covers every vendored source, test and patch file (510 files)
and can be checked from a clean repository clone without an upstream SwiftPM
checkout. The critical input/output hashes are also recorded below.

| File | SHA-256 |
| --- | --- |
| pristine `Libraries/MLXLMCommon/GatedDelta.swift` (upstream d5d8b29) | `2e81ef2359b9d28fe850a04b1a45e8881144ebca84276a2d5aeff77f7c683b49` |
| vendored `Libraries/MLXLMCommon/GatedDelta.swift` (patched) | `b882b63af7cb8259d4759a726768dce14753af7d5a5f539a92e0d79aa1208eaf` |
| `Tests/MLXLMTests/GatedDeltaPrefillRouteTests.swift` (new) | `cb720698b962e85fa666dc9ea6a4380e1fc4214506c42803ec2d8c57f5f0d218` |
| `patches/0001-gdn-prefill-t1-ops-route.patch` | `a634c9b0e7b54a1fd5d6e6934e60495361a465e29a9bea42f891bb3198dcafd2` |
| pristine `Libraries/MLXLLM/LLMModel.swift` (upstream d5d8b29) | `e783dbc314ec0e95d25e755e9c1ec907f848b0069155a59a4e4d237cba4da702` |
| vendored `Libraries/MLXLLM/LLMModel.swift` (patched) | `f5d950df6ece3da721916fe9d2c883f592fc78d49e6226ffba682d55468e5095` |
| `Tests/MLXLMTests/LLMModelPrepareFailFastTests.swift` (new) | `7cf47025c97c62c6a2c031fcca730f7abff25beb352126eda20cd77168b69910` |
| `Tests/MLXLMTests/Qwen35GDNPrefillShapeTests.swift` (new) | `9c97456ac75c9431a10050c3640f5c2b8834e58770d501d73a60a8d784cab24b` |
| `patches/0002-llmmodel-prefill-window-error-fail-fast.patch` | `5764d9468e5bc672c46141ac37df718aac8b0b9e02da6c8d4e0318f9885b4812` |

`tests` additions (in the upstream `MLXLMTests` target) do not modify existing
upstream tests:

- `testSingleTokenDecodeRoutesToFusedKernel` — `T == 1`, `Dk = 32`: public
  result is bitwise identical to a direct `gatedDeltaKernel` call.
- `testMultiTokenPrefillRoutesToOpsFallback` — `T = 8`, `Dk = 32`: public
  result is bitwise identical to a direct `gatedDeltaOps` call.
- `testOpsPrefillMatchesStepwiseFusedDecode` — ops prefill numerically matches
  per-token fused decode (bf16-scale tolerance) with fp32 state continuity.
- `testMultiTokenPrefillChunksMatchSingleCall` — chunk-boundary regression for
  the re-routed prefill path.
- `testPrepareCompletesWithoutError` / `testPrepareThrowsOnPoisonedWindow` /
  `testPrepareThrowsOnFinalFlushError` — Build229 fail-fast repair: a
  mid-prefill MLX error throws with its original message instead of
  continuing on degenerate arrays into a `getItemND` trap.
- `testGeneralConvStateShapesAtProductionWindowSizes` /
  `testForwardStateShapesAtProductionWindowSizes` /
  `testCacheRoundTripAtProductionWindowSizes` /
  `testGeneralConvChunkBoundaryIsBitwise` /
  `testForwardChunkBoundaryTracksWholePrompt` — Qwen3.8-4B GDN prefill state
  shapes at S = 8/48/96 bf16 and chunk-boundary equivalence; pins the
  conv-state tail slice as shape-correct (the device fault was
  environmental, not an indexing defect).

## Regeneration / re-sync

From the repository root, with the pinned checkout already present:

```bash
SRC="FloeAgent/.build/out/checkouts/mlx-swift-lm"
test "$(git -C "$SRC" rev-parse HEAD)" = d5d8b290e601ac1bf11f24635f8f811a83b98bf8

rsync -a --delete \
  --exclude='.git' --exclude='.build' --exclude='DerivedData' --exclude='.DS_Store' \
  --exclude='patches' --exclude='FLOE_VENDOR.md' --exclude='floe_vendor_check.sh' --exclude='FLOE_SHA256SUMS' \
  "$SRC/" FloeAgent/ThirdParty/MLXSwiftLM/
chmod -R u+w FloeAgent/ThirdParty/MLXSwiftLM

# apply Floe patches (in lexical order)
for p in FloeAgent/ThirdParty/MLXSwiftLM/patches/*.patch; do
  patch -d FloeAgent/ThirdParty/MLXSwiftLM -p1 < "$p"
done
python3 - <<'PY'
from pathlib import Path
import hashlib
root = Path('FloeAgent/ThirdParty/MLXSwiftLM')
skip = {'FLOE_SHA256SUMS', 'FLOE_VENDOR.md', 'floe_vendor_check.sh'}
files = sorted(p for p in root.rglob('*') if p.is_file()
               and p.relative_to(root).as_posix() not in skip)
(root / 'FLOE_SHA256SUMS').write_text(''.join(
    f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root).as_posix()}\n'
    for p in files))
PY
```

Read-only audit: `bash FloeAgent/ThirdParty/MLXSwiftLM/floe_vendor_check.sh`.
It always checks the complete vendored tree against `FLOE_SHA256SUMS`; when
the pinned upstream checkout is present, it also verifies its revision and
replays the patch series byte-for-byte.

## Verification status

- Copy is byte-identical to the pinned checkout except the files above plus
  the `patches/` directory (`diff -rq` clean).
- Patch series applies cleanly to pristine `d5d8b29` and reproduces the
  vendored tree exactly (round-trip checked for both patches).
- `swiftc -parse` passes for both changed/added Swift files.
- Patch 0002 tests were additionally executed on a macOS host (SwiftPM,
  trait `FoundationModelsIntegration` disabled): all 8 tests in
  `LLMModelPrepareFailFastTests` and `Qwen35GDNPrefillShapeTests` pass, and
  the pre-existing `GatedDeltaPrefillRouteTests`, `GatedDeltaTests`,
  `Qwen35CompiledDecodeLifecycleTests` and `Qwen35GDNDecodeBitwiseTests`
  still pass (15 tests total). The full `MLXLMTests` suite is owned by cloud
  CI; device/TestFlight acceptance remains with the user.

## App wiring status

- Landed (main thread; observed read-only): `FloeAgent/Package.swift` now
  depends on `.package(name: "mlx-swift-lm", path: "ThirdParty/MLXSwiftLM")`
  and its target products reference `package: "mlx-swift-lm"`. The remote
  `mlx-swift-lm` pin is no longer used.
- Remaining: resolve/build in cloud CI, then qualify Qwen3.5/Qwen3-Next
  prefill with T > 1 prompts and single-token decode on device/TestFlight.
- Expected: prefill runs the ops recurrence (slower, crash-free if the
  hypothesis holds); decode keeps the fused kernel. If a prefill crash
  persists, the fused GDN path is exonerated and the next suspect is the
  conv / mask path in `Qwen35.swift`, not `GatedDelta.swift`.

## 中文说明

本目录是 `mlx-swift-lm` 在仓库内的本地 Swift package 副本，固定于提交
`d5d8b290e601ac1bf11f24635f8f811a83b98bf8`，保留上游 MIT 许可，不含 `.git`
与构建产物，可直接通过 `.package(path:)` 引用。

Floe 补丁 `patches/0001-gdn-prefill-t1-ops-route.patch` 只改
`gatedDeltaUpdate` 的路由：多 token 预填充（`T > 1`）改走已有的
`gatedDeltaOps`；单 token decode（`T == 1`）保留 Metal fused 内核；
`Dk % 32` 守卫保留。Build227 的异步崩溃仍是怀疑（尚未在真机证实），
因此本补丁按“预填充安全路径”处理，并未改动其他上游代码。

Floe 补丁 `patches/0002-llmmodel-prefill-window-error-fail-fast.patch` 修复
Build229 真机崩溃：窗口化预填充此前从不检查 MLX 错误，一旦底层出现 MLX
错误（如内存压力下的 Metal command-buffer 失败），后续图构建会在 C API
返回的退化 0 维数组上继续，最终在 `getItemND` 切片处触发 Swift
index-out-of-range 陷阱导致进程 abort。该补丁在每个预填充窗口之间以及
最后 `eval(cache)` 后检查一次错误框，首个 MLX 错误会以
`MLXError.caught`（保留原始信息）抛出，由上层映射为可重试的
`decodeFailed`，而不是崩溃。成功路径行为不变。

重新生成方式见上节命令；只读审计脚本为 `floe_vendor_check.sh`。
本地仅做了 `swiftc -parse` 语法检查和补丁回放校验，编译与真机验收由主线程
接线后的云端 App 构建与用户设备验证负责。主线程已在 `FloeAgent/Package.swift`
中以 `.package(name: "mlx-swift-lm", path: "ThirdParty/MLXSwiftLM")` 完成接线。
