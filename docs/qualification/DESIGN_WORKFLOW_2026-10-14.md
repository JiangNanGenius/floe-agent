# Design workflow qualification / 设计工作流验证 — 2026-10-14

Status: **implemented and locally qualified; unreleased**. Versions remain 1.7.30 / Build 271. No release tag, upload, TestFlight submission or automation was created.

状态：**已实现并完成本地相关验证，未发版**。版本仍为 1.7.30 / Build 271；未创建发布标签、上传、送审或定时跟进。

## Source and toolchain / 源码与工具链

- Branch: `codex/design-workflows-20261013`; base: `734e97f5eec9792b262932dc2f33ba6e725db189`.
- Local Xcode 27.0 (27A266a), iOS 27 Simulator SDK; full App `build-for-testing` succeeded.
- Exact-source simulator artifact and SHA-256 manifest retained privately. The root dependency lock and application versions are unchanged.
- 本地 Xcode 27 完整 App 编译成功；保留精确源码模拟器产物和哈希清单。根依赖锁与版本号未变。

## Changed behavior / 本轮行为

- Natural-language creative entry; artifact preview alongside the original conversation. Brief, specification and work-mode controls are optional inspector content.
- No automatic design-page popup for ordinary questions, keywords or attachments alone. Pending-candidate decisions use one primary action and a compact menu; the current artifact has no resident decision strip.
- Root full-window presentation, reserved format badge strip, trailing inspector, retained preview and conversation state, compact preview/chat switch.
- Model-directed creative destinations and bounded `canvas.startOrdinaryTask` handoff reuse existing workspace, task, authority and launch services. Canvas receives no Linux execution permissions.
- Original revision protection, trusted adoption, crash/replay reconciliation, bounded outputs and runtime recovery use the existing services.
- 创意入口以自然语言开始；成果预览与原会话并列。简报、规范和工作模式收进按需详情，普通问答不自动弹出设计页。
- 候选采用为一个主按钮加菜单，当前成果不常驻决策条；全窗预览、右侧详情、窄屏预览／聊天切换保留原状态。
- 模型按任务选择目标；画布素材交接绑定运行、文档、修订及明确素材，复用原有任务和权限服务，不给画布开放 Linux 执行。

## Evidence and limits / 证据与边界

- Latest focused App suites: **29 tests passed** (creative destination, fixture ownership, entry policy, preview resource limits).
- iPad UI: **2 design-page tests + 1 creative-entry test passed**. Primary visual review confirmed the badge does not overlap page content, details appear on the right, fullscreen fills the available window, and the original unsent draft survives exit.
- Primary iPhone 17 Pro simulator review used the existing device serially after shutting down the iPad. The actual design page opens and switches between preview and the original conversation.
- 最新定向 App 测试 **29 项通过**；iPad 设计页 **2 项**及创意入口 **1 项** UI 测试通过。主协调实际复核 iPad 全窗、右侧详情和草稿保留，并串行复用现有 iPhone 验证窄屏预览／聊天切换。
- An exploratory full App run (778 tests / 91 suites) was **not green**. Independent isolation retained baseline failures in `CapabilityExecutionRouter`, `SourceControlRootIdentity` and `LinuxPortForwardCenter`; their source/tests are unchanged in this round. Office deadline cases passed in isolation. A skill-guide reference error was repaired and its affected suites passed. This record does not claim a clean full matrix.
- 探索性全 App 测试并非全绿；保留未改动的路由、源码根身份和端口中心基线失败。Office 时限用例隔离通过，Skill 指南引用错误已修复并回归。本记录不宣称整套测试全过。
- Physical-device smoothness, a live Linux VM workflow, and a real-provider Canvas-to-task GUI loop were **not verified in this final pass**. Earlier real-provider owner/adoption validation is separate evidence and does not replace those checks.
- 最终复核未验证实机流畅度、真实 Linux 虚拟机工作流或真实供应商的画布交接 GUI 闭环；此前真实模型采用验证为独立证据，不能替代这些项目。
