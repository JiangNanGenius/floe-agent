# 1.7.22 (263) — Workspace experience

Candidate under validation. This document is not evidence of upload, TestFlight availability or external approval. See [current status](../../CURRENT_STATUS.md).

## English

- Browser controls use larger touch targets and a real, editable URL. Full screen retains the same page and browser session.
- User takeover blocks agent browser actions while allowing other task work. Returning control produces a durable notification for the original task. Finished tasks require an explicit Continue action; delivery failures remain retryable.
- Recent conversation messages appear before auxiliary data. Streaming text reuses the historical timeline; large expanded tool outputs load in bounded sections.
- Concurrent starts of the same Linux environment share startup. Existing CPU/RAM and the four-core total / three-core per guest limits are retained. Stopping asks about affected terminals and services and checks the resulting VM state.
- Local and SSH terminals gain common keyboard and display controls. Terminal output uses byte positions across bounded-buffer rollover, and full-screen presentation retains the terminal renderer.
- Shared port management supports editing rules and local/LAN scope. The `linux.port` tool operates on the task's environment and distinguishes saved rules from actual listeners. Port forwarding does not start a web server.

## 简体中文

本候选尚在验证，本文不代表上传、内部可安装或公测审核通过。各阶段以[版本状态](../../CURRENT_STATUS.md)为准。

- 浏览器采用更大的触控区域和真实可编辑地址，全屏保留原页面与会话。
- 用户接管只限制模型的浏览器操作，其他任务工作可继续。交还时向原任务持久投递通知；已结束任务需要明确点击“继续任务”，通知失败可重试。
- 会话先显示最近消息，再加载辅助数据。流式输出复用历史时间线，大工具输出分段展开。
- 同环境并发启动共享一次启动过程，保留已有 CPU／内存配置及总四核、单机最多三核限制。停止前提示受影响的终端和服务，并核对实际停止状态。
- 本地与 SSH 终端提供统一快捷键和显示控制。输出按字节位置增量显示，全屏保留终端渲染器。
- 各入口共用端口管理，支持编辑规则、本机／局域网范围。`linux.port` 沿用任务环境和权限，区分保存规则与实际监听；转发本身不启动网页服务。

## Verification

Local full-device validation compilation passed. Component tests passed (38 XCTest and 19 Swift Testing cases), followed by 45 focused iPad Simulator cases covering browser protocol/handoff, port edits, terminal byte rendering and history projection/pagination. Actual iPad Simulator interaction checked browser address editing, full-screen transitions, handoff persistence and terminal full screen. Final immutable-source device compilation passed for `0a847da5cf14fe5ee259056f0ac994b9dd9b9f4e` (Xcode 27A266a, iphoneos27.0). App/dSYM UUIDs match. Eleven final browser handoff/recovery cases passed, and iPhone compact address/fullscreen controls were inspected. Distribution remains pending.

Synthetic 1k/10k histories kept the first page at 20 messages and paged to 50 without duplicates. Measured model loads were about 30/21 ms; these measurements do not establish a 40% improvement in full first-screen rendering against the old version. Sampled App footprints were 160/221 MB after constructing the fixtures; no peak-memory nonregression claim is made. Local VM networking and real SSH were not exercised in this simulator. Physical-device smoothness and network reachability require separate observation. No full cloud matrix or external approval is claimed.
