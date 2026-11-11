# Siri 与现有 Shortcuts 模块增量预研

日期：2026-11-06。调查基线：`e3a1b47a2e3c7223b96ec3d29efb26b9804bd86c`，根工作副本 `main`。交付复核时并发工作已将主线推进到 `e7e6fcb436dc729c4263afc7f7fcfb1627380b25`；本研究涉及的 25 份生产源码、模板和项目配置摘要均未变化。

本轮授权是模块预研与轻量核对。首批方向为快速记手记、查询任务进度、查找并打开手记；保留现有快捷指令。本文包含现状、增量接口草案和接入边界，尚未实现这些增量、修改 App 接线或完成系统 Siri 验收。没有完整构建、模拟器、物理设备、签名或分发操作。

用户补充方向：不将 App Store Connect 是否显示“已接入 SiriKit”作为本项工作的目标、交付指标或验收门槛。后续根据实际 Siri/快捷指令功能与既有合同兼容性判断完成；不为改变后台接入展示新增遗留框架、权限或无实际用途的动作。本轮不操作 App Store Connect。

## 结论与兼容基线

继续扩展 `FloeApp/Shortcuts`，沿用唯一的 `FloeShortcuts: AppShortcutsProvider`。现有代码已经实现 11 个 App Intent，其中 5 个有预设 App Shortcut；Siri 增强不是从零接入。首批只补手记动作、受控名称发现和语音表现，不新增旧 SiriKit Intents/IntentsUI 扩展，不另建任务运行时、权限中心或手记数据库。

还须区分两个已经存在的方向：

- **系统调用 Floe**：App Intents → 当前 AppEnvironment → 草稿、任务或定时任务服务。
- **Floe 调用用户的快捷指令**：`AppleShortcutsRunTool` / `apple.shortcuts.run` 打开系统 Shortcuts，结果不可观察。不能把系统界面已打开改报为快捷指令已完成，也不改变其原有确认边界。见 [AppleSystemTools.swift](../FloeAgent/FloeApp/Apple/AppleSystemTools.swift)。

### 现有 Intent 合同

下表为当前源码事实。类型名、参数名和参数类型、默认值、实体标识、已有本地化键与返回值语义均作为兼容基线；实施时不删除、改名或重新定义已有动作。

| 现有类型 | 参数 | 当前行为及返回 | 模式 / 预设入口 |
| --- | --- | --- | --- |
| `SendToFloeIntent` | `text: String`；`prompt: String = "Summarize this text"` | 将组合文字存入持久草稿 FIFO；返回已放置的文字回执；不启动模型任务 | 前台 / 有 |
| `CreateFloeTaskIntent` | `taskDescription: String` | 存入同一草稿 FIFO，交 Home 审阅；无业务返回值 | 前台 / 有 |
| `RunFloeTaskIntent` | `task: String`；`taskTitle: String?` | 启动普通持久任务；返回含 conversation ID 的本地化 String 回执，不能改成 typed run | 后台 / 有 |
| `ScheduleFloeTaskIntent` | `task: String`；`taskTitle: String?`；`scheduledAt: Date`；`cadence = .once` | 保存冻结模型、环境与权限绑定的日程；返回含 schedule ID 的 String 回执 | 后台 / 有 |
| `RunScheduledTaskIntent` | `schedule: TaskScheduleEntity` | 通过既有定时任务 coordinator 的 claim/launch/bind 链启动；返回确切的 `FloeShortcutRunEntity` | 后台 / 有 |
| `StartFloeRunIntent` | `prompt: String`；`taskTitle: String?` | 启动任务，返回含 run ID 和 conversation ID 的 `FloeShortcutRunEntity` | 后台 / 无 |
| `GetFloeRunStatusIntent` | `run: FloeShortcutRunEntity` | 查询该次运行，仍返回同类型实体 | 后台 / 无 |
| `WaitForFloeRunIntent` | `run`；`timeoutSeconds: Double = 20` | 有界等待并返回实体；超时不取消任务 | 后台 / 无 |
| `GetFloeRunTextIntent` | `run`；`includePartial: Bool = false` | 返回该次运行已证明归属的最终 String；部分结果必须显式选择 | 后台 / 无 |
| `CancelFloeRunIntent` | `run` | 校验归属后请求取消；返回实际观察到的实体状态 | 后台 / 无 |
| `GetFloeRunFilesIntent` | `run`；`includePartial: Bool = false` | 返回该次运行通过快照核验的 `[IntentFile]` | 后台 / 无 |

来源：[FloeShortcuts.swift](../FloeAgent/FloeApp/Shortcuts/FloeShortcuts.swift)、[FloeShortcutRunIntents.swift](../FloeAgent/FloeApp/Shortcuts/FloeShortcutRunIntents.swift)、[FloeScheduledTaskIntents.swift](../FloeAgent/FloeApp/Shortcuts/FloeScheduledTaskIntents.swift)。

