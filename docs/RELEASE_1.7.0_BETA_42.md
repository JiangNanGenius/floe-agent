# Floe Agent 1.7.0 (185) — beta.42 candidate

**Cloud qualification in progress; not uploaded.**

Tag `v1.7.0-beta.42`, source `42ecc4527fdbeb171dd0aed1d0776375770f1572`.
[Release run 35292395886](https://github.com/JiangNanGenius/floe-agent/actions/runs/35292395886).

This candidate completes durable IDE GitHub Actions job ownership: submission
intent is persisted before dispatch; relaunch and foreground entry reload jobs
and resume bounded polling. An unknown dispatch response is reconciled instead
of submitted again; cancellation waits for the remote terminal result. Closing
the App does not stop GitHub Actions. iOS may suspend local polling while the App
is inactive; foreground recovery reads the current remote state.

The previous build 184 compiled on both SDK lines, but both full-App regression
runs failed the same Lua test (203/204 passed). Its unsigned device recovery
archive is preserved; signing and upload were skipped. The WASI environment
contract now accepts realistic export sets with bounded count/bytes and precise,
content-free diagnostics. Seven actual Swift Testing cases passed against the
production runtime, including real Lua and WASM environment reads.
[Focused evidence](qualification/build185-release/lua-environment.json).

The HTTP preview server now reads complete, bounded request headers; engineering
covers await the viewer bridge with cancellation and a real deadline. The
follow-up NativeNotes component run
[35290599088](https://github.com/JiangNanGenius/floe-agent/actions/runs/35290599088)
on source `f4435d2271d3036d263bea49e7d032688af2bc53` passed both iPad and iPhone.
These are component-host results, not final full-App UI acceptance.

## Observed cloud results

Both SDK lines compiled the App. Both full-App regression summaries now report
**204/204 passed, zero failed/skipped/expected failures**, including the repaired
Lua case and23 IDE cloud-job cases. The SDK27 module stages also passed:
1,254 main-suite tests, two JavaScript groups of12,92 platform cases and42 Notes
cases; all7 new WASI cases actually executed. These are separate stage counts,
not a deduplicated product-wide total.

- [Development App regression](qualification/build185-release/sdk27-app-regression.json)
- [Accepted-SDK App regression](qualification/build185-release/accepted-app-regression.json)
- [Module execution](qualification/build185-release/cloud-modules.json)
- [Verified device recovery](qualification/build185-release/device-recovery.json)

The unsigned device recovery archive is retained locally and in CI. Both SDK
Notes UI legs, signing/upload and Apple availability remain pending here.

## 本轮内容

- IDE 云端构建由 App 保存并恢复任务，重开后主动回读与轮询；不依赖模型反复 sleep。
- 云端取消须回读确认；响应不明不会盲目重复提交。
- 修复 Lua 被旧环境变量上限拦截的问题，保留参数、大小和输出的明确边界。
- 修复预览 HTTP 分段请求与 CAD 封面准备时序，继续验证 Word、Excel、PPT、DXF、DWG 的真实内容缩略图。
- 复用已通过的定向检查，完整 App 构建、双 SDK 回归和双端界面验收仍在云端进行。

## Delivery boundaries

Build 178 remains the last confirmed internal TestFlight release until the new
build is uploaded, processed and available to the existing internal Floe QA group.
Public Beta material remains a draft for user review, without a developer-funded
API key. Physical iPad local-model chat stability and Pencil/Office interaction
remain separate acceptance. Local PHP, full RDP App integration and the entire
native package/model catalogs are not claimed as delivered in this candidate.
