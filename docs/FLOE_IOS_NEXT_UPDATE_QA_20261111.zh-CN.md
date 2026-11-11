# 下一轮 iOS 更新：用户 QA、实现核对与交付计划（2026-11-11）

状态：1.8.8（330）已冻结并完成内部 TestFlight、GitHub stable/latest 和 awaited Feather 交付，未提交公开 TestFlight；见[330交付记录](releases/builds/FLOE_1.8.8_BUILD330_DELIVERY.md)。该包不含新增 Linux 视频硬件解码。本批实际 App19 及测试包编译、链接通过；App17 首轮19项原有7项失败保留，App18受影响9项为8通过、1失败，最终MIDI保存/重开问题经App19单项复验通过，未变范围复用原结果。实际界面观察与组件检查分别记录，不作物理设备或完整App GPU交互已验收声明。地图根因仍待用户补充记录。

最新用户反馈与顺序：330仍有传感器、计时器、三份化学文件批删 `Unauthorized` 和生物回收站剩余项问题。先完成这四类 hotfix 及相关真实 App 验证，尽快交付新的中间内测，不等GPU／新增Linux视频硬件解码；暂选1.8.9（331），尚未冻结或交付。后续支持硬解的完整版本再公开 TestFlight，Build315不改。以下原分包计划和既有通过证据保留，不能据330交付自动结清这些新反馈。

本轮以 App 的实际 UI → 会话/工具 → 服务 → 原件存储为依据。修复前基线核对来自 `main` 源码 `b491d2533117633d7a8e9aa1e5a80f7c490e25a9`，源码预研发起点为 `6f93d7ff7bb9f9e92f835934a4ec4864635f4fb9`；已交付标签 `v1.8.7` 指向 `1f7fa8889a8e7bac26e4484ae2aafac5c54c51c0`，基线核对时关注的生物、音乐、会议、聊天界面路径与该标签无源码差异；这一结论不覆盖正在修改的工作区。静态代码发现、用户实机报告、本轮运行复现和修复验收分开记录。

本文件接续 [11 月 9 日需求 QA](FLOE_NEXT_ROUND_REQUIREMENTS_QA_20261109.zh-CN.md)，保留 RQ08（音乐）、RQ17/RQ21（地图）的原始身份。用户本轮“流程图改为思维导图”更新旧 RQ19 的命名决定。旧组件宿主、编译或历史 UI 成绩不作为本轮 App 故障已修复的证据。

## 1. 已确认的产品规则

| 项目 | 本轮结论 |
| --- | --- |
| 文件任务收纳 | 任务中心有单独的文件任务区域，默认收起；进行中仍在外部全局运行区域显示。待用户处理的审批/失败仍有全局可发现入口。归类依据真实文件归属，不匹配标题。 |
| 文件任务持久性 | 同一文件继续同一持久会话；关闭编辑器、折叠助手、一次回答结束都不销毁会话。运行是否结束与会话是否保留是两个状态。 |
| 删除文件及其任务 | 用户已确认：先停止这个文件自己的运行任务，再随文件一起清理关联对话；删除失败不能先丢对话。沿用现有回收站设置，恢复和最终清理需要同属一个文件生命周期。普通任务仅引用过文件时不因此被删除。 |
| 引导/排队 | 用户已确认：普通聊天和所有文件编辑器使用通用设置；空闲直接执行，运行时才按引导/排队处理；尚未消费的单条消息可通过三点菜单双向切换。已经送入模型的内容不能伪装成撤回成功。 |
| 生物工程范围 | 用户要求尽量多完成，包含恢复 DNA 3D、可用 AI 助手、无需先导入的空白编辑入口。已进一步确认：先支持从空白创建序列、注释、网络，3D 恢复显示、选择和编辑已有结构；本轮不扩展到从零手动搭建三维原子/键。以已有实现逐项补闭环，新增能力单列。 |
| 音乐录制 | 用户撤销误触的“伴奏默认关闭”，要求由工程调查成熟录制行为。计划采用统一播放头/时钟：从当前播放头录制，已有未静音音轨同步播放，默认保留原内容并新增录制片段。输入监听与已有音轨回放独立控制。 |
| 地图重点 | 用户明确主要问题是图层导入，以及 AI 未通过实际画面判断图层覆盖关系。诊断记录待补；导入、编辑、保存、导出和 AI 回写整链仍在范围内。 |
| 绘画界面 | 手指绘画保留为明确开关，移出独占一整行的主要画布区域，放入工具选项/输入方式入口；鼠标/Pencil 编辑、手指默认导航的既有规则保留。整体整理工具层级、画布空间和侧板收放。 |
| 命名 | 用户指定入口改为“思维导图 / Mind Map”，相关新建菜单、标题、文件类型名称和 AI 描述同步；保留既有文件标识和格式兼容，不合并不同编辑器的状态。 |
| 会议 | 尽量实时呈现说话人 1/2，录后校正，可改名和合并。录音以一条连续记录呈现；内部切块、重试队列不作为普通用户操作流程。 |
| 编辑器内部删除 | 本轮覆盖各编辑器添加对象后的删除入口、真实删除、撤销/重做、保存重开和关联引用处理。文件列表删除与编辑器内部对象删除分别验收。 |
| 化学异常退出 | 无坐标/加载失败的对象不能锁住整个工程；保留可恢复内容，允许移除问题对象或安全离开。未发生编辑的加载失败不能冒充未保存修改。 |
| 文件助手中断恢复 | 用户新增：各文件助手容易中断，继续/重开后难以恢复；同一持久会话必须可以从安全边界恢复，保留已完成结果、原件和新输入。恢复进行中、等待用户继续和恢复失败各有准确状态，不让用户反复点击同一个无效恢复入口。 |
| 已交付产物的完成判定 | 用户实见 40 张图已经返回，但末尾出现 `recoveryPointPersistenceFailed` 和任务未完成。生成/交付结果、最终持久提交和可选进一步核验分别判断；已修正的参数尝试不能永久被当成当前待完成工作。恢复点保存问题必须保留准确诊断，不应让用户重做已成功交付的图。 |
| 模型主动等待 | 用户新增：模型可以主动等待指定秒数再继续。采用可取消、可恢复的原生运行工具，遵守既有后台/运行所有权和消息引导规则；等待期间显示真实状态，不用模型空转或忙轮询计时。 |
| Mac Bridge 间歇兼容错误 | 用户明确 Mac Bridge 是 1.1.3（当前最新版），主要在执行任务或传输文件时仍间歇提示兼容错误。优先核对命令/传输返回体、分页及错误响应，同时保留连接/协议回归；尚无证据确认具体根因。 |
| Traceroute 实时结果 | 用户新增：逐跳实时显示结果，超时也显示；可停止并保留已有跳点，不等全部结束才展示。覆盖原生网络工具箱及实际使用的工具输出路径。 |
| IP 信息库 | 用户新增：把 IP 信息库真正接入诊断结果。每跳地址独立补地区、ASN/网络归属等实际可用字段，查询不阻塞探测；标明来源/版本，缺失与本地/保留地址如实显示。 |

## 2. 当前实现核对

