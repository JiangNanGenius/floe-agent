# Floe Mac 工作台与 iPad 功能对照（按用户流）

> 第 1–11 节记录 1.11.0 的源码基线。第 12 节起按版本记录增量，第 16 节列出 1.11.4 的工作台现状。
>
> - iPad 基线：`origin/main` = `6165fd01eaf181e97db2feff9326f7a8f4c53458`（`git show origin/main:<path>` 取证）。
> - Mac 基线：同一提交的已发布标签 `floe-mac-v1.11.0`（appcast build 30，bundle `org.floeagent.macbridge`，`FloeMac/project-ota.yml`；正式数据目录 `~/Library/Application Support/Floe Mac Agent/floe.sqlite`）。
> - 下表记录 1.11.0 的源码基线。后续发布的增量记录从第 12 节开始。

状态图例：✅ 已按源码实现　⚠️ 部分实现　❌ 未实现　➖ 双端均无　? 源码无法判定

## 总览

| # | 用户流 | iPad (main) | Mac (v1.11.0) | 差距结论 |
|---|---|---|---|---|
| 1 | 项目任务受理 | ✅ | ✅ | 基本对齐 |
| 2 | 模式选择器 / harness | ✅ | ⚠️ | Mac 无评测 harness、无临时聊天 |
| 3 | 模型配置 | ✅ | ✅ | 基本对齐（Mac 无本地模型组） |
| 4 | 文件附件 | ✅ | ✅ | 基本对齐 |
| 5 | 图像/视频创作 | ✅（含 MediaV2 编辑引擎） | ⚠️ | Mac 画布为简板、无图像编辑引擎 |
| 6 | 权限 / 自动审批 | ✅ | ✅ | 基本对齐；协调器新增 3 项均缺 |
| 7 | 提示词编辑/重试/回退 | ⚠️ | ⚠️ | 双端均无 rewind、无"编辑已发送消息" |
| 8 | 上下文保留与历史 | ✅ | ⚠️ | Mac 无全局会话内容搜索 |
| 9 | Space = 文件管理工具箱 | ✅ | ⚠️ | Mac 有文件列+工具箱格，无 iPad 式富媒体库 |
| 10 | 设置面 | ✅（约 22 项） | ⚠️（4 页） | 多数 iPad 设置项 Mac 未对应（部分可能不适用） |

---

## 1. 项目任务受理 ✅/✅

**iPad**：`ConversationCenter.startTask(goal:…)`（`FloeAgent/FloeApp/Remote/ConversationCenter.swift:5769`）；目标模型 `GoalModels.swift:173`（`ConversationGoal`/证据与标准/完成裁决）；计划 `PlanningModels.swift`（`ConversationMode` chat/plan/goal）；子任务 `SubagentRunner.swift:108`、`DelegateTool.swift:22` + `DelegateWaitTool`、`ChildRunStore.swift:56`；任务提问 `UserQuestionTool.swift`（`"user.ask"`）+ `UserQuestionCoordinator` + `UserQuestionCenter.swift:18`；命名 `TaskTitlePrompt.swift`；状态 `RunStore` + `MoreView.swift` Runs 列表 + `TaskScheduleSheet.swift`。

**Mac**：`HostAgentWorkspace.send(_:workspaceID:mode:criterion:)`（`FloeMac/Sources/FloeMacHost/HostAgentWorkspace.swift:1376`）；任务中心 `MacWorkspaceTaskCenter.swift:10`（标题/目标搜索、当前/已归档、停止/删除）；目标卡 `goalCard` + `editGoal`/`confirmGoal`/`continueGoal`；计划复核卡直接复用 iPad `ThreadPlanReview`，`acceptPlan` 后可再运行；子任务 `HostChildSubagentController.swift:73` + `MacChildTasksView.swift:4`（含逐项取消）；提问 `FloeMacSelfQuestionToolExecutor` + 复用 `UserQuestionCardView`，回答/拒绝/草稿 + `MacQuestionHistoryView`；命名 `MacTaskNaming.swift:9`（辅助文本模型流式生成，20s 超时）。

**结论**：结构对齐。Mac 任务中心的置顶/重命名/清空归档在当前工作树未提交改动中补齐（ shipping 版经由侧栏上下文菜单完成）。

