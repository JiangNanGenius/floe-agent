# Floe 首轮工具与上下文优化实现与交付

2026-11-14。实现基线 `e770526d6`。云端按智能体、聊天、计划提供不同的直接调用范围，本地沿用固定资源档并按动作加载。

## 1. 云端首轮应该能做什么

普通会话的输入栏按产品文案列出「智能体」「聊天」「计划」「目标」。配置中的 `chatFastMode` 取自 `executionMode == .chat`，用于选择「聊天」的提示路径。普通文字和语音聊天使用同一模式判断。[输入栏模式菜单](../FloeAgent/FloeApp/Chat/ThreadComposerView.swift) · [产品文案](../FloeAgent/FloeApp/Resources/Localizable.xcstrings)

普通「聊天」与「计划」都只读用户文件，包括工作区和已授权的外部文件。模型可在回复里给出改写后的正文或建议补丁。落盘新建、覆盖、移动、删除、导入导出文件，以及能间接产生这些效果的命令、作业、委派和编辑器动作，交给执行模式。用户要求保存的记忆、澄清问题和原生计划卡归 App 自身的记录；这几种操作有各自的工具和权限。

### 智能体

在已授权的「智能体」主会话里，用户说“把上次讨论的决定整理成 Markdown，保存给我”，模型应能直接查会话、读原文、建文件、核对保存并交付。需要用户选择时可直接提问，多阶段工作可维护进度。以上步骤无需先查工具目录。需要专用工作台时，仍能通过发现工具加载完整定义。

| 能力 | 云端智能体首轮候选工具 |
| --- | --- |
| 用户交互、工具发现与结果续读（5） | `user.ask`、`chat.present`、`tools.search`、`tools.list`、`tools.readResult` |
| Skill 查询（3） | `skill.list`、`skill.search`、`skill.read` |
| 目标与进度（5） | `goal.create`、`goal.read`、`checklist.readPlan`、`checklist.updatePlan`、`checklist.resetPlan` |
| 会话与委派（6） | `conversation.list`、`conversation.search`、`conversation.read`、`conversation.message`、`conversation.spawn`、`delegate` |
| 工作区检索（4） | `workspace.listDirectory`、`workspace.searchFiles`、`workspace.readFile`、`workspace.inspectFileMetadata` |
| 文本与文件管理（9） | `workspace.createFile`、`workspace.appendFile`、`workspace.replaceText`、`workspace.applyPatch`、`workspace.writeFile`、`workspace.createDirectory`、`workspace.copyFile`、`workspace.moveFile`、`workspace.deleteFile` |
| 记忆（6） | `memory.search`、`memory.recall`、`memory.list`、`memory.remember`、`memory.update`、`memory.forget` |
| 任务成果（3） | `chat.content.list`、`workspace.importOutput`、`workspace.publishOutput` |
| 执行、等待、作业与调度（7） | `exec.shell`、`task.wait`、`jobs.submit`、`jobs.status`、`jobs.result`、`jobs.cancel`、`task.schedule` |

合计 48 个，表示候选集合。三个 `tools.*` 由运行时提供。其余名称必须存在于本轮实际可用目录中。按会话或工作区可见范围可以少于 48 个；因任务匹配或精确搜索可以多于 48 个。两个同级子任务通信工具 `delegate.peers`、`delegate.message` 继续通过子任务现有入口提供。`conversation.message` 使用运行中的目标 runID；查历史使用 conversationID，两者不能互换。选择题使用 `user.ask`。`chat.present` 用于展示内容。Linux 维护、网页、浏览器、专业查看和各工作台由任务匹配或发现提供。

### 聊天

普通「聊天」可直接回答问题、查公开资料、阅读授权文件，并按用户要求保存或修正记忆。云端聊天首轮提供以下 12 项候选，各项与本轮实际可用目录取交集。用户已贴出内容时，可以直接回答。