以下是修复前基线的源码事实或明确标注的推断，均不等于本轮已完成 App 复现；实施后的结果另按组件和 App 层记录。

| 编号 | 当前事实 | 实际路径 | 仍需核实 |
| --- | --- | --- | --- |
| T01 | 文件助手创建、重开都会调用 `setArchived(...true)`；文件归属在独立的 `document_assistants` 表。任务中心按普通会话及运行状态分类，并另读全部归档，缺少文件来源分区。 | `Space/StudioAgentTools.swift`、`Space/StudioDocumentAccess.swift`、`Home/HomeOverviewView.swift`、`Home/HomeLaunchpadViewModel.swift` | 文件助手、Notes/Office 助手等不同入口的真实归属覆盖及活跃任务投影。 |
| T02 | 文件软删/永久删除经 `PersonalLibraryFileActions`；会话删除经 `ConversationCenter`，属于不同存储与生命周期边界。 | `Space/PersonalLibraryFileActions.swift`、`Space/PersonalLibraryPermanentDeletion.swift`、`Remote/ConversationCenter.swift` | 所有助手归属的删除/恢复联动、崩溃恢复、旧孤立记录；不能假定跨存储天然原子。 |
| T03 | 通用模式在 `ThreadDetailViewModel` 加载时读取；发送分流依赖 `isRunning`。队列三点菜单只有“转为引导”，没有“转回排队”。运行中输入已有 `withdrawPendingGuidance` 和 `restoreQueued` 机制可复用。 | `Chat/ThreadDetailViewModel.swift`、`Chat/ThreadDetailView.swift`、`Remote/ConversationCenter.swift` | “每条消息都等待安全点”的实际运行状态/服务归属与设置更新；不能仅修菜单文字。 |
| T04 | 已核对上传诊断：多个文件工作流出现网络中断，其中部分随后在同一 run 内继续执行原生工具；另一次手动继续能读出 v5 checkpoint，之后先发生模型流提前结束，再次继续得到接口参数拒绝。源码另有明确覆盖缺口：Studio 文件助手强制归档，而 `resumeSafeRunsAfterForeground` 遍历的 `conversations` 来自排除归档的查询。 | `Space/StudioAgentTools.swift`、`Remote/ConversationCenter.swift`、`Sources/FloePersistence/ConversationStore.swift`、`Sources/FloeAgentRuntime/AgentRuntime.swift` | 短暂断线重试、前台恢复、手动继续、重新打开编辑器和进程重启分别验证；日志不能把所有中断都归为 checkpoint 丢失，也不足以确认具体无效字段。 |
| F01 | 用户截图中三份化学工程批量删除均报 `Unauthorized`。化学删除会打开原件、flush、处理宿主计算记录，非终态尝试会调用 `cancelNative` 并恢复原任务身份。 | `Space/Chemistry/ChemistryProjectSession.swift`、`Space/Chemistry/ChemistryEnvironmentJobAdapter.swift` | 具体拒绝点需结合对应原件和诊断；不直接绕过授权或停止证明。 |
| M01 | 钢琴 MIDI 录制使用 `midiStart`/host time 计算音符；`playbackPosition` 只读取播放器或静态播放头。UI 时间更新暂停条件也只看播放，不含录制。`startMIDIRecording` 没有启动已有编曲；麦克风录制拒绝 `isPlaying`。 | `Space/Music/MusicProjectSession.swift`、`Workbench/Music/MusicWorkbenchView.swift` | 实际混音路由、首帧、tempo/loop、监听与延迟；按钮会动不等于录音对齐。 |
| G01 | 新建导入与工程内导入走不同宿主入口，最后进入同一 HeavyEditor `file.import`。GIS 原生面板已有图层顺序/透明度、图层删除、要素删除。AI 工具可查询、执行、导入、导出；宿主返回 JSON 和产物引用，未见专用当前地图截图→模型图片输入的闭环。 | `Space/GIS/GISProjectImport.swift`、`Space/GIS/GISProductionTools.swift`、`Modules/FloeHeavyEditorSupport/.../ToolSession.swift`、`Modules/FloeGISKit/.../GISNativePanels.swift` | 导入出错样例、坐标/投影、栅格配准、图层覆盖和实际多模态请求；等待用户地图记录。 |
| D01 | 绘画使用的 `MediaFingerDrawingToggle` 固定内容尺寸并保留至少 44 点高度，当前画布控制区把它单独放进一行。 | `Workbench/MediaDrawingInputPolicy.swift`、`Workbench/MediaV2/MediaV2Workspace.swift`、`Workbench/WorkbenchImagePreview.swift` | iPad 横竖屏、窄分屏、iPhone 和键盘出现时的实际布局。 |
| B01 | 结构 3D 默认 `backbone`，仅筛选非 hetero 的 `CA`；没有 Cα 会直接报无法显示。原子/带状模式仍在，序列素材只进入序列视图。 | `Modules/FloeBiologyKit/.../ScientificViews.swift`、`NativeScene.swift`、`BiologyWorkbench.swift` | DNA 旧样例和旧版本的完整路径；核酸原子坐标模型与纯序列的可视化需分别处理。现有 Cα 条件是高度吻合的故障点，不先声称唯一根因。 |
| B02 | 新建生物工程只创建空工程；添加菜单只有“导入文件/离线示例”，选中素材后才能打开现有编辑器。 | `Space/PersonalContentService.swift`、`Modules/FloeBiologyKit/.../BiologyWorkbench.swift`、`Service.swift` | 空白编辑的合法草稿状态和各类型创建能力；不能用导入假文件模拟原生新建。 |
| B03 | 生物组件内助手是独立 Form：本地一份 prompt/reply，等待整个 `requestAI` 完成后显示最后回复。宿主直接取默认模型并 `startRun`，没有沿共同聊天输入使用引导/排队、流式工具展示等。外层另有通用文件助手入口。 | `Modules/FloeBiologyKit/.../BiologyWorkbench.swift`、`Space/Biology/BiologyProjectSession.swift`、`Space/StudioAssistantView.swift` | 不可用的具体错误、两入口模型/归属/运行冲突、真实工具发现与执行；保留配置错误和工具失败原始证据。 |
| E01 | 生物底层已有 `asset.delete` 事务和运行中素材保护，当前资料列表未连接删除菜单；化学有原子/键擦除，与删除整份对象不是同一操作。GIS 部分删除已存在。 | `Modules/FloeBiologyKit/.../ServiceOperations.swift`、`BiologyWorkbench.swift`、`Modules/FloeChemistryKit/.../NativeChemicalCanvas.swift` | 逐个真实添加对象检查，区分“缺入口”“入口不可达”“删除后未保存”，不把全 App 一概判为完全没有删除。 |
| C01 | `NativeDrawingSession.load` 失败标记 `.failed`；`ChemistryEditorState.hasPendingEdits` 无条件将 `.failed` 算作待保存；关闭调用 `flushForClose` 后直接拒绝离开。加载失败且没有 dirty 数据时 flush 也不能解除这个标记。 | `Modules/FloeChemistryKit/.../NativeDrawingState.swift`、`EditorState.swift`、`Space/Chemistry/ChemistryProjectSession.swift`、`Space/PersonalContentEditor.swift` | 用无坐标对象重现具体触发路径，兼顾真正的未保存绘图/文本，不通过直接忽略 flush 修复。 |
| A01 | `TimedSpeechSegment` 只有时间、文字、词级信息，没有 speaker 字段；实时切块和导入转写写入 `appendFinal` 时未传 speaker，界面显示“说话人未识别”。 | `Voice/FileSpeechTranscriber.swift`、`Space/Meetings/MeetingLiveTranscription.swift`、`MeetingProjectSession.swift`、`MeetingTranscriptPanel.swift` | 当前可用转写/说话人分离后端，跨块身份保持、重叠语音及录后校正。不能仅把所有空身份改名“说话人1”。 |
| A02 | 底层已同时写一份连续无损原件和独立 AAC 转写块，轮换块不重启麦克风；普通会议页仍显示下一块收集、待处理块数、片段重试/停止等内部状态。已有 `visibleRecordings` 过滤部分内部分析会话。 | `Modules/FloeMeetings/.../MeetingPCMChunkRecorder.swift`、`Space/Meetings/MeetingProjectView.swift`、`MeetingLiveRuntime.swift` | 重点修呈现、跨块时间戳和回放连接，复用既有连续原件；暂停恢复与最后尾段仍需实测。 |
| P01 | 已按截图请求身份匹配 Build329 的实际上传诊断；脱敏结论为方舟 `ark-code-latest` 的后续带工具请求返回 HTTP400 / `InvalidParameter`，上游 `param` 为空。 | 用户截图、私有上传证据；`Sources/FloeProviders/` 及运行请求链 | provider/model 已核实；具体字段尚无证据，需要重建最小失败请求，核查工具目录、历史配对、多模态和适配参数。不能直接判为图片故障。 |
| T05 | 已匹配新增 Build329 上传：图表任务报告流式恢复点失败，中间之后仍有多次 SQLite checkpoint 保存成功，末尾又失败并转为 failed。代码把一次恢复点错误存入 `durabilityFailure`，后续成功不会消除它，终态提交又受该标记限制。 | `Sources/FloeAgentRuntime/ConversationRunService.swift`、`SQLiteRunCheckpointStore.swift` | 最后一次失败在保留日志窗口内没有后续成功；当前错误日志不含底层异常，需补域/码/阶段/边界代次并复现，不能假定只是磁盘、容量或旧错误残留。 |
| T06 | 当前完成门禁以工具名+完整参数指纹识别同一次工作。参数修正后指纹改变，旧失败仍使 `hasNonSuccessfulWork` 为真。已编译当前实际 `TaskClosureGate` 做合成回执探针：所有步骤完成、修正参数后成功、答案说明图已返回，仍得到 `reportUnfinished`；相同指纹后成功则允许结束。未知副作用对照仍被阻止。 | `Sources/FloeAgentRuntime/TaskClosureGate.swift`、`AgentRuntime.taskClosureFacts`、`finishOrSteer` | 这是本轮策略组件复现，未等同完整 App 复现；真实 40 张产物需按回执/输出身份核对，不能用聚合成功调用数替代图表数。 |