## 2. 模式选择器 / harness ⚠️

**iPad**：执行模式枚举 `AgentExecutionMode`（agent/chat/plan/goal，`ThreadComposerView.swift:25`），选择器 `FloeComposerModeMenu`（`Design/FloeTheme.swift:271`）；运行时 harness `Sources/FloeAgentRuntime/Harness.swift`（`HarnessState`、`HarnessBudgets`、快照、`AgentRuntimeHarnessBridge:550`）；UI 测试 harness `WorkbenchUITestHarness.swift:28`（`--ui-test-workbench-fixture` 等入口，`App/FloeAgentApp.swift:186`）。

**Mac**：宿主模式仅有 **Agent / Bridge** 两种启动模式（`FloeMacBridge/Sources/FloeMacBridgeApp/FloeMacBridgeApp.swift:116`，持久化 `floe.mac.launchMode`）；任务模式 chat/agent/plan/goal（`HostAgentWorkspace.swift:122`）+ 复用 `FloeComposerModeMenu`。工具箱是 Space 页/独立窗口，不是模式。

**差距**：❌ Mac 无 harness/评测模式；❌ Mac 无 iPad 的临时聊天（RAM 只读天花板，`ConversationCenter.swift:802` `temporarySession`、`temporaryToolCeiling:1180`）。

## 3. 模型配置 ✅/✅

**iPad**：`Settings/ProvidersSettingsView.swift` → `FloeApp/Providers/ProviderListView`、`ModelPickerView`；GRDB 存储 `Sources/FloePersistence/ModelConfigurationStore.swift:99`；密钥 `CredentialStore` + `KeychainSecretStore`；iCloud 同步 `Sources/FloeSync/ConfigSyncEngine.swift` + `FloeSyncCore/ConfigMerge.swift`；辅助模型 `AuxiliaryModelsView.swift`；适配层 `Sources/FloeProviders/`。

**Mac**：`MacProviderSettingsView.swift:18`（账号↔多模型分组，`HostProviderAccount.swift:5`）；会话级模型记忆（`applyComposerRun:2453`，随会话最近运行恢复）；辅助模型 `MacAuxiliaryModelsView.swift:23`（命名/视觉/审批审阅）；iCloud 同步 `MacICloudModelSync.swift:56`（CloudKit `iCloud.org.floeagent.ios`，发布时剥离密钥）；单模型选项 `MacProviderOptionsView.swift:5`（工具名兼容、自定义头、推理力度、主选择器隐藏）；图像/视频账号独立 Keychain（`MacImageGeneration.swift:168`、`MacVideoGeneration.swift:126`）。

**差距**：⚠️ Mac 选择器明确排除本地/端上模型（`MacCloudModelEntry.accepts`），iPad 有 MLX 本地模型组；其余对齐。

## 4. 文件附件 ✅/✅

**iPad**：输入侧 `ThreadComposerView`（`attachments`、`registerPicked`）；注册 `Files/FilesCenter.swift:26`（安全域书签）；气泡/打开 `UserMessageBubble.swift`、`ChatAttachmentOpen.swift`；文档摄取管线 `DocumentIntake/`（队列/路由/存储）；Space 文件 `Space/PersonalContentService.swift`；草稿 `ComposerDraftStore.swift:65`。

**Mac**：`stageAttachments(_:)`（`HostAgentWorkspace.swift:1145`，只读安全域书签、`O_NOFOLLOW` 有界读取、SHA-256、类型嗅探、分档大小上限）；草稿 `MacWorkspaceDraftStore.swift:10`（`drafts.json`，文本 1MB/文档 32MB 上限）；读文档工具 `workspace.readFile` / `workspace.readDocument`（PDF/DOCX/RTF 文本层）；Space 文件 `MacWorkspaceFilesView.swift:104`（书签根目录、改名/删除/导入/导出、Quartz 预览、32KB 轻量文本编辑、原子保存）。

**差距**：⚠️ Mac 无 OCR 附加入口（OCR 在文档工具内）；无 iCloud Drive 浏览集成。整体可用性对齐。

## 5. 图像/视频创作 ✅/⚠️

