# Floe Agent 1.4.77 (Build 108) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

This candidate fixes the local completion stage of Infinite Canvas generation and makes Picture in Picture an explicit, optional task surface. Build 108 is available only after CI passes with a non-zero verified test count, App Store Connect reports a valid processed build, and the internal Floe QA group can see it.

## Focus areas

- **Canvas completion rebase:** an image or video provider can finish successfully after the canvas revision has advanced. Floe now reads the latest project, verifies the active generation-attempt ID, and applies the already-produced result with a bounded local compare-and-save rebase. A save conflict retries only the local commit; it never calls the provider again.
- **Stale-attempt protection:** an older completion or failure cannot overwrite a newer generation attempt. Unrelated viewport or node changes made while the provider is running are preserved, and an asset-reference bookkeeping error does not relabel a successfully attached result as a generation failure.
- **Explicit Picture in Picture:** preparing progress content does not show an in-app floating or inline preview and foreground, inactive, or background scene transitions do not start PiP. Floe requests PiP start or retry only after the user presses the explicit control in an active task or canvas toolbar; the same control can stop an active PiP window.
- **Independent ordinary background mode:** standard background execution continues through its normal continued-processing, completion-lease, checkpoint, and resume path. It does not depend on PiP and must not create a floating window.
- **Executed-test CI gate:** CI and release verification read the focused Canvas and PiP suite's actual counts from the `.xcresult`. The gate requires at least 14 executed tests, zero failures, and `passed == total`; a missing count or a zero-test success is a release failure.
- **Regression continuity:** Plan mode must remain non-mutating until explicit acceptance, VNC input still requires an active connection, explicit Canvas source edges remain authoritative, and long reasoning text must not become a phantom tool call.

## Physical-iPad acceptance boundary

Simulator builds and automated state-contract tests do not prove that AVKit presents and retains the real system PiP window on iPadOS. Before calling Build 108 accepted, use a physical iPad to run a task and a Canvas task, confirm that preparation alone creates no foreground floating preview, start PiP from each explicit toolbar button, leave and return to Floe, stop and retry PiP, and confirm progress remains visible without duplicate windows. Separately verify an ordinary background task with PiP disabled; it must continue through the standard background path without showing PiP. Record the device model, iPadOS version, exact transitions, and timestamps.

## 简体中文

本候选版修复无限画布生成完成后的本地提交阶段，并把画中画改成明确、可选的任务界面。只有 CI 通过且确认实际执行了非零测试、App Store Connect 显示构建处理有效，并且内部 Floe QA 测试组可见 Build 108 后，才算真正可用。

- **画布完成提交重基：**图片或视频供应商成功返回时，画布 revision 可能已经前进。Floe 现在重新读取最新项目、核对当前生成 attempt ID，并通过有界的本地比较保存重基提交已经生成的结果。保存冲突只重试本地提交，绝不会再次调用供应商。
- **旧 attempt 防覆盖：**较早一次生成的成功或失败结果不能覆盖更新的生成尝试；供应商运行期间发生的视口或节点修改会保留。素材引用计数失败只作为可诊断的一致性问题处理，不能把已经成功挂接的产物反向标成生成失败。
- **显式画中画：**准备任务进度内容不会在 App 前台显示自定义悬浮或内嵌预览，前台、inactive 或进入后台等场景切换也不会自动启动画中画。只有用户点击运行中任务或画布工具栏中的明确按钮，Floe 才会请求启动或重试系统画中画；画中画已启动时，同一按钮可用于关闭。
- **普通后台独立：**普通后台任务继续使用原有的系统持续处理、短时完成窗口、检查点和恢复链路，不依赖画中画，也不能创建悬浮窗口。
- **CI 实际测试数门禁：**CI 与发布验证从 `.xcresult` 读取画布与画中画定向套件的实际测试数；必须至少执行 14 条、失败数为 0 且通过数等于总数。缺失计数或“零测试成功”都必须阻止发布。
- **既有行为回归：**计划模式在明确接受前仍不得执行有副作用操作；VNC 输入仍要求有效连接；画布上下文仍只沿显式来源连线传播；长思考文本不能被误判成幽灵工具调用。

## 实体 iPad 验收边界

模拟器构建和自动化状态测试不能证明 AVKit 在真实 iPadOS 上确实显示并保持系统画中画。宣称 Build 108 验收通过前，必须在实体 iPad 分别运行普通任务和画布任务，确认仅准备内容不会在前台弹出悬浮预览；分别点击工具栏按钮启动画中画，离开并返回 Floe，验证关闭与重试，并确认进度持续可见且不会出现重复窗口。还要单独关闭画中画运行普通后台任务，确认它沿普通后台链路继续且不会显示画中画。请记录设备型号、iPadOS 版本、准确切换步骤和时间。

反馈请注明 Build 108、设备和系统版本、模型与供应商、画布/任务 ID、准确操作与时间。不要上传 API Key、Token、密码、SSH 私钥、证书或描述文件。