截图补充对照：底部“本轮仍有未完成事项，执行已停止。进度与工具结果已保留…”与已交付 `v1.8.7` 的 `AgentRuntime.finishOrSteer` 中 `.reportUnfinished → failRun(recoverable: true)` 唯一文案一致，进一步指向完成门禁失败路径。恢复点错误与门禁决策需分别诊断；聚合的 7 条失败仍不足以确定逐调用的类型、责任及纠正关系。

路径均相对于 `FloeAgent/`。省略的模块中段仅用于阅读；实施时使用实际文件，不以本表作为完整目标清单。

## 3. 实施包与用户可验收结果

### W1：文件任务、消息调度与中断恢复

- 从真实绑定解析文件任务，复用现有会话、任务和存储；文件区域默认收起并显示计数，可搜索/按文件类型筛选。运行/等审批任务在全局可达，结束回到文件区域，避免重复计数和长列表。
- 点击文件任务优先返回对应文件及其助手；文件在回收站时说明恢复入口。会话归类与归档语义分离，不继续借“强制归档”代替归属。
- 关闭重开保留同一 conversationID、消息、模型/权限选择；不因面板重建产生新任务。
- 统一空闲/运行/等待审批/等待依赖/终态判断与真实服务归属。通用设置作用于所有文件助手；单条引导与排队可双向变更，运行结束边界不得丢消息、重复发送或永远等待安全点。
- 旧文件助手按保存的绑定迁移，不按中文标题识别；旧记录检查和恢复必须幂等，不能全量复活旧运行。
- 修复文件助手被归档排除出前台恢复候选的问题。恢复候选从真实文件/会话/run 归属解析，不沿用普通侧栏可见列表；仍遵守用户恢复策略、原件存在性和任务取消/删除边界。
- 统一网络短暂重连、重试耗尽后的手动继续、退出再进及冷启动恢复。正在安全重试时显示重连状态及停止入口，已经停止时显示可执行的继续入口；历史错误不遮蔽后来恢复成功的状态，也不把仍有活跃 owner 的任务再次启动。
- 手动继续保留同一 run、已完成工具回执和持久会话，重新核对当前原件/选区/修订、环境及权限。对结果不明的写操作先核实实际状态；不通过重发整段用户请求重复编辑/导出/外部写入。
- 本次日志已证明 checkpoint 可读而后续 provider 请求再次失败；这条路径与 W9 联动排查冻结请求重建、工具调用/结果配对、模型/工具目录兼容。参数错误不能靠无限重发同一请求解决；需要明确错误、可修改的恢复路径和保留进度。
- 所有文件内的独立助手入口都纳入恢复对齐：Studio 通用助手、Notes/Office、Canvas、地图、制谱/字体及生物的内置入口。关闭面板与用户明确停止分开；尤其检查生物组件本地助手在 `BiologyProjectSession.close` 中主动取消 `aiRuns` 的行为，避免与已选“后台继续”策略冲突。

验收：同一文件反复打开仍为同一会话；大量文件任务不撑开普通任务列表；文件任务启动、审批、完成时正确移动；引导/排队两向操作和重开显示一致；空闲消息直接执行。新增恢复场景：流在首字前/回答中/工具结果后断开，自动重试成功或耗尽，断线后切前后台、关闭重开文件及重启 App；普通聊天与文件助手在相同策略下行为一致，已完成写入不重复、队列不丢失、无法恢复时能继续操作文件。网络重连使用可控 transport fixture 验证，实际 App 验证恢复入口、同一原件及结果回读，不依赖反复消耗真实模型调用。

预研发状态：真实绑定、任务分区及消息模式策略已进入源码；初版组件宿主 10 项测试通过。最终复核纠正了运行/失败文件任务仍重复出现在文件区域的问题，补强跨区域唯一性后，相关 4 项测试通过。已补文件名搜索、类型筛选和重新校验绑定后返回原件并展开助手的源码候选；这批 App 会话中心、设置订阅和路由界面尚未完成对象编译或运行验收，删除包的可见性衔接也须合流验证。