| 用途 | 聊天首轮候选工具 | 使用场景 |
| --- | --- | --- |
| 查公开资料（2） | `web.search`、`web.fetch` | 搜索已配置的公开来源，或直接读用户给的公开链接，核对原文。 |
| 读文件（3） | `workspace.listDirectory`、`workspace.searchFiles`、`workspace.readFile` | 已知路径就读原文。只知道目录、文件名片段或正文关键词时，先定位再读。 |
| 读取记忆（3） | `memory.search`、`memory.recall`、`memory.list` | 按问题找相关记忆，回忆已保存的偏好，或分页查看条目和 ID。 |
| 写入记忆（3） | `memory.remember`、`memory.update`、`memory.forget` | 用户要求记住、纠正或忘记某件事时，先检查已有记录，再新增、更新或遗忘对应条目。 |
| 让用户做选择（1） | `user.ask` | 需要用户在几个选项中做决定时使用。 |

`workspace.readFile` 支持 UTF-8 文本，单次最多 64 KiB，长文件按返回的 `nextOffset` 续读。上述清单覆盖 Markdown、TXT、CSV、JSON 和源代码等文本。PDF、Office 等容器的正文提取属于专用读取能力。目录和搜索沿用工作区权限，读取也沿用执行目标已有的路径授权。聊天中可以给出修改稿。保存文件、执行和作业归入「智能体」；跨会话只读调查也可在「计划」中进行。[文件读取实现](../FloeAgent/Sources/FloeWorkspace/Tools/FileReadTools.swift)

记忆可用时，普通「聊天」可以直接使用六项工具。用户说“以后默认用繁体”，同一轮应能先查已有偏好，再写入或更新。检索、操作范围和回执沿用现有记忆流程。App 注册的 `memory.search` 还会查询手记、项目、历史会话等索引来源。聊天搜索只调用现有持久记忆召回分支，继续经过记忆授权，按聊天范围生成描述；普通智能体保留现有的全来源搜索。[记忆工具](../FloeAgent/Sources/FloeAgentRuntime/MemoryTools.swift) · [App 的搜索和遗忘实现](../FloeAgent/FloeApp/Memory/GlobalSources/GlobalSourceSearchTools.swift)

聊天以输入栏模式为准，网页限制按调用设置，持久记忆沿用本任务授权。临时聊天再与现有临时权限取交集。[会话入口](../FloeAgent/FloeApp/Remote/ConversationCenter.swift) · [当前聊天提示](../FloeAgent/Sources/FloeAgentRuntime/AgentPromptComposer.swift) · [网页检索](../FloeAgent/Sources/FloeExecution/Tools/WebSearchTool.swift) · [网页读取](../FloeAgent/Sources/FloeExecution/Tools/WebFetchTool.swift)

### 计划

云端首轮提供聊天的 12 项，加下表 12 项，共 24 项。额外能力服务于需求澄清、调查和提交可执行的方案。用户说“先看上次定了什么、现在仓库改到哪了，再出一个迁移方案”，计划模式可以读已有讨论、查看差异、核对依赖、让用户选方向，然后提交原生计划卡。已知任务涉及 Git 时，状态和差异也可以在首轮按需加入。

| 计划额外首轮候选 | 工具 | 用途 |
| --- | --- | --- |
| 文件详情（1） | `workspace.inspectFileMetadata` | 核实指定路径的类型、大小或摘要。 |
| 历史会话（3） | `conversation.list`、`conversation.search`、`conversation.read` | 在已有授权范围内查找并读回以前的决策。 |
| 既有目标与进度（2） | `goal.read`、`checklist.readPlan` | 核对本任务的目标、已完成工作和待办。 |
| Skill 目录（2） | `skill.list`、`skill.search` | 找已安装的流程说明，需要正文时再按需读。 |
| 工具发现和结果续读（3） | `tools.search`、`tools.list`、`tools.readResult` | 从计划允许的目录找专用读取工具，分页读回本任务的调查结果。 |
| 提交方案（1） | `plan.submit` | 将这版方案写入原生计划卡，供用户审阅。 |

例如 `git.status`、`git.diff`、`git.log` 可按任务匹配加载。PDF、Office 等专用工具只开放经核实能直接返回内容的读取动作，生成、转换或导出文件的参数和路径归执行模式。既有 `checklist.resetPlan` 是主运行的版本化内部清单重置例外，可继续按需提供。既有 `checklist.updatePlan` 属于执行进度更新。计划草案用 `plan.submit` 提交，每个修订版提交一次；用户在计划卡上确认执行后，再按其选定的普通或目标模式启动执行。[计划准入策略](../FloeAgent/Sources/FloeAgentRuntime/PlanToolPolicy.swift) · [计划提交协议](../FloeAgent/Sources/FloeAgentRuntime/PlanningModels.swift) · [用户确认后的执行入口](../FloeAgent/FloeApp/Chat/ThreadDetailViewModel.swift)