**iPad**：工作台 `Workbench/MediaWorkbenchView.swift` + `WorkbenchCenter.swift:90`；**MediaV2 原生编辑引擎** `Workbench/MediaV2/`（约 50 个文件：扩图/重绘/形变/调色/HDR/视频动效/矢量文字/人声分离等，`MediaV2Session.swift` 598 行）；AI 生成抽屉 `WorkbenchAIDrawer.swift`/`WorkbenchAIBridge.swift` → `MediaGenerationService`（`Platform/BackgroundRunCoordinator.swift:7068`）；持久任务 `MediaGenerationJobStore`；原生处理 `Sources/FloeImages/ImagePipeline.swift`、`Sources/FloeMedia/MediaCore.swift:347`；视频时间线 `WorkbenchVideoPanels.swift`。

**Mac**：图像生成 `MacImageGeneration.swift:16`（预设/参考图转编辑操作/防重复计费提交/200 条历史）；图像工作台 `MacImageWorkbenchView.swift`；视频生成 `MacVideoGeneration.swift:22`（持久异步作业、轮询、512MB 有界下载、mp4/webm 嗅探、重开恢复、取消）；视频工作台 `MacVideoWorkbenchView.swift`；创作库 `MacCreativeLibrary.swift:9`（`CanvasProject` 编解码与 iPad 相同，三页创作工作台 `MacCreativeWorkbenchView`）。

**差距**：
- ❌ **Mac 无 MediaV2 等价物**（无扩图/调色/人声分离等原生编辑流）。
- ⚠️ Mac 画布为**简板**：`MacCreativeLibrary.swift:196-204` 明确拒绝含 `canvasKitState`、笔迹 `strokes`、`pencilDrawingData`、连线 `connections` 的 iPad 工程（抛 `mac.creative.unsupported`）；无 Pencil 编辑/连线/脑图渲染。

## 6. 权限 / 自动审批 ✅/✅ + 三项新缺口

**iPad**：`Settings/AgentPermissionsView.swift:16`（默认模式 human/approvalModel/fullControl，Full Control 需 LocalAuthentication `authenticateFullAccess:137`）；策略 `Sources/FloeModels/TaskPolicy.swift:85`（`TaskApprovalMode` ask/automatic/fullAccess + 每会话工具/路径/网络/凭证天花板）；审批卡 `Chat/ApprovalCardView.swift:85`（可折叠 diff/证据）；持久授权 `Sources/FloeSecurity/ApprovalGrantStore.swift:9` + `ApprovalDecision.swift:111`；灾难动作闸门 `CatastrophicActionGate.swift`。

**Mac**：`MacPermissionsSettingsView.swift:18`（默认审批模式、审阅模型、Full Access 说明；`authorizeFullAccess` 走 `LAContext`，`HostAgentWorkspace.swift:372`）；审批卡 `MacWorkspaceApprovalView.swift:9`（复用 iPad `ApprovalCardView`，文件作用域 once/任务文件/项目文件 → `FloeMacFileGrantScope`，证据预览）；策略 `MacTaskApprovalPolicy.swift:9` → **共享 iPad `TaskApprovalPolicyFactory`** + 可选 `ApprovalModelBackend` 审阅；已存授权 `MacSavedApprovalGrantsView`；按任务持久模式 `setTaskApprovalMode`。

**差距（含协调器 2026-11-21 新增范围）**：
1. ❌ **macOS 原生 exec 三级风险**：已提交 Mac 源码中无 `exec.shell`/风险分级实现（`git grep origin/main` 无命中）。
2. ❌ **工作区外审批 / Full Access 跨边界**：Full Access 审批模式已存在，但无"跨越工作区边界需审批"的流程；iPad `TaskPolicy` 的路径天花板语义在 Mac 侧未见对应。
3. ❌ **非前台 KimiCU**：已提交 Mac 源码无 KimiCU 相关实现。
4. ⚠️ Mac 无自动审批决定的审计日志查看器；授权粒度为 文件+操作+任务/项目，无通配。

## 7. 提示词编辑 / 重试 / 回退 ⚠️/⚠️