`FloeShortcutRunEntityQuery` 目前只恢复显式 run ID，`suggestedEntities()` 返回空；`TaskScheduleEntityQuery` 恢复显式 schedule ID，并推荐最多 20 个启用日程。保留这些默认发现行为，不自动扩大为历史任务/手记枚举，也不把 conversation ID 当作 run ID。

现有 `FloeShortcuts.swift` 与 [本地化模板](../FloeAgent/scripts/l10n/FloeShortcuts.template.swift)逐字节一致；`scripts/l10n/apply_special.py` 会从模板覆写该文件。未来若改 provider，必须同步维护模板，不能只编辑生成落点。现有打包的 `FloeScheduledTask.shortcut` 及导入绑定本阶段不变。

## 首批模块与接口草案

以下新类型名为建议名，尚未加入源码或系统注册。

| 编号 | 增量 | 复用模块 | 建议合同 |
| --- | --- | --- | --- |
| SIR01 | 快速记手记 | `NotesRepository.shared` → `NotesStore` | `CreateFloeNoteIntent(text, title?, notebook?)` → `FloeNoteEntity` + 简短保存回执；后台完成本地写入 |
| SIR02 | 查询任务进度 | 当前 exact-run bridge/service | 给已有 `GetFloeRunStatusIntent` 增加 `ProvidesDialog`，保留 `ReturnsValue<FloeShortcutRunEntity>`、参数、认证与执行语义；按名称发现单独见下文 |
| SIR03 | 查找并打开手记 | `NotesStore.search`、现有根入口及 NotesSession | `FindFloeNotesIntent(query, modifiedRange?)` → `[FloeNoteEntity]`；`OpenFloeNoteIntent(target)` → 前台导航到精确文档 |

`FloeNoteEntity` 只暴露文档 ID、标题、种类、更新时间等必要元数据；不包含编辑器、撤销栈、整份正文、OCR 内容、二进制或助理会话。`notebook` 如果需要，使用现有集合身份；快速记录创建的是 `NoteDocument(kind: .notebook)`，不是新建一个笔记本集合。

### SIR01：明确保存后才答复

1. 复用现有 `.shortcuts` 能力开关和 App 拥有的依赖。纯手记写入只要求可用的手记持久存储，不要求默认 AI 模型，也不使用 `ensureReadyForExternalAutomation()` 的模型配置门槛。
2. 通过 [NotesRepository](../FloeAgent/FloeApp/Notes/NotesRepository.swift)取得唯一 NotesStore，用现有 `NoteDocument` / `NotePage` / `NoteElement` 构造文本手记，在一次 `NotesStore.create` 事务中提交正文、索引和资源引用。输入为空、过大或集合身份失效时明确失败。
3. 等待事务提交后返回文档实体与“已保存手记 / Saved note”；保存成功不自动导航，不改变当前手记、选区或聊天草稿。现有 `NotesStore.changes()` 负责通知已打开的编辑器。
4. 取消在提交前检查；提交已完成时不能再把它误报为未保存。相同正文可以是两次合法记录，不能按正文哈希合并。没有稳定系统调用标识时，不承诺跨系统重试恰好保存一次。

普通记录不走 AI 的 `notes.edit` 提议审批，也不伪造一个 conversation scope。系统明确发起的用户动作不会因此向模型授予其他手记的访问权限。追加/覆盖已有手记留到后续，届时仍用 `NotesStore.apply(expectedRevision:)` 和原冲突机制。

### SIR02：发现与查询分开，保留确切运行身份

`GetFloeRunStatusIntent` 已经完成查询能力，增量首先是自然的语音回复，而非再注册一个同名“查询任务”动作。状态措辞复用 `FloeRunStatus` / `FloeShortcutRunDisplayState`：运行中、等待确认、已暂停、已取消、失败或不可用均如实表达；不能将 raw `completed` 一律读成全部成功。正文仍由原 `GetFloeRunTextIntent` 取得，不能用中间推理或工具前文本冒充最终结果。

按名称找任务建议新增一个职责明确的 **发现动作** `FindFloeRunsIntent(name)`，经认证后返回现有 `[FloeShortcutRunEntity]`，然后串接原查询动作。它只查持久化、普通、正常可见任务；默认排除归档、Notes 助理会话和临时聊天。按标题匹配后取得有界运行候选，显示运行时间和状态；重名或同任务多次运行时交用户选择，不暗中取另一个“最新 run”。

现有 [ConversationStore](../FloeAgent/Sources/FloePersistence/ConversationStore.swift) 的普通任务列表具备 purpose/visibility/archive 过滤，但读取整表；实施名称发现时应在同一 store 增加参数化、有上限的标题查询，不能从 UI 缓存筛选后声称检索完整。运行候选复用 [RunStore.recentRuns](../FloeAgent/Sources/FloePersistence/RunStore.swift)，选定之后固定 run ID + conversation ID，再交当前 bridge 校验。