计划可按用户要求更改持久记忆，读取 Skill 时只返回已安装的说明，资源包不会写入用户工作区。查询、分页和执行前均核验本次运行的权限。[Skill 读取](../FloeAgent/Sources/FloeSkills/SkillManagement.swift) · [运行时执行](../FloeAgent/Sources/FloeAgentRuntime/AgentRuntime.swift)

## 2. 首轮输入实测

使用源码基线 `e770526d6` 与补丁后的真实 `AgentRuntime → ProviderStreamRequest` 在本机捕获请求。样本为无历史、附件、工作区说明和个性化的新会话，用户正文为 Hello，窗口为 262,144。输入目录含上述基础工具的真实名称、描述与参数，另含公开网页搜索和读取。App 覆盖注册的两项记忆工具使用 App 描述。运行时生成发现工具和计划提交定义。测试只量发送给模型的内容，未连接供应商。

| 模式与目录 | 定义数 | 工具数组 | 系统消息 | 首轮合计 |
| --- | ---: | ---: | ---: | ---: |
| 改前，复现用户的基础样本，shell 不可用 | 13 | 3,668 | 4,782 | **8,450** |
| 改前，智能体，shell 可用 | 14 | 4,631 | 4,934 | **9,565** |
| 改后，智能体，shell 可用 | 48 | 11,509 | 3,875 | **15,384** |
| 改前，聊天，shell 可用 | 14 | 4,631 | 2,267 | **6,898** |
| 改后，聊天 | 12 | 2,733 | 1,400 | **4,133** |
| 改前，计划，shell 可用 | 15 | 5,037 | 5,228 | **10,265** |
| 改后，计划 | 24 | 4,839 | 4,025 | **8,864** |

按同一 `o200k_base` tokenizer 对系统消息正文及紧凑序列化的 function-tools JSON 分别计数。表中排除了用户正文、角色分隔符、供应商私有模板和输出预留。线上最终输入和缓存命中要看对应供应商的 usage。真实设备上，项目说明、用户资料、选中的 Skill、额外工具组和历史都可能改变结果。计划的定义数增加，工具 token 仍略降，原因包括网页参数按公开来源裁剪，以及首轮移除了 shell。

相同授权目录下，智能体首轮增加 34 项、5,819 token。与用户看到的 13 项相比，增加 35 项、6,934 token。15,384 约占 256 Ki 窗口的 5.87%。没有统一的 18 项总加载上限。完整定义仍受本轮窗口预算约束，已禁用的工具也不会因出现在基础清单中而恢复。

Floe 在选择工具时使用较保守的 UTF-8 字节估算。该算法对改前 13 项样本估算为工具 5,829、整轮 14,069，对改后智能体估算为工具 18,245、整轮 24,959。它适合防止超窗，与上表 tokenizer 的口径不同。

## 3. 实现位置与执行顺序