**iPad**：编辑未发送/排队输入 `ThreadDetailViewModel.editPendingInput`（`:2082`）+ `RunningInputStore`；重试 `ConversationCenter.retry`（`:9472`）、`ThreadDetailViewModel.retry`（`:2132`，失败/中断/检查点态可继续）；失败重试按钮 `ErrorEventView.onRetry`；计划重跑 `retryConfirmedPlan`（`:2225`）；目标编辑 `editGoal`（`:2379`）。

**Mac**：输入编排 `editFailedInput`（`HostAgentWorkspace.swift:1249`，失败提示恢复进输入框）、排队行内编辑 `MacQueuedInputEditor`（`editQueued:2124`）；运行中转向 `steer`（`:2354`）+ 持久排队输入（编辑/排序/移除/提升为指导/降级，`enqueue:2060`）；计划确认卡重跑、目标续跑。

**共同缺口（双端 ➖）**：
- ➖ **rewind / 回退到某条消息分叉**：双端源码均无（`rewind|forkTo|branchFrom` 在 `FloeMac/Sources`、`FloeAgent` 均无用户流实现）。
- ➖ **编辑已发送消息**：双端均无；仅失败运行/未发送队列可编辑。
- ➖ **逐条助手消息"重新生成"**：双端均无独立实现（仅有按 run/plan 粒度重试）。

## 8. 上下文保留与历史 ✅/⚠️

**iPad**：GRDB 持久 `Sources/FloePersistence/DatabaseManager.swift:93` + `SQLiteConversationStore`/`SQLiteRunStore`/`ConversationPromoter`（临时→正式提升）；全局历史搜索 `Chat/ConversationSearchView.swift` → `IntelligenceStore.conversationSearchMatches`（`Sources/FloeAgentRuntime/IntelligenceStore.swift:1586`）；会话内查找 `ThreadSearchBar`；提问历史 `UserQuestionStore`；上下文引擎 `ContextEngine.swift`（预算/压缩/保护）；批量管理 `ConversationBatchManagementView`。

**Mac** 使用 `floe.sqlite` 持久化会话，通过 `HostAgentDatabase.swift` 校验数据库与目录权限。重开应用时恢复最近的会话和项目。会话内按 ⌘F 打开共享的 `ThreadSearchBar`，由 `ThreadSearchModel` 定位消息。任务中心、侧栏标题搜索、`MacQuestionHistoryView` 和经凭据过滤的 Markdown 导出各自保留原入口。

**1.11.0 的差距**：当时只能搜索本会话和任务标题、目标。1.11.2 已增加跨会话正文搜索及原消息定位（第 13 节）。会话可按项目、置顶和归档组织。

## 9. Space = 文件管理工具箱 ⚠️

**iPad**：Space 富媒体库 `Space/PersonalContentService.swift`（文件夹、移动、回收站 `PersonalLibraryTrash`、`PersonalRecentlyDeletedView`、预览 `PersonalLibraryPreview`）；工具箱 `Space/Toolbox/ToolboxRootView.swift` + 模块 `FloeAgent/Modules/FloeToolbox/Sources/FloeToolboxCore/ToolCatalog.swift:5`；Agent 可用工作室工具 `Space/StudioAgentTools.swift`（`registerStudioAgentTools:1751` 注册进 `ToolRunnerRegistry`）。

**Mac**：文件列 `MacWorkspaceFilesView.swift:104` + 工具箱格 `MacWorkspaceToolboxView.swift:6`/独立窗口 `MacToolboxWindowController`；工具目录 `FloeMacToolbox` 包（终端、VNC、浏览器、HTTP/WebSocket/MQTT、USB 串口、网络诊断 ping/traceroute/DNS/端口/局域网/Wi-Fi；水平仪/运动/指南针/测量/气压计在 Mac 上为空视图）。

**差距**：⚠️ Mac 无 iPad 式富媒体库（全工作区文件夹/回收站/最近删除）；文件范围限单一书签根目录。按用户方向"Space=文件管理工具箱"，Mac 骨架已就位，缺富媒体库语义。

## 10. 设置面 ⚠️

**iPad**：`SettingsRootView.swift:15` 约 22 个分区（通用、提供方、辅助、本地模型、权限、Apple 能力、隐私、执行环境、后台执行、文件、同步、远程、用量、数据管理、诊断、更新、GitHub、网页搜索、浏览器、内部提示词、反馈、许可证等）。