首批不改变 `FloeShortcutRunEntityQuery.entities(for:)` 和空推荐列表。这样旧快捷指令继续恢复原引用，名称搜索也不会在系统参数推荐时自动暴露整个历史。若后续要直接加入 `EntityStringQuery`，先完成查询阶段的认证与隐私核对；不能只在 `perform()` 解锁就假定所有参数查询已受保护。

普通 Siri 可先用有名称的组合快捷指令串接“发现 → 选择候选 → 原状态查询”。不把 App Shortcuts 的示例话术等同于任意自然语言、多步自动编排已可用。只读查询继续使用 `ensureDurableAutomationReady()`，没有可用模型也应能读取已有运行；缺记录或存储失败不创建替代任务。

### SIR03：已有搜索可用，打开通道需要小幅泛化

[NotesStore.search](../FloeAgent/Sources/FloeNotes/NotesStore.swift) 已有中文可用的字面包含搜索、LIKE 转义、排除回收站及结果上限。首批复用它，不为 Siri 另建索引或启动 OCR/Office 提取；尚未索引的内容不宣称可全文查到。查询日期用明确时间范围和时区参数，按数据库条件过滤后再限量，不能先取前 N 项再过滤日期。

新查找/打开动作采用适当的系统认证策略；实体默认只按 ID 恢复、推荐列表为空。名称查找在已认证的显式搜索动作中执行，返回标题/种类/更新时间以便消歧。只读查询在手记库不存在时返回空，不因调用 `NotesRepository.store()` 而悄悄创建空库；需要为 repository 补“已有库读取”入口，复用其路径和实例管理。

打开手记的当前真实路径是：

`根场景导航 → AppRouter.openMore(.notes) → DocumentIntakeCenter.noteOpenRequest → NotesRootView 认领 → NotesSession.adoptImportedDocument → select`。

已有请求带 scene ID，并且只允许一次认领；`select` 等待保存队列、检查未保存文档并调用离开守卫。这些机制应保留。对应源码为 [DocumentIntakeCenter](../FloeAgent/FloeApp/DocumentIntake/DocumentIntakeCenter.swift)、[NotesRootView](../FloeAgent/FloeApp/Notes/NotesRootView.swift)、[NotesSession+DocumentIntake](../FloeAgent/FloeApp/DocumentIntake/NotesSession+DocumentIntake.swift) 和 [NotesSession](../FloeAgent/FloeApp/Notes/NotesSession.swift)。

**不能直接伪造 DocumentIntakePresentation 调用现成方法**：现有请求要求真实导入 event ID，完成后显示导入成功，失败后的重开也关联该事件。建议把同一打开通道泛化为可区分 `.import(eventID)` / `.systemAction(requestID)` 的请求；原导入行为和回执保持原样，Siri 来源只报告文档已打开或暂不能切换。源标签是导航上下文，不能授予读写权限。

冷启动通过现有 [FloeAppEntryRoute](../FloeAgent/Sources/FloeCore/FloeAppEntryRoute.swift) / 根入口的待投递机制增加严格文档 ID 路由，或等价的系统 Intent 场景交接。当前只有 new/task/share/externalFile，**尚无已实现的 note URL**；不能直接生成 `floe://note/...` 后宣称可打开。目标场景由系统/既有根路由确定，不选全局第一个窗口，不把 `sceneID = nil` 当作可向所有窗口广播。用户在等待中主动导航后，旧请求应失效。

保存失败、当前编辑器不允许离开或目标已删除时保留现状并给出可操作反馈；不能清空当前文档来强行完成。Notes 与 Canvas/聊天的编辑状态及助理会话继续独立。复用既有文档打开路径，不增加绕过 `PDFKitGate` 的渲染入口。

## 接入顺序与文件所有权

1. **合同阶段**：冻结上表已有动作，补新增参数/回执与英中本地化文案；明确名称候选、认证和场景投递规则。本轮已完成这一步的源码预研，尚无运行实现。
2. **手记服务阶段**：在 NotesRepository/NotesStore 补已有库读取、明确时间范围的有界查找与一次文本创建的薄适配；编辑器不参与后台保存。存储与冲突逻辑继续归原模块。
3. **系统动作阶段**：新 Notes/发现 Intent 放回 `FloeApp/Shortcuts`；原状态 Intent 只增加展示能力。保持 `FloeAgentApp.init` 的单一 AppDependencyManager 注册，不创建第二个 AppEnvironment。
4. **导航阶段**：由同一 owner 同步处理根入口、AppRouter、NotesRootView 与现有导入请求泛化，保留未保存守卫和导入事件回执；不改外层 split-view 结构。
5. **可发现性阶段**：只在原 `FloeShortcuts` provider 增补少量高频入口，原 5 项及其话术保留；查找、结果、取消等组合动作不必各占一个预设入口。维护本地化模板及 Localizable.xcstrings。若涉及 target/resource/settings，再按 project.yml 生成工程。

