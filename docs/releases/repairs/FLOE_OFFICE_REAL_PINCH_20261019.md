# Office 真实双指缩放诊断 / Actual UIKit pinch diagnosis

日期 / Date: 2026-10-19。源码 / Source: `faa67d21fc26858f05440c50e9e728e3a0b400b3`。

## 结果 / Result

已定位可信双指同时起始时的初始化缺口；尚未交付缩放修复。诊断仅在 Debug 与显式启动参数下运行，不改变手势路由。/ Trusted simultaneous two-finger starts reach the canvas but fail to initialize the gesture. This is diagnosis, not a delivered zoom fix. The explicit Debug-only probe does not change routing.

| 横屏对照 / Landscape case | 画笔关 / Drawing off | 画笔开 / Drawing on |
| --- | --- | --- |
| 首个 touchstart / First touchstart | touches=2, changed=2, trusted=true | touches=2, changed=2, trusted=true |
| 后续 touchmove / Subsequent moves | 9 | 10 |
| 目标 / Target | document-canvas | document-canvas |
| 取消／丢弃记录 / Cancellation or dropped records | 0 / 0 | 0 / 0 |
| 手势起点、区域 / Start, section | 未初始化 / unset | 未初始化 / unset |
| 移动期间 multiTouch / Multitouch during moves | 1 | 1 |
| 引擎缩放 / Engine zoom | 10 → 10 | 10 → 10 |
| 文档标题可见宽度比 / Visible title width ratio | 0.9286 | 1.0000 |

两组视口均为 1133×640 CSS 像素、dpiScale=2；关闭画笔前存在高度为零的键盘 AX 元素，手势后消失，开启画笔时无键盘。两组触摸均到达画布，未发生取消，不能归因为单纯的横屏目标未命中。/ Both viewports were 1133×640 CSS pixels at dpiScale 2. Drawing-off initially exposed a zero-height keyboard AX element; drawing-on exposed none. Both gestures reached the canvas without cancellation, ruling out a complete landscape targeting miss for these runs.

固定前端的 `CanvasSectionContainer.onTouchStart` 仅在单指分支建立 `positionOnMouseDown` 和 `sectionOnMouseDown`，双指分支依赖已有区域；随后 `onTouchMove` 在起点为空时返回。可信事件记录与这一断点一致。后续修复需保留单指与先一指后两指路径，并验收结束／取消状态恢复。/ The pinned frontend initializes the start and section only for a one-touch start; the two-touch branch relies on an existing section, and move handling returns when the start is null. Trusted-event evidence matches this gap. The fix must retain single-touch and sequential two-touch behavior and clean termination/cancellation.

## 已执行检查 / Executed checks

- Xcode 27.0 (`27A266a`), iOS Simulator SDK 27.0, arm64，6 编译任务。`xcodebuild build-for-testing -project FloeAgent/FloeAgent.xcodeproj -scheme FloeAgent -destination 'generic/platform=iOS Simulator'`：成功，包含新诊断文件的实际编译。/ Full App and UI runner compilation passed.
- 同一已有 iPad 模拟器，串行 `test-without-building`，关闭并行测试：`OfficePinchDiagnosticsUITests/testRealPinchDrawingOffLandscape`、`testRealPinchDrawingOnLandscape`，2 项通过，零跳过。/ Two opt-in diagnostic tests passed with no skips.
- 原有工具栏验收的 1.08 可见放大阈值保持不变；本次诊断只验证记录契约，不断言功能已修复。/ The original 1.08 visible-growth acceptance threshold is unchanged; diagnostics validate observation, not zoom success.
- 精确提取的观测脚本 34 项检查通过：首个起始不被移动事件覆盖、结构化有界 JSON、代次隔离与旧监听清理。/ 34 checks passed against the extracted observation scripts.
- 运行回执、原始截图、前后 JSON、键盘／视口和 xcresult 均已保留。模拟器运行结束后已关机，未重置或删除数据。/ Raw evidence is retained; the simulator is shut down with data preserved.

后续 / Next: 最小生产修复 → 重建实际前端资源并校验来源 → 原可见缩放、画笔保持、无手指误写与保存重开验收 → 新编号内测。真实 Pencil、手掌与锁屏交互仍须设备反馈。/ Minimal production fix, verified resource integration, original zoom and drawing/save acceptance, then a new internal beta. Physical Pencil and device behavior remain separate acceptance.

## 源码修复进展 / Source repair progress

已增加双指同时起始的初始化补丁，并修复取消后遗留的多指状态；新手势会丢弃上一手势结束后保留的旧区域，而同一次先后落指保持原区域。实际源码提取的 15 项行为检查通过，包含旧写法失败的连续手势对照。补丁准备的 16 项临时 Git 行为测试通过；设备与模拟器构建入口现复用同一准备流程，设备入口通过 shell 语法检查。/ The patch initializes batched starts, clears cancellation state and distinguishes a fresh gesture from a sequential second finger. Fifteen source-behavior checks and sixteen preparation tests passed; both build entrypoints now share preparation. The device entrypoint passed shell syntax checking.

补丁尚未进入新生成的 Office 资源或安装包。新的补丁锁文件需要与重建组件的来源证明及资源摘要一起固定；现有组件证明保持原值，不能用旧包宣称已携带新修复。/ The patch is not yet included in regenerated Office resources or an installable build. Its new lock identity must be pinned with rebuilt component provenance and resource hashes; existing component evidence remains unchanged.