**Mac**：统一设置 `UnifiedMacSettingsView` 4 页：通用（外观/默认模式/答案核验）、模型（提供方+媒体账号+辅助+iCloud+选项）、权限、Bridge（配对管理、更新、存储清理、屏幕录制/辅助功能权限行）。

**差距**：⚠️ Mac 未对应项：本地模型、执行环境管理、后台执行、网页搜索/浏览器、用量统计、数据管理/存储优化、诊断导出、更新通道、反馈、远程连接等。其中部分对 macOS 可能不适用，需产品裁决，不计入已实现。

## 11. 存储与身份（实现路径证据）

- iPad：`DatabaseManager`（GRDB `DatabasePool`）；iCloud 容器 `iCloud.org.floeagent.ios`。
- Mac：`~/Library/Application Support/Floe Mac Agent/floe.sqlite`（`HostAgentDatabase.swift:10-14`，`namespace == "org.floeagent.macbridge"`）；CloudKit 同容器、按账号哈希分库（`MacICloudModelSync.swift:37`）；草稿 `Drafts/drafts.json`，媒体 `Images/`、`Videos/`、`Canvases/`。

## 12. Mac 1.11.1 增量验收

- 从 Mac App 新建两个未指定项目的会话，通过本机模型协议样例触发真实 `exec.shell`。内核返回 Darwin，会话文件分别保存，重新打开第一条会话能找回原文件。
- 拒绝工作区外操作后文件未变，单次批准后写入成功。普通工作区执行通过符号链接读取相邻文件时也被系统拦住。完全访问模式下，测试命令在当前账户权限内直接写入同一文件。
- 使用已授权的 Kimi CU 0.6.8，在一个后台 AppKit 测试窗口实际填写文本、点击按钮并读取窗口截图。按钮计数和输入值已在目标端确认，全程目标窗口未成为前台。其他应用的控件和系统对话框行为可能不同。
- 该版本记录的三个缺口中，跨会话正文搜索在 1.11.2 加入，临时聊天在 1.11.4 加入。完整创意编辑仍有差距。

## 13. Mac 1.11.2 工作台与设置

- **查找旧消息**。侧栏输入关键词后可进入「搜索会话正文」。任务中心在当前或归档范围内复用 iPad 的可见消息搜索，显示匹配片段；当前任务的命中项可以定位到原消息。返回任务中心会保留本次检索条件。归档任务可先恢复再打开。
- **继续已有任务**。会话开始后，输入栏保留会话文件夹或项目入口；右键自己的消息可放入输入框，已有草稿可追加。助手回复支持直接复制。
- **配置任务**。模型尚未配置时可从输入栏进入设置。权限页集中显示默认审批、Agent 操作开关、审批模型及系统授权入口；运行期间可切换该会话后续操作的审批模式。当前待审批卡仍需处理。
- **设置导航**。提供方、辅助模型、图像和视频配置可直接进入；通用设置可选择运行中输入是排队还是引导。Bridge 页继续使用同一套配对和更新设置。
- **仍待对齐**。一次性临时聊天、完整的画布/媒体编辑和空间文件的最近删除仍有差距。同步本轮暂缓。

## 14. Mac 1.11.3 模型供应商与会话附件

- iPad 的 `ProviderListView` 按对话、生图和视频组织账号，`ProviderEditorViewModel` 在首次保存可用模型时填写对应的空默认项。Mac 采用这两个操作顺序，并复用 `ProviderCatalogServiceRole`、供应商表单规格和媒体适配器。Mac 安装包与 iPad 使用同一份 ProviderCatalog.json，火山 Agent Plan 与阿里 Token Plan 可使用随包模型候选。
- Mac 设置中的「模型供应商」集中管理三种用途。添加、发现模型、按模型启停和默认模型选择均基于同一份账号目录。创作工具可以仅为本次生成选模型，参数和凭据跟随实选账号；更改默认项后，已提交视频继续按原账号恢复。旧版单独保存的媒体配置可继续使用。
- 会话输入框可从 Finder 粘贴文件，从剪贴板粘贴截图，也可用系统照片选择器添加图片。导入图片归属当前会话并沿用现有附件草稿。移除外部文件附件保留原件。
- 临时聊天、完整的画布编辑工具和空间的最近删除仍待对齐。当前版本的媒体请求覆盖共享适配器支持的能力；供应商实际支持的模型和参数取决于所选服务。