### W2：文件删除与化学退出（阻断项优先）

- 修复截图中 `Unauthorized` 的实际拒绝点。原生文件管理授权与历史模型 run 的寿命分开，不以陈旧 run 的授权状态永久锁住用户自己的文件；仍须证明它的 worker 已停止。
- 沿已有文件屏障停止这个文件的准备/运行/保存/计算，校验归属后提交删除及会话清理。跨存储通过可恢复的生命周期记录衔接，保留中断后的重试/对账；不宣称两个独立数据库存在天然原子提交。
- 回收站开启时文件及专属会话共同隐藏/恢复；永久删除时清理该文件专属对话、授权和运行引用。失败原件和未确认停止的工作保留，批量删除逐项报告真实成功/失败。
- 化学绘图状态区分加载失败、无坐标待准备、真实 dirty、保存失败和保存成功。无实际修改的加载失败可直接退出；真正的 dirty 内容可保存为恢复草稿、重试或明确放弃后退出。移除坏对象可恢复，不强制先生成 3D。

验收：单删/批删/删除文件夹、回收站开关、恢复、永久删除、删除时运行、过期任务绑定、停止失败及中断恢复；无坐标对象进入 2D/3D 后均可离开，已有内容完整。

早期预研发状态（保留原记录）：化学对象移除的 7 项定向测试、真实编辑器状态的 5 项测试，以及提交跟踪的 4 项测试已通过。后续原生探针证实“坐标集数量为零”不代表没有当前三维坐标，已修正此误判并保留无坐标/二维绘图的计算保护；Core 17＋Engine 25 项全部通过，原 3 项失败记录保留。Core 与提交跟踪均完成真实 iOS Simulator 对象编译。

330实测后重新打开：用户仍报告三项化学文件批删 Unauthorized，以及生物回收站清理残留。已用真实Foundation／路径guard复现化学 `/var` 与 `/private/var` 二次标准化拒绝；生物可信存储根的冷热目录身份也有原生失败及窄修复。定向原生路径、真实purge及同事务中断恢复检查已通过，仍保留根归属、链接拒绝、CAS和停止证明。两条真实Files／Trash App回归已追加，尚待主线统一运行；canonical只读副本不包含截图中的精确生物剩余项，不能宣称已取得物理该项的具体抛错点或已完成用户验收。

### W3：各编辑器内部对象删除

建立“添加对象 → 选中 → 删除入口 → 实际存储变化 → 撤销/重做 → 重开”矩阵，先复用存在的真实删除命令，再补缺入口/服务。统一触控菜单和适用的 Delete/Backspace；不把隐藏当作删除。

| 实际编辑器 | 需要逐项盘点的对象 |
| --- | --- |
| 绘画/图像/视频 | 图层、笔画/路径、文字、遮罩、素材、轨道、片段、关键帧 |
| 音乐/制谱/DJ | 乐器/音频轨、片段、音符、控制点、素材引用、谱面对象、deck 装载素材；删除引用与删除原始文件分开 |
| 地图 | 图层、点线面要素、顶点、书签、导入素材；检查已有命令的可达性及撤销 |
| 生物 | 数据素材、序列记录/注释、结构选区、网络节点/反应、分析结果引用；运行中的输入先停止对应工作 |
| 化学 | 整份分子/反应/谱图对象、文档块、原子/键/标注；失败/无坐标对象也可移除 |
| 思维导图/混合画布 | 节点、边、分组、页面、附件/引用，不误删外部原件 |
| CAD/电路/文档/LaTeX/会议 | 按已有真实模型核查实体/特征及依赖、元件/连线、插入对象、附件、录音/转写/待办。保留现有领域相关保护，不引入一套泛化删除绕过它们 |

每个缺口保留自己的对象身份与复现步骤；删除选区后不保留悬空选中状态，撤销应恢复对象及必要引用，保存重开结果一致。

### W4：音乐统一录制与播放（接续 RQ08）

