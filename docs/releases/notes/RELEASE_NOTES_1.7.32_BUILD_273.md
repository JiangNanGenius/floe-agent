# Floe 1.7.32 (273) — Temporary chat, CAD and shared Linux execution

Internal Floe QA candidate. App qualification, upload, Apple processing and availability are recorded separately.

Delivery record (2026-10-15): internal Floe QA only. Frozen source `29937dc025267bacd89434cc092b3906c99b93ee` (tag `v1.7.32`); local Xcode 27.0 (27A266a) Release archive with `CODE_SIGNING_ALLOWED=NO`; transport sha256 `0fc1e741…`; signed and uploaded through the repository local-artifact workflow without rebuilding the App (run `38715266826`), then independently read back from Apple: build `f0b719ad-c418-4c50-bba0-48ab45aa4147`, `VALID`, unexpired, `IN_BETA_TESTING` in the existing internal Floe QA group. The qualification limits below still stand.

交付记录（2026-10-15，仅内部 Floe QA）：冻结源码 `29937dc025267bacd89434cc092b3906c99b93ee`（标签 `v1.7.32`），本地 Xcode 27.0（27A266a）Release 归档（`CODE_SIGNING_ALLOWED=NO`），传输包 sha256 `0fc1e741…`；通过仓库的“本地制品”流程签名并上传，应用未重新构建（运行 `38715266826`）；随后独立读取 Apple 状态：构建 `f0b719ad-c418-4c50-bba0-48ab45aa4147`，`VALID`、未过期、现有内部 Floe QA 组 `IN_BETA_TESTING`。下方验证边界仍然有效。

## 简体中文

- 临时会话复用正常聊天界面和语音输入，以顶部精简菜单管理；按实际配置与授权提供只读工具。语音识别沿用正常设置，所选服务可能在线处理。切后台或锁屏保留会话，真正离开则取消并销毁临时内容；保留为正式会话不重复发送请求。
- 子助手可自行搜索工具、读取 Skill 并加载所需能力，继承主任务实际权限，仅禁止继续委派。修复工具目录过大导致无法启动的问题，不再一次塞入全部工具定义。
- 完善同一 Linux 环境中父任务与子助手的并发执行、工作目录与环境变量、输出及取消归属。交互终端按客户端识别会话，避免同名工具调用混淆记录或误操作其他助手的终端。
- 修复虚拟机启停与新命令交错、输出压力下控制帧处理，以及取消过程中意外重新启动模型请求的问题。
- 修复输入框测量触发布局递归的路径，并调整系统通知回调桥接。
- Linux 解释器的发布构建采用吞吐优化配置。原生来宾对照结果与实机性能分开记录，不承诺达到其他模拟器的测试成绩。
- CAD 编辑接入任务授权，普通已授权操作无需逐项到工作台签发确认；提案不再强制打断连续任务。保留修订、防误写与重试去重校验，补齐中文名称和拉伸参数示例。画布入口统一显示“3D 工作台”。
- 普通文档与媒体编辑减少逐项确认。本地 Linux 虚拟机的例行命令减少重复审批；代码库写入与远端风险操作仍遵循任务审批模式。执行环境与写入目标由运行时核对。

验证边界：模块、完整 App、模拟器与实机证据分别记录。真实设备流畅度、长时间使用和性能仍需对应设备复测。本轮仅内部 Floe QA，不提交外部公测、生产版本或内容包，不恢复定时任务。

## English

- Temporary chat reuses the normal conversation surface and voice input, with a compact header menu and configured, authorized read-only tools. Speech recognition follows the usual settings and may use an online service. Backgrounding or locking preserves the session; leaving it cancels work and destroys temporary content. Keeping it as a saved chat does not resend requests.
- Subagents independently discover tools, read Skills and load capabilities within the main task's actual permissions; further delegation remains disabled. Large tool catalogs no longer have to fit into the initial schema payload.
- Improves parent/subagent concurrency in one Linux environment, including working directories, environment variables, output ownership and cancellation. Client-owned terminal sessions prevent identical tool-call identifiers from mixing records or accidentally operating another assistant's terminal.
- Repairs lifecycle/new-command races, control-frame handling under output pressure, and a cancellation race that could open a new model request.
- Removes the composer measurement path that could recurse through layout, and updates system-notification callback bridging.
- Uses throughput-oriented optimization for the release Linux interpreter. Native guest comparisons are reported separately from device performance; no parity with other emulators is claimed.
- CAD editing uses task authorization so ordinary authorized operations do not require a separate workbench grant for every edit. Proposals no longer force a pause in continuous tasks. Revision checks, overwrite protection and retry deduplication remain; Chinese names and extrusion examples are improved. The Canvas entry is simply “3D Workbench”.
- Reduces per-operation confirmation for ordinary document and media edits and repeated review for routine local Linux VM commands. Repository writes and risky remote operations still follow the task's approval mode. The runtime verifies execution environments and write targets.

Qualification limits: module, full-App, Simulator and physical-device evidence remain distinct. Device responsiveness, extended use and performance require on-device retesting. Internal Floe QA only; no external beta, production/content publication or scheduled follow-up in this round.