本轮不改 `project.yml`、生成 Xcode 工程、entitlements、`.shortcuts` 偏好键、定时任务绑定格式或任务持久层 schema。未来实现时如遇真实需要，应在相应小批次处理并说明迁移，不用新增“Siri 权限中心”替代原能力开关。

## 轻量验证与本轮实际核对

本轮仅做源码合同和文档核对，不以既有测试文件存在宣称测试已通过。原 11 个 Intent / 5 个 App Shortcut、模板一致性、相关英中键以及下列路径均已读取；相关生产源码、签名和注册没有因本次预研改动。

未来实现时按受影响边界选择少量检查，不把整套回归、真实模型账户或 Siri 真机矩阵作为预研门槛：

| 变化边界 | 可复用检查及需补的小范围用例 |
| --- | --- |
| 既有动作合同 | `FloeShortcutRunIntentTests` 的 legacy String、exact run、跨任务引用、超时/取消；确认新增 dialog 后返回实体及参数元数据仍兼容 |
| 冷启动 | `FloeShortcutsInitializationTests`、`FloeShortcutRunProductionWiringTests`；无模型仍可读状态/本地记手记，关闭 Shortcuts 时不读写 |
| 草稿 | `ShortcutInboxHandoffTests`；本轮无草稿链改动，不机械全量重跑，实施若触及该链再选相应 FIFO/多窗口用例 |
| 名称发现 | 相同标题、多次 run、归档/隐藏/Notes/临时任务排除、缺失及存储失败；读取不启动任何任务 |
| 手记创建/搜索 | 空输入、提交失败不报成功、相同正文独立记录、中文/通配字符、回收站、未索引内容、带日期过滤及库不存在不创建 |
| 手记打开 | `ExternalDocumentIntakeTests.noteOpenRequestClaimsOnceAcrossWindows`；补来源区分、重复请求、错误窗口、未保存守卫和原导入回执不变 |
| App Intent 编译 | 新代码需要实际相关 SIL/object 编译及元数据提取；先用小范围编译，不把 typecheck 等同于 Swift 6 编译通过 |
| 系统实际表现 | 未来在授权的复用 iPad Simulator 做最小导航抽查；Siri 语音、锁屏及系统参数认证仍是设备证据，不由组件测试替代。本轮不使用用户物理 iPhone |

本轮没有编译输出、安装包或 Simulator 生命周期需要清理；只保留本预研和轻量源码基线/核对记录。现有其他预研模块与未跟踪文件保持原样。

## 平台边界与后续项

- Apple 当前将 SiriKit 列为旧接口兼容支持；部分旧 API（包括创建/查找手记等）已标记弃用，旧 Lists and Notes 域不支持 Apple Intelligence / Siri AI。这不等于整个框架已经停止运行；下列官方说明没有给出整个 SiriKit 的统一移除时间表。新增动作使用 [App Intents](https://developer.apple.com/documentation/appintents) 与 [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)。[SiriKit 说明](https://developer.apple.com/documentation/sirikit)、[旧手记域说明](https://developer.apple.com/documentation/sirikit/lists-and-notes)
- [EntityStringQuery](https://developer.apple.com/documentation/appintents/entitystringquery) 提供字符串匹配，不自动提供授权、任意自然语言时间解析或全文语义检索。[认证策略](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy) 需要结合参数查询与动作执行分别设计，不能为新增体验悄悄修改旧快捷指令的锁屏行为。
- 标准手记动作可后续对接 [Notes schema](https://developer.apple.com/documentation/appintents/app-schema-domain-notes)，只映射真实的 note/folder/account，保留 iOS/iPadOS 26 兼容。当前自定义任务不硬套提醒事项或消息 schema。
- 常用流程优先复用原 `RunScheduledTaskIntent` 或现有任务配置；文件接力复用共享/文档接收和原 `GetFloeRunFilesIntent`。二者不在本轮实现范围，也不重复建立执行引擎。
- Apple 于 2026-11-03 开放的 [Siri AI Developer Preview](https://developer.apple.com/documentation/appintents/siri-ai-developer-preview) 可探索屏幕上下文、自定义工具与多步 app skills；目前为 27.3 beta 开发预览，限开发签名与内部 TestFlight，外部 TestFlight/App Store 不可用，API 可变。它不作为上述基础增量的依赖或当前交付承诺。[发布说明](https://developer.apple.com/news/?id=gdk2umrf)
- 本轮无分发授权，不改版本号或发布状态；保留正式 Build 315 的审核及自动发布设置。