## 15. Mac 1.11.4 会话浏览与子代理

- 会话链接和浏览器入口在工作台中打开 WebKit 页面。返回后继续编辑原会话草稿，已打开的任务各自保留临时浏览状态。空间中的项目或会话 HTML 可以连同目录内的图片、脚本和样式交互预览。
- Chat、Plan 和 Agent 的主任务可调用 `web.fetch` 在后台读取公开 HTTPS 页面。Mac 和 iPad 复用同一套网页正文提取和分页逻辑。后台读取独立于浏览器登录状态。
- 个人会话和项目任务均可派发独立执行的子代理。沿用共享的派发、等待、逐项取消和持久记录。父任务中可检查完整结果、失败或中断说明，重新打开会话后仍可查看。子代理通过父任务逐次授权，沿用其工作区、工具范围和当前审批模式。
- 会话消息附件使用系统快速查看，可在预览中定位访达原件。展开输入框编辑长草稿时，完成、发送和运行中追加输入沿用原会话操作。
- 新任务右上角提供临时聊天。消息、运行和草稿归属同一内存会话；实际切换目的地时同步撤销。主动保留通过共享的 `ConversationPromoter` 在同一个事务中保存首次使用的模型、消息、运行及归属。已用签名 Debug App 验证首次保存、失败回滚及重试、进入临时聊天后用 ⌘N 离开。
- 任务导出保留现有 Markdown，增加纯文本和 iPad 共用的 JSONL。结构化导出包括持久化的工具事件、用量和附件引用。空间和任务文件栏可新建文件夹、重命名、移入系统废纸篓，并从本应用的「最近删除」恢复。
- 设置里的网页搜索使用 iPad 的供应商目录和搜索服务；配置与停用即时影响后续搜索。用量统计直接编译 iPad 既有页面并使用同一 SQLite 汇总查询。两页已从 Mac 的 ⌘, 设置窗口实测打开。

## 16. 1.11.4 主工作台对照

| 用户操作 | Mac 当前入口及范围 |
| --- | --- |
| 窗口、键鼠和触控 | 主窗口共用 iPad 的侧栏行、输入标签和审批卡。常用按钮使用 44 点目标，项目展开、打开、新建分开命中，次级操作常显。输入选项按实际宽度换行；设置按窗口宽度采用左右分栏或逐级导航。 |
| 新建、组织和找回任务 | 新任务可直接开始，会话有私有文件夹，也可指定项目。侧栏支持置顶、归档和按标题筛选；「搜索会话内容」跨会话检索正文并定位原消息。 |
| 发送和继续任务 | 输入栏提供模型、模式、审批和附件。Chat、Plan、Agent、Goal 沿用共享运行时和模式限制。计划确认、目标、运行中输入、审批结果和子任务记录跟随原会话。普通失败或中断任务可从历史发起下一轮，不自动重放先前动作。 |
| 从会话发起另一项工作 | 独立任务使用单独的会话记录、初始消息和工作区。可按权限检索其他任务；子代理通过主任务审批执行原生工具。 |
| 文件、附件和浏览器 | 「空间」集中管理文件和工具箱。任务文件栏可编辑、预览本地网站、定位原件和恢复删除。支持在同一工作区移动文件或目录、制作普通文件副本。会话网页链接回到同一份草稿。 |
| 模型配置、辅助模型和创意 | 对话、生图和视频归属供应商设置。辅助模型中可控制 Agent 是否自主选生图模型；默认沿用用户选定的生图模型。创意工作区仍有独立的生成和画布入口。 |
| 偏好设置与控制 | ⌘, 打开总设置。Bridge 有自己的标签页；设置同时提供权限、网页搜索和用量统计。 |
| 保存与导出 | 个人及项目任务可重开。临时聊天在保留前留在内存。已保存会话支持纯文本、Markdown 和与 iPad 共用的 JSONL 导出。 |

