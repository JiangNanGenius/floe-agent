# Floe Mac 工作台与 iPad 功能对照（按用户流）

> 日期：2026-11-21。性质：**纯源码清点**，只做"是否实现/缺什么"的文件与符号级证据比对，**不含任何运行时、构建或分发验收**。
>
> - iPad 基线：`origin/main` = `6165fd01eaf181e97db2feff9326f7a8f4c53458`（`git show origin/main:<path>` 取证）。
> - Mac 基线：同一提交的已发布标签 `floe-mac-v1.11.0`（appcast build 30，bundle `org.floeagent.macbridge`，`FloeMac/project-ota.yml`；正式数据目录 `~/Library/Application Support/Floe Mac Agent/floe.sqlite`）。
> - 下表记录 1.11.0 的源码基线。1.11.1 与 1.11.2 的增量记录见 §12、§13。

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

**Mac**：全部实体持久于 `floe.sqlite`（`HostAgentDatabase.swift`，0700/0600 描述符校验）；重开恢复最近会话/项目（`@AppStorage`）；会话内搜索 `MacConversationSearch.swift:55`（共享 `ConversationSearchQuery`，20 页/2000 条/200 命中上限，Cmd-F）；任务中心+侧栏标题搜索；提问历史 `MacQuestionHistoryView`；导出 Markdown  transcript（`markdownTranscript`，裁剪凭证）。

**差距**：❌ Mac 无**跨会话全局内容搜索**（仅会话内 + 任务标题/目标）；无会话文件夹/标签（项目、置顶、归档之外）。

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
- 临时聊天、跨会话正文搜索和完整创意编辑能力仍属于后续对齐范围。

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
