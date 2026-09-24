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
| Local patches | `patches/0001-gdn-prefill-t1-ops-route.patch` (Floe) |

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

## Contents and checksums (SHA-256)

| File | SHA-256 |
| --- | --- |
| pristine `Libraries/MLXLMCommon/GatedDelta.swift` (upstream d5d8b29) | `2e81ef2359b9d28fe850a04b1a45e8881144ebca84276a2d5aeff77f7c683b49` |
| vendored `Libraries/MLXLMCommon/GatedDelta.swift` (patched) | `b882b63af7cb8259d4759a726768dce14753af7d5a5f539a92e0d79aa1208eaf` |
| `Tests/MLXLMTests/GatedDeltaPrefillRouteTests.swift` (new) | `cb720698b962e85fa666dc9ea6a4380e1fc4214506c42803ec2d8c57f5f0d218` |
| `patches/0001-gdn-prefill-t1-ops-route.patch` | `a634c9b0e7b54a1fd5d6e6934e60495361a465e29a9bea42f891bb3198dcafd2` |

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

## Regeneration / re-sync

From the repository root, with the pinned checkout already present:

```bash
SRC="FloeAgent/.build/out/checkouts/mlx-swift-lm"
test "$(git -C "$SRC" rev-parse HEAD)" = d5d8b290e601ac1bf11f24635f8f811a83b98bf8

rsync -a --delete \
  --exclude='.git' --exclude='.build' --exclude='DerivedData' --exclude='.DS_Store' \
  --exclude='patches' --exclude='FLOE_VENDOR.md' --exclude='floe_vendor_check.sh' \
  "$SRC/" FloeAgent/ThirdParty/MLXSwiftLM/
chmod -R u+w FloeAgent/ThirdParty/MLXSwiftLM

# apply Floe patches (in lexical order)
for p in FloeAgent/ThirdParty/MLXSwiftLM/patches/*.patch; do
  patch -d FloeAgent/ThirdParty/MLXSwiftLM -p1 < "$p"
done
```

Read-only audit: `bash FloeAgent/ThirdParty/MLXSwiftLM/floe_vendor_check.sh`
(verifies checkout SHA, file hashes, and that the patch series reproduces the
vendored files from pristine source).

## Verification status

- Copy is byte-identical to the pinned checkout except the two files above plus
  the `patches/` directory (`diff -rq` clean).
- Patch series applies cleanly to pristine `d5d8b29` and reproduces the
  vendored tree exactly (round-trip checked).
- `swiftc -parse` passes for both changed/added Swift files.
- **Not** built or executed locally (disk budget); the cloud App build owns
  compilation, and device/TestFlight acceptance remains with the user.

## Remaining App wiring (main thread)

1. In `FloeAgent/Package.swift`, replace the remote `mlx-swift-lm` dependency
   with `.package(path: "ThirdParty/MLXSwiftLM")` (keep the product names
   `MLXLLM` / `MLXVLM` / `MLXLMCommon` unchanged).
2. Re-resolve `FloeAgent/Package.resolved` and run the cloud App build; then
   qualify Qwen3.5/Qwen3-Next prefill with T > 1 prompts and single-token
   decode.
3. Expected: prefill now runs the ops recurrence (slower, crash-free if the
   hypothesis holds); decode keeps the fused kernel. If the crash persists on
   prefill, the fused path is exonerated and the next suspect is the conv /
   mask path in `Qwen35.swift`, not `GatedDelta.swift`.

## 中文说明

本目录是 `mlx-swift-lm` 在仓库内的本地 Swift package 副本，固定于提交
`d5d8b290e601ac1bf11f24635f8f811a83b98bf8`，保留上游 MIT 许可，不含 `.git`
与构建产物，可直接通过 `.package(path:)` 引用。

Floe 补丁 `patches/0001-gdn-prefill-t1-ops-route.patch` 只改
`gatedDeltaUpdate` 的路由：多 token 预填充（`T > 1`）改走已有的
`gatedDeltaOps`；单 token decode（`T == 1`）保留 Metal fused 内核；
`Dk % 32` 守卫保留。Build227 的异步崩溃仍是怀疑（尚未在真机证实），
因此本补丁按“预填充安全路径”处理，并未改动其他上游代码。

重新生成方式见上节命令；只读审计脚本为 `floe_vendor_check.sh`。
本地仅做了 `swiftc -parse` 语法检查和补丁回放校验，编译与真机验收由主线程
接线后的云端 App 构建与用户设备验证负责。