已核对 [Logic Pro for iPad 录制流程](https://support.apple.com/en-mide/guide/logicpro-ipad/lpip1f3b2684/ipados)和[输入监听说明](https://support.apple.com/en-mt/guide/logicpro-ipad/lpip973d59e0/ipados)：从当前播放头开始录制，输入监听是独立控制。本轮保留原片段并新增录制的默认行为来自 Floe 已确认的产品规则，不能把其他软件的覆盖录音默认值直接照搬过来。

- 对齐工程 transport、录制时钟、UI 播放头和音符/音频片段落点。录制从当前播放头开始，时间轴与录制可视反馈同步推进；空工程也前进。
- 默认播放工程中应可听到的已有轨道作伴奏，遵守 mute/solo、速度和循环；新演奏默认新增片段，保留原有内容。录制轨、监听和回放的信号归属清楚，不把伴奏重复录进 MIDI 数据。
- 区分合成器试听、编曲回放、录制监听、谱面试听和 DJ 独立 transport；工程控制与试听控制的关系明确，停止/关闭不遗留另一播放器。不会因“统一”而把独立 deck 的时间硬套到编曲时间轴。
- 麦克风录音加入工程位置和回放链，明确输入监听、耳机/扬声器路由、开始/结束尾音与中断恢复；先核实实际音频服务可行性，再确定组件边界。

验收：无/有伴奏、非零播放头、已有 MIDI+音频轨、mute/solo、tempo、循环、停止和中断、编辑删除、保存重开、回放及导出相互一致。定量时序用真实采样/事件比对，不只看播放头动画；实体音频延迟单独标注。

参考：Apple 的 [GarageBand 触控乐器录制](https://support.apple.com/en-qa/guide/garageband-ipad/chs392846e9/ipados) 使用同一播放头产生可编辑录制区域；[Logic Pro 音频设置](https://support.apple.com/en-me/guide/logicpro-ipad/lpip67576fc5/ipados) 明确区分轨道回放和输入监听。上述是行为参考，不代表当前 Floe 已达到同等功能。

预研发状态：钢琴/MIDI 与麦克风已接入共同播放头和伴奏 transport；循环按整轮提前排程，实际首帧位置贯通到录制片段，各轮 take 保存为原件资产并支持重新选择。已修复非零起点重复偏移、长音频排程、循环静音帧长及录音失败恢复；源码已合入共享主工作区。原生组件 47 项、循环时钟 6 项通过，收件修正的相关测试组 13 项通过，最后局部修正后采集与恢复 7 项通过；这些结果包含复用，不能相加成独立测试总数。主线 App17 已完成新接入及测试包的实际 iOS 编译、链接，新的 App 用例和界面验收继续；设备音频路由、延迟、多播放器对齐及循环听感尚未验证。

### W5：地图导入与 AI 视觉闭环（接续 RQ17/RQ21）

- 用用户补充的诊断和素材区分：新建地图导入、向已有地图加图层、聊天文件导入、带配套文件的格式及 AI `fileID` 解析。失败提示指出实际缺项；失败不留下无法删除的半图层。
- 读取图层范围、CRS、栅格地理配准、顺序、透明度、可见/锁定等结构信息；没有地理位置的图片需要明确定位/配准流程。截图用来检验显示，不能替代坐标系和范围的验证。
- 给现有 GIS 工具链接入受文件/修订/选区约束的真实地图图像观察能力，验证图片确实进入所选视觉模型请求。可以按需看单层/组合层及导入前后视图；不采用另一个无关窗口截图。
- 需要判断覆盖/遮挡的任务，执行“读结构 → 看图 → 修改顺序/透明度/配准 → 再看图 → 保存回读”。不根据文字成功回执宣布覆盖正确，也不对每条普通消息自动重复截图。
- AI 修改与手动编辑共享同一原件、历史和 revision 冲突边界，结果回到同一文件。

验收：以实际故障样例加有明确已知重叠/偏移/顺序的合成图层；手动与 AI 两条入口都完成导入、观察、修正、撤销、删除、重开及真实格式导出。

预研发状态：导入 CRS 与配套文件检查、图层结构证据、真实视口观察及验证图片进入既有模型请求通道已落源。GIS 42 项、输入 39 项、标签 4 项检查通过，保留的 iOS Simulator 模块对象已核实；独立原生 WK 宿主完成保存重开、导出与两个视口观察。主线另完成 3 项实际 App 边界测试；这些证据仍不代表完整地图交互或真实视觉模型的完整验收，用户提及的诊断样例仍待补充。

### W6：生物工作台恢复和创作闭环

- 恢复核酸 3D 路径：检查旧版本与原数据；有真实坐标的 DNA/RNA 不依赖蛋白 Cα，自动选可显示的表示并能切换/旋转/缩放/复位。蛋白、核酸、混合结构分别覆盖；链/模型选择与原子选择不失效。纯序列与真实三维坐标模型分开，任何理想化结构都须明确其来源与含义。
- 新建直接进入可工作的空白工程，提供原生创建/粘贴序列、注释和网络的完整路径，空白草稿能保存、重开，AI 可在空工程开始工作；不强迫先导入示例，也不只增加一个无编辑能力的“空白”按钮。按用户本轮选择，3D 恢复显示、选择和编辑已有结构；从零手工搭建三维原子/键不纳入本轮。
- 生物 AI 复用同一文件的持久助手与通用模型/运行/工具 UI，不再另开只有一次回复的简化入口。串起模型选择、流式回复、真实工具发现/调用、取消、排队/引导、执行结果和返回原件，失败有可用的错误/重试路径。
- 接回已经存在的序列编辑/注释/统计/互补/翻译/比对/ORF，结构查看/测量，显微通道/切片/测量，表达矩阵处理，反应网络编辑/模拟，系统树和密度视图；按实际服务和 native/Linux 后端列出“已有且可达、接入缺口、确实缺实现”，尽量完成可独立验证的完整工作流。
- 加资料删除、重命名、撤销/恢复及持久化；已有底层 `asset.delete` 先接真实 UI。保持大文件原件引用、worker 生命周期、运行输入保护和既有授权。外部模型/后端不因开发者未付费测试而封禁。

验收：从空间新建的真实空工程出发，手动建内容、AI 从零建立内容、编辑、删除、撤销、保存重开、导出；另用带核酸坐标的数据验证 3D。已有各数据类型各走一条端到端代表流程，并对本次实际修改的领域计算做定向数值/契约检查。

预研发状态：空白序列/网络创建、资料删除、DNA/RNA 与混合结构主链显示已进入源码；71 项组件测试无失败，含 1 项既有 Python 条件跳过。已有结构新增移动/旋转入口，可作用当前模型/链或选中原子，冻结打开时的修订并接回撤销；新增 2 项数值、并发与保存重开测试通过。共享助手先异步校验当前资料，再显示对话面板；失效资料不进入助手，界面重绘不触发选择写入。修改后的 UIKit/SceneKit 模块及新增表单均完成真实 iOS Simulator 对象编译；主线另完成 3 项实际 App 边界测试，完整编辑、三维交互及真实助手任务仍待相应界面验收。

### W7：会议连续录音、转写和说话人

参考 [Google Recorder 说话人标签流程](https://support.google.com/pixelphone/answer/16269004)，真实声音区分后再允许改名/重新归属；能力可用性需要实际后端支持。[Volcengine 官方分离说明](https://docs.volcengine.com/docs/doubao-voice/speaker-separation?lang=en)区分流式与文件接口参数；不能只在 UI 生成标签冒充区分。

本次源码核对还发现云端路径在 `CloudASRFiles.swift` 和 `AssistantAudioService.swift` 两次重建转写片段，均只保留时间和文字。W7 必须打通共享 ASR 类型、提供商解析、文件切块映射及会议存储，不能只增加界面标签。

- 普通界面只显示连续录音的时长/波形、录制/暂停/继续/结束、转写进度和可操作失败；内部音频切块、采集片段数、逐块调度隐藏在显式诊断详情。
- 保留分块存储/恢复机制，合并时间线与播放体验。暂停继续仍为同一次录音，文字时间戳定位到正确位置；最后尾段和失败重试不丢失、不重复。
- 为真正的说话人分离接入能力及数据字段，维护一次会议内稳定的身份，跨块映射而非每块重置；尽量实时标记说话人 1/2，结束后校正。提供改名、合并和必要的纠正入口，人工纠正不能被迟到结果覆盖。
- 后端在不同请求/重连后返回的相同编号，不能单凭编号认定为同一人。优先保留连续识别会话，录后依据整份原始录音的真实区分结果校正；不把独立片段的“1”直接全局合并。遵守已有识别引擎选择及音频上传授权，不能因本地引擎不支持区分就悄悄改用新的云服务。
- 普通转写后端不提供分离时如实显示可操作的状态，继续保留录音和转写；不伪造 speaker，也不让全屏长期重复“说话人未识别”。
- 检查会议助手能够访问当前会议笔记、连续录音及转写，并把可追溯结果写回同一会议。

验收：单人、多人轮流、跨切块的同一人、短暂停顿、暂停继续、重叠讲话、停止尾段、重开、录后校正、人工改名合并、回放定位及导出；中文、英文和混合语音分别保留证据范围。

参考：Apple [语音备忘录录制流程](https://support.apple.com/en-hk/guide/ipad/ipadf455678zz/ipados) 以一份录音提供暂停/继续/回放；[Notta 说话人说明](https://support.notta.ai/hc/en-us/articles/4403163792027-Does-Notta-support-speaker-identification) 区分匿名编号和未识别，并说明分离能力依赖录制方式和语言。Floe 的后端选择以实际能力为准。

预研发状态：真实说话人字段、提供商 opt-in、人工改名/合并/更正及普通界面隐藏分段已落源；录后拆并、历史引用和旧数据兼容已完成前包验证。连续 PCM 已接到用户所选且支持实时识别及区分的服务，识别请求域、停止尾段、人工归属和原音来源均保留。组件 73 项、适配器 34 项通过；本地收件又修复提交/撤销原子边界、离散覆盖与真实补转写区间、PCM 帧坐标、尾帧记账及同句修订的人工归属保护，相关 15、3、2、3 项定向检查通过（含复用，不相加为独立总数）。最终模块 iOS 26 目标、SDK 27.2 对象及主线 App17 编译、链接通过；7 项新 App 用例的执行和实际界面仍由主线验证。20 MiB 换域预算是当前 App 策略，尚不是官方接口总量限制；跨请求不猜同一人，真实多人及长会议效果仍待验收。

### W8：绘画空间与名称

- 手指绘画改为工具选项中的紧凑开关，保留启用状态和 VoiceOver 名称/值；同页不再重复占位。工具、图层/属性和助手面板各有稳定收放入口。
- 集中检查一轮 iPad 横竖屏、窄分屏及 iPhone：画布可用面积、顶部遮挡、底栏、键盘和主要操作可达；保持原生风格和最小触控面积。
- “流程图”入口统一更名“思维导图 / Mind Map”；核对新建、文件列表、编辑页、帮助/工具描述与搜索，保留数据兼容。

### W9：新增模型参数拒绝

- 已读取并匹配用户上传的对应诊断，核实 Build329、实际 provider/model 和请求阶段；原始日志、请求身份、上传编号及完整传输记录仅保存在私有证据区。当前证据不足以确认具体无效字段。
- 对照真实请求构造与现有适配检查：动态工具目录及名称/schema、历史工具调用配对、多模态/图片内容、空字段和 provider 专有选项。只有证据支持后才缩小到具体字段。
- 用脱敏最小请求或契约 fixture 复现并修复；不把移除全部工具/禁用图片/重复重试作为通用修复。必要时补 run/请求身份关联和参数形状摘要，不记录消息正文、图片字节或凭据。保留原始错误及请求身份，用户界面显示简短可行动错误，技术 JSON 留在详情。

验收：本次故障阶段的定向回归，包含工具发现后继续、空/有图片消息、合法图片/图表返回及重试边界；配置后端的实际调用证据独立于本地 fixture。无凭据/原始私有请求进入公开资料。

### W10：产物已交付后的完成判定与恢复点保存

- 将本次“40 张图已返回却判未完成”作为独立回归。以实际已生成的图表/文件回执、交付引用和用户要求核对完成情况；可选逐图像素核验没有执行时应准确说明，不自行变成额外必做工作。
- 把先前被拒绝的参数尝试与修正后的成功结果关联到同一工作目标/产物身份；保留失败历史，但完成判定读取当前未解决工作，而非所有不同参数指纹上的历史失败。保留真正缺产物、未完成步骤、拒绝未解决和副作用结果不明的校验；不能仅凭助手自报完成或勾选清单判成功。
- 恢复点写入携带一致的边界/代次和原子快照，核对流式定时保存与工具状态变化、前后台切换、结束收尾的交错。诊断记录实际异常类别和代码，区分快照一致性校验、编码、数据库暂停/写入和归属变化，不能只留下通用错误 token。
- 成功写入确实覆盖失败边界后，通过经验证的状态解除对应保存故障；旧代次/更早快照的成功不能覆盖较新的真实失败。最终回复、产物证据和终态提交的持久性仍须真实确认。
- 若产物已经持久交付而仅恢复元数据异常，应准确保留产物及完成情况并单列恢复限制；若关键持久提交尚未成功，明确指出哪一项未保存并允许只修复收尾，不重复创建已有图/文件。普通界面不直接展示 `recoveryPointPersistenceFailed` 内部名称。

验收：先失败后同一目标改参数成功、真实未解决失败、未知副作用、可选核验未做、临时保存失败后新快照成功、最后一次保存仍失败、流尾与定时保存交错，以及前后台切换后的同一任务。复现用户的批量图表流程，核对产物数量/身份、历史错误、最终回复和任务状态；现有合成策略探针仅作为初步问题证据，修复后仍需相关编译、定向契约及实际 App 回读。

预研发状态：原子快照捕获、写入串行及持久代次已进入源码候选，相关 58 项定向检查通过，包含四项持久化故障注入及实际执行后取消的回归。新快照并发测试另修正了暂停信号并重验；补充全套中的其他失败仍保留、尚未归因。不能据此宣称全套或用户原批量图表任务已完整修复，未知副作用和独立失败仍须保守处理；完整 App 与原场景还需主线验收。

### W11：模型主动等待

用户已补充：需要模型可主动等待若干秒后继续工作。沿原生工具目录和运行服务实现，支持指定时长、取消与真实等待回执；普通聊天和文件助手共用。引导消息在可处理边界打断等待，排队消息保持原有规则。保存可信的起始/截止时间及工具调用身份，中断恢复只等待剩余时间，不重新计满或重复已完成操作。设备后台挂起不能保证准点唤醒，应在实际恢复后按截止时间继续。更长定时工作沿已有任务调度服务，不创建并行调度系统。

与主线计时器集成时复用统一等待工具：同一任务可等待其原生计时器，再继续后续步骤。以真实计时状态和已观察到的响铃证据处理暂停、恢复、停止及进程重启，不能根据计时器消失猜测到时；取消或删除所属任务后不得启动替代任务。

当前主线已合入等待工具和原生计时器桥接的 11 个源文件，20 项聚焦测试通过，10 个组件对象编译通过。普通聊天和手记的调用接入已实现；全 App 测试产物及实际界面验收仍由主线完成，组件通过不代表这些场景已验收。

验收：正常到时、零/非法时长、停止、引导/排队、关闭编辑器、切前后台、进程中断后恢复；用可控时钟验证，不让测试实际等待长时间。覆盖工具发现、实际调用、回执和可见运行状态。

### W12：Mac Bridge 1.1.3 间歇版本兼容错误

基于用户当前 1.1.3，核对 App→发现/配对→Bridge HTTP 握手→命令/重连的实际版本与协议比较。用户已进一步确认：报错主要发生在执行任务或传输文件时，优先复现命令结果、工作区传输分页、缺失字段和错误响应解析。当前源码 `FloeMacBridge/Info.plist` 为 1.1.3 (6)，传输协议 `BridgeWire.version` 为 1；两者不能混用。客户端还把缺失传输字段等数据错误报告成 `incompatible`，因此用户看到版本错误本身尚不能证明协议不兼容。检查发现缓存、端点切换和并发响应，不靠一律忽略版本检查处理。当前本轮已有上传日志未检出这个错误，间歇根因保持待复现。

验收：1.1.3 正常握手与重连、真正不兼容协议、两个实例交替发现、缓存过期、响应乱序、传输分页和缺失字段；保留已配对凭据和信任边界。本轮只做源码及聚焦组件验证，不自动升级或重启用户运行中的 Bridge。

### W13：Traceroute 逐跳实时输出

当前有两条实际生产路径：`Sources/FloeExecution/Tools/DeviceICMPTraceroute.swift`/`NetworkDiagnosticTools.swift` 的工具调用，以及 `Modules/FloeToolbox` 的原生诊断服务。工具箱 `DiagnosticService.traceroute` 返回完整数组，`DiagnosticWorkbenchModel` 等它返回后才映射结果，符合用户报告的最后一次性展示。

- 从真实 ICMP 生产者逐跳发出观察，经服务和工作台更新稳定行；不使用计时器模拟进度。超时跳点和实际 RTT 仍可见，不把最大跳数当作确定总时长。
- 探测、停止、完成和错误分别可见。停止/退出保留已测跳点，重新开始后旧请求与旧 IP 查询结果不能写到新结果；有界缓冲和已拥有 socket/worker 的释放沿现有生命周期。
- 保留最终文本/导出兼容。前台工具卡需要实际接入实时通道；现有 `ToolContext.taskProgress` 仅后台任务注入，不能只调用这个空 reporter 就声称前台已实时。

验收：第一跳在第二跳尚未结束时已被观察到；连续超时、提前到目标、停止立即重开、关闭界面和迟到回调；当前 IPv4 探测范围保持准确，不伪造不支持的 IPv6 路由结果。

集成接缝已明确：逐跳观察与可选 IP 信息服务分离，IP 库版本参与回写校验，查询限制并发；缺库时仍显示真实跳点。主线正在实现和验证生产者至工作台、前台工具卡的完整通道，默认空适配器仅保留调用兼容，不算 IP 库已接通。

### W14：IP 信息库与诊断结果接入

初查工具箱时尚未接通 IP 信息库；本轮已增加真实 Swift 服务，并沿 AppEnvironment 接到工具箱诊断和 Traceroute。采用成熟数据源与读取器，保留准确来源、数据版本、许可及署名，提供真实的导入/下载更新、验证和回读。默认可用方案不依赖开发者购买账户；如需可配置服务，沿现有凭据存储及用户选择。

已核对的优先候选是 [DB-IP Lite 的地区与 ASN 离线库](https://db-ip.com/db/lite.php)和 [libmaxminddb 读取器](https://github.com/maxmind/libmaxminddb)：前者提供月度 CSV/MMDB 并要求保留署名，后者的当前正式版本为 [1.14.1](https://github.com/maxmind/libmaxminddb/releases/tag/1.14.1)。依实际 iOS 组件编译、真实文件字段和下载验证选定并固定版本；不把读取器与数据集的许可证混用。[IPtoASN](https://iptoasn.com/)可作 ASN 数据候选，其旧公共查询 API 已停止，不能接入失效 API 充数。

数据/读取器预验证已完成：真实下载并校验 2026 年 11 月 City 与 ASN MMDB，解压后与官方发布校验值一致；固定的 libmaxminddb 1.14.1 已读出公网 IPv4/IPv6 的真实地区及 ASN 字段，并完成 `arm64` iOS Simulator 原生对象编译（最低 26.0、SDK 27.2）。Swift 服务与诊断模块也已进入主线的实际 iOS 对象编译；更新/缓存行为、逐跳 UI 和完整 App 的验收仍分别记录，不能由读取器成绩替代。

- 查询和探测独立，逐跳出现后异步补信息，慢查询或缺库不能拖住整条路由。重复地址合并查询并缓存；更换库版本正确失效，停止/新请求的代次必须同时约束资料回写。
- 本地、环回、链路本地和保留地址本地判别；包含映射形式的私有 IPv6 地址，不向公共查询服务发送。地区和 ASN/网络归属仅展示数据源真实字段，不根据主机名猜运营商或精确物理地址。
- 支持所选数据源可读的 IPv4/IPv6，采用有界读取/索引；下载、校验、更新失败保留可用旧库。普通界面简洁展示，来源/版本和更新放到适当详情或设置入口。

验收：真实格式的脱敏/合成库 fixture、公网 v4/v6、本地/保留、无匹配/缺库、损坏/超大库、版本切换、重复地址缓存和缓慢查询；用真实读取器验证内容，不能仅通过假 resolver 的 UI 演示。

## 4. 顺序、依赖和验收门槛

1. **先处理阻断**：W2 化学无法退出/文件删不掉、W1 引导/排队卡住及文件助手中断后无法恢复、W9 参数拒绝诊断、W10 完成误判/恢复点保存、W6 生物 AI/3D 回归。早期以源码预研发起步；330已分阶段交付，当前按顶部最新决定先处理四类hotfix与改动相关App验证，不以GPU集成作等待门槛。
2. **落实共同生命周期**：W1 文件归类与 W2 删除/恢复联动，形成 W3 各编辑器可复用的对象删除原则；不要求所有编辑器同时改完才交第一批结果。
3. **专业工作流闭环**：W4 音乐、W5 地图、W6 生物、W7 会议各自输出可独立审查的小批源码和实际产物。重叠文件由同一 owner 维护；App 构建、设备使用和发行串行。
4. **界面收尾及改动回归**：W8 加各包暴露的实际布局问题；复用未受影响的已有组件证据，集中验收本轮 App 的受影响路径。依赖冲突、崩溃、数据丢失、无法退出或删除错误不得用文案掩盖。
5. **冻结下一版**：QA 范围稳定、源码集成及必要本地验证完成后，依版本权威选择未用版本/build，准备双语 Release/TestFlight 文案和精确源码产物；TestFlight、GitHub、Feather按当前用户授权分别处理和读回。本轮计划本身未执行版本、标签、上传或发行操作；Build315 正式安排保持。

验证遵循现有仓库流程：实际相关编译（Swift 6 包含 SIL/object）、变更行为的定向测试、同一 canonical iPad 的实际 App UI/保存重开；使用锁且不创建/重置 Simulator，不使用用户实体 iPhone。音频延迟、Pencil 手感、真实多人说话人分离等实体效果按实际条件另记，不以模拟器或独立组件宿主成绩替代。

每包短交接必须含：需求编号、源码 SHA、具体改动、命令/结果、实际产物、截图/回读及未验限制。失败原证据保留；构建通过、可操作、保存正确和发行可安装分别确认。

## 5. 当前未闭合信息

- 地图：等待用户正在生成的诊断记录；将其拆成可复现事实、助手推测和工具/原件证据，再更新 G01，不能直接照搬模型自诊断为根因。
- 新增参数拒绝：已匹配上传及失败请求，确认实际 provider/model；上游未给字段名，最小失败请求/具体参数仍待定向复现。
- 生物：核酸 3D 的旧样例/来源路径继续从现有实现和历史核对；空白序列/注释/网络与已有三维结构的编辑范围已确认，不再重复询问。
- 文件助手恢复：已读取相关上传诊断并确认归档/前台恢复候选缺口；具体任务在编辑器关闭、前后台切换、断流和接口拒绝之间的关联需用定向 App/transport 复现继续收窄，不能将截图中的普通任务恢复失败直接等同于所有文件助手的唯一根因。
- 图表完成判定：当前完成门禁已做实际源码的合成策略组件编译/运行复现；恢复点故障标记和终态路径已核对。上传证据还显示进入后台后邻近多个任务报恢复点失败，只有时间关联，具体底层异常未被现有日志记录，仍需定向复现。
- 本批源码及组件复核已交主线。主线 App17 第四次构建完成实际完整 iOS Simulator App 与测试包的编译、链接及产物保留，402 项冻结输入保持稳定。首轮 19 项新 App 用例实际为 12 通过、7 失败，原证据保留；修正测试原件初始化、原生创作录音占用规则及主线会议测试夹具后，App18 的 9 项受影响用例实际为 8 通过、1 失败，其余 10 项按未变范围复用既有通过结果。剩余失败暴露非空 MIDI 录制版本的片段/轨道 ID 不一致，已局部修正为共用 ID，保持文档校验和全部断言，App19 仅复验该实际用例，1 项通过且无跳过；未重跑原 19 项，原失败和各次产物继续保留。构建与既有组件通过不能代替这些运行结果，后续追加修改也不自动继承旧产物的验证。其余证据按各节区分；安装和发行由主线统一推进。

## 6. 直接实现入口

- 文件助手与归属：[StudioAgentTools.swift](../FloeAgent/FloeApp/Space/StudioAgentTools.swift)、[StudioDocumentAccess.swift](../FloeAgent/FloeApp/Space/StudioDocumentAccess.swift)、[任务中心](../FloeAgent/FloeApp/Home/HomeOverviewView.swift)。
- 调度与菜单：[ThreadDetailViewModel.swift](../FloeAgent/FloeApp/Chat/ThreadDetailViewModel.swift)、[ThreadDetailView.swift](../FloeAgent/FloeApp/Chat/ThreadDetailView.swift)、[ConversationCenter.swift](../FloeAgent/FloeApp/Remote/ConversationCenter.swift)。
- 文件删除与化学退出：[PersonalLibraryFileActions.swift](../FloeAgent/FloeApp/Space/PersonalLibraryFileActions.swift)、[ChemistryProjectSession.swift](../FloeAgent/FloeApp/Space/Chemistry/ChemistryProjectSession.swift)、[EditorState.swift](../FloeAgent/Modules/FloeChemistryKit/Sources/FloeChemistryUI/EditorState.swift)、[NativeDrawingState.swift](../FloeAgent/Modules/FloeChemistryKit/Sources/FloeChemistryUI/NativeDrawingState.swift)、[ChemistrySubmissionTracker.swift](../FloeAgent/FloeApp/Space/Chemistry/ChemistrySubmissionTracker.swift)。
- 音乐：[MusicProjectSession.swift](../FloeAgent/FloeApp/Space/Music/MusicProjectSession.swift)、[MusicWorkbenchView.swift](../FloeAgent/FloeApp/Workbench/Music/MusicWorkbenchView.swift)。
- 地图：[GISProjectImport.swift](../FloeAgent/FloeApp/Space/GIS/GISProjectImport.swift)、[GISProductionTools.swift](../FloeAgent/FloeApp/Space/GIS/GISProductionTools.swift)、[通用工具桥](../FloeAgent/Qualification/HeavyEditors/Integration/FloeHeavyEditorsHostAdapter/Sources/FloeHeavyEditorsHostAdapter/HeavyEditorToolBridge.swift)。
- 生物：[BiologyWorkbench.swift](../FloeAgent/Modules/FloeBiologyKit/Sources/FloeBiologyUI/BiologyWorkbench.swift)、[ScientificViews.swift](../FloeAgent/Modules/FloeBiologyKit/Sources/FloeBiologyUI/ScientificViews.swift)、[NativeScene.swift](../FloeAgent/Modules/FloeBiologyKit/Sources/FloeBiologyUI/NativeScene.swift)、[BiologyProjectSession.swift](../FloeAgent/FloeApp/Space/Biology/BiologyProjectSession.swift)、[ServiceOperations.swift](../FloeAgent/Modules/FloeBiologyKit/Sources/FloeBiologyEngine/ServiceOperations.swift)。
- 会议：[FileSpeechTranscriber.swift](../FloeAgent/FloeApp/Voice/FileSpeechTranscriber.swift)、[MeetingLiveTranscription.swift](../FloeAgent/FloeApp/Space/Meetings/MeetingLiveTranscription.swift)、[MeetingProjectView.swift](../FloeAgent/FloeApp/Space/Meetings/MeetingProjectView.swift)、[MeetingPCMChunkRecorder.swift](../FloeAgent/Modules/FloeMeetings/Sources/FloeMeetingsAV/MeetingPCMChunkRecorder.swift)。
- 绘画与名称：[MediaDrawingInputPolicy.swift](../FloeAgent/FloeApp/Workbench/MediaDrawingInputPolicy.swift)、[MediaV2Workspace.swift](../FloeAgent/FloeApp/Workbench/MediaV2/MediaV2Workspace.swift)、[PersonalContentService.swift](../FloeAgent/FloeApp/Space/PersonalContentService.swift)。
- 参数拒绝：[ProviderAdapter.swift](../FloeAgent/Sources/FloeProviders/ProviderAdapter.swift)、[OpenAIChatCompletions.swift](../FloeAgent/Sources/FloeProviders/Wire/OpenAIChatCompletions.swift)。
- 终态/恢复点：[ConversationRunService.swift](../FloeAgent/Sources/FloeAgentRuntime/ConversationRunService.swift)、[SQLiteRunCheckpointStore.swift](../FloeAgent/Sources/FloeAgentRuntime/SQLiteRunCheckpointStore.swift)、[TaskClosureGate.swift](../FloeAgent/Sources/FloeAgentRuntime/TaskClosureGate.swift)、[HarnessInvariant.swift](../FloeAgent/Sources/FloeAgentRuntime/HarnessInvariant.swift)。

- 主动等待：[AgentRuntime.swift](../FloeAgent/Sources/FloeAgentRuntime/AgentRuntime.swift)、[ToolCatalog.swift](../FloeAgent/Sources/FloeTools/ToolCatalog.swift)；新增等待实现需沿原运行生命周期接入。
- Mac Bridge：[MacBridgeClient.swift](../FloeAgent/Sources/FloeExecution/MacBridge/MacBridgeClient.swift)、[MacBridgeShellBackend.swift](../FloeAgent/Sources/FloeExecution/MacBridge/MacBridgeShellBackend.swift)、[BridgeWire.swift](../FloeMacBridge/Sources/FloeMacBridgeProtocol/BridgeWire.swift)、[BridgeService.swift](../FloeMacBridge/Sources/FloeMacBridgeApp/BridgeService.swift)。
- Traceroute：[执行工具原生探测器](../FloeAgent/Sources/FloeExecution/Tools/DeviceICMPTraceroute.swift)、[NetworkDiagnosticTools.swift](../FloeAgent/Sources/FloeExecution/Tools/NetworkDiagnosticTools.swift)、[工具箱原生探测器](../FloeAgent/Modules/FloeToolbox/Sources/FloeToolboxDiagnostics/DeviceICMPTraceroute.swift)、[DiagnosticWorkbench.swift](../FloeAgent/Modules/FloeToolbox/Sources/FloeToolboxWorkbenches/DiagnosticWorkbench.swift)、[ToolboxDiagnosticsCenter.swift](../FloeAgent/FloeApp/Space/Toolbox/ToolboxDiagnosticsCenter.swift)。
- IP 信息库：新增数据服务与上述诊断链路接通；依赖归入 [FloeToolbox 模块清单](../FloeAgent/Modules/FloeToolbox/Package.swift)，数据来源及预验证见 W14。