本轮仍可复现的差距包括运行中追加附件、从输入栏直接识别文字、端侧模型选择和完整画布编辑。Mac 的本机命令授权按次审核，已记住的授权主要覆盖文件操作；系统快捷指令及部分权限管理设置也没有 iPad 对应入口。同步及 3D 导演台按本轮范围暂缓。终端、VNC 和后台电脑操作的实际能力取决于目标连接及 macOS 已授予的权限。

## 17. Mac 1.11.5 主工作台增量

- 「模型供应商」沿用 iPad 的目录、搜索筛选和签名校验。下载的目录与实际保存账号使用同一份数据，账号列出模型仍按供应商自己的接口执行。失败任务可查看模型错误和原消息，并从设置调整连接。
- 两个会话同时输出时可以用 ⌘N 新建任务。草稿按会话保存，后台回包不会切换当前会话。任务中心复用 iPad 的选中、批量归档和恢复逻辑。
- 运行中引导和排队消息使用同一份附件记录，重开后仍可从消息看到原附件。输入栏可把已添加图片中识别的文字插入草稿。
- 浏览器从任务右上角的检查器菜单或消息链接打开。应用内回退保留原任务和未发送草稿。「空间」继续聚合文件管理和工具箱。

逐项对照仍发现的缺口包括异常退出后恢复待回答卡、浏览器下载与跨启动保留网页状态、按任务记住非文件工具审批、项目整理、部分诊断页面以及完整创意画布。

## 18. Mac 与 iPad 共用基础组件

基础流程以 iPad 的实现为源。Mac 构建直接编译共用组件，原生宿主负责窗口、菜单、键鼠、文件授权和本机工具。更改通用行为时从共用源修改，并用两端相同的输入检查结果。

| 基础流程 | 共用实现 | Mac 接入 |
| --- | --- | --- |
| 会话消息与历史 | `ThreadTimeline`、`ThreadTranscriptViewport`、`ThreadHistoryPaging` | 从当前任务读取同一套分页数据，接入 Mac 的文件预览、工具和审批。 |
| 会话内查找 | `ThreadSearchModel`、`ThreadSearchBar` 和共用消息搜索索引 | ⌘F 打开查找栏。搜索跳转、翻页和流式更新由共用组件保持位置。 |
| 模型供应商选择 | `ProviderCatalogPicker` 和现有 `FloeProviders` 目录 | Mac 设置页提供原生窗口和字段。目录行、筛选、选择及刷新按钮共用。 |

原生工具的进程、文件和桌面授权由 Mac 宿主提供，并使用共用运行时的工具和审批契约。

## 19. Mac 1.11.7 工作台基础组件

- 模型菜单和排队、引导的发送提示由两端直接编译同一份组件。Mac 输入区按模型、推理、项目、模式、运行中发送和权限排列，窄窗口按原顺序换行。
- 草稿确认按会话和文本版本处理。普通发送、排队和引导只清除提交时捕获的草稿。切换会话和发送时的重新编辑走同一个规则。
- 任务中心使用与 iPad 历史页相同的任务行布局和批量勾选控件。Mac 宿主管理会话路由、归档和恢复。
- 文件工作台共用 iPad 的文本分类和 UTF-8 解码。Mac 负责打开授权路径、拒绝跨工作区的异步回调以及核对文件版本后保存。

## 20. Mac 1.11.8 项目、提问与浏览器

- 侧边栏项目菜单和「空间」的文件夹菜单提供项目改名、访达定位和项目任务列表。改名更新现有记录，保留文件夹绑定、任务归属和权限。任务中心沿用共用的历史呈现与消息检索，项目过滤在数据库限制结果数之前生效。
- 重新打开意外中断的任务时，通过共用的持久化提问协调器读取原问题和草稿。回答由原任务、运行、请求、问题与修订号共同确认，已保存的答案保留在原运行记录。打开任务是一次历史读取，继续执行仍需用户主动选择。
- 会话浏览器按任务保存地址，打开浏览器时恢复。保存 PDF 或图片使用 iPad 的 `BrowserDownloadService` 和当前会话的 WebKit 登录态。Mac 的保存面板负责选定文件位置，浏览器显示进度、取消与完成结果。