| 改动位置 | 运行路径和规则 |
| --- | --- |
| App 会话入口 | 从输入栏选择的执行模式冻结 Chat、Plan 或 Task。先与可用目录、工作区、临时会话、编辑器范围取交集，再建立运行配置。普通持久会话的基础记忆工具不依赖提示词出现“记忆”。聊天记忆搜索和自动召回只读取持久记忆。会话恢复优先使用已记录的模式，旧格式沿用既有持久化聊天证据。[ConversationCenter](../FloeAgent/FloeApp/Remote/ConversationCenter.swift) · [GlobalSourceSearchTools](../FloeAgent/FloeApp/Memory/GlobalSources/GlobalSourceSearchTools.swift) |
| 模式目录与实际执行 | 同一策略用于呈现、发现、直接调用、批量调用和子任务权限。公开网页仍由原网页工具执行目标与凭据检查。允许的记忆变更只接受对应的内部状态操作。聊天、计划均不允许向其他会话发送操作或委派写文件。计划的结果续读限定当前运行。用户批准计划后从现有执行入口启动。[PlanToolPolicy](../FloeAgent/Sources/FloeAgentRuntime/PlanToolPolicy.swift) · [AgentRuntime](../FloeAgent/Sources/FloeAgentRuntime/AgentRuntime.swift) · [ToolResultPagingTool](../FloeAgent/Sources/FloeAgentRuntime/ToolResultPagingTool.swift) |
| Skill 读取 | 计划按需读取已安装说明，可按偏移续读，不传可准备文件的资源上下文。搜索也只查安装目录。执行模式继续使用绑定的工作区和资源准备路径。[SkillManagement](../FloeAgent/Sources/FloeSkills/SkillManagement.swift) |
| 云端组装与恢复 | 三种模式有各自的首轮候选。完整定义先按可用预算、精确加载和当前操作决定是否入选，再按基础项在前、扩展项随后和名称稳定排序。普通任务使用紧凑组索引，具体领域的指导按需要补充。实时钟、执行前提和本轮任务指导放入动态区。受限模式恢复时重建请求，保留工具调用与结果的配对。供应商重试遇到已撤回的工具时重建。[ToolDiscovery](../FloeAgent/Sources/FloeAgentRuntime/ToolDiscovery.swift) · [AgentCheckpoint](../FloeAgent/Sources/FloeAgentRuntime/AgentCheckpoint.swift) · [ConversationRunService](../FloeAgent/Sources/FloeAgentRuntime/ConversationRunService.swift) |
| 本地加载 | 在已授权目录内，当前动作、待完成调用和刚刚精确发现的名称决定优先级。一般动作省掉工具名大全，查询能力时再附目录。完整定义装不下会整体延后。已完成的动作保留调用和回执，不占后续轮次的常驻名额。保留 Apple 工具结果后续回答和 MLX 生成前的模板预算校验。[LocalProviderAdapter](../FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift) · [LocalModelToolPolicy](../FloeAgent/Sources/FloeProviders/LocalModelToolPolicy.swift) · [ProviderAdapter](../FloeAgent/Sources/FloeProviders/ProviderAdapter.swift) |

## 4. 本地窗口与验证

MLX 按模型重量和可用内存分配固定资源档。受限档总窗口 8,192，默认输出预留 1,024，可用输入 7,168。均衡档为 12,288 / 1,536 / 10,752，宽裕档为 16,384 / 1,536 / 14,848。Apple Foundation Models 使用系统能力和现有独立后续轮次逻辑。[资源档位](../FloeAgent/Sources/FloeLocalModelCatalog/LocalInferenceResourcePolicy.swift) · [输入预算](../FloeAgent/Sources/FloeLocalModels/LocalPromptPressure.swift)

使用真实本地提示构造函数、合成上下文和 8K 档测试。12 字问候样本的组装估算为 2,283 输入 token，带回执的两次连续读文件在最后总结轮为 2,729。它们是提示构造器的预算估算。模型权重、设备推理速度和真实生成任务完成率未在本轮测量。

最终 78 项针对性检查通过，覆盖首轮实际发送的定义、超过 23 项的发现、禁用项、精确找回、聊天拒绝写入、计划提交、受限会话从旧快照恢复、只读 Skill 绕过资源准备、云端和本地的最终准入、小窗口大工具的整体延后，以及原生与 JSON 两套调用通道。固定 iPad 模拟器上的组件探针另外执行了三模式清单和读写权限断言。App 会话入口和记忆搜索已按实际 iOS Simulator 目标编译为对象。未进行带供应商账号的线上对话、完整 App 界面走查或权重推理。[云端与恢复测试](../FloeAgent/Tests/FloeAgentRuntimeTests/ToolSchemaExposureContractTests.swift) · [聊天策略测试](../FloeAgent/Tests/FloeAgentRuntimeTests/ChatModePolicyTests.swift) · [本地准入测试](../FloeAgent/Tests/FloeLocalModelsTests/LocalBaseToolSchemaTests.swift) · [Skill 读取测试](../FloeAgent/Tests/FloeSkillsTests/SkillManagementTests.swift)

## 5. 主线集成

第一个独立提交为 `b279dfa60`，负责普通云端智能体首轮。后续提交包含聊天、计划、恢复、本地适配与验证。集成顺序为基础提交、模式实现提交、本文件。345 已冻结并交付。主线可在下一未冻结候选吸收这一组提交，合入时保留共享工作区中同时进行的其他修改。
