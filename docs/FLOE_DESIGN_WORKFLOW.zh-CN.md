# 设计流程（简报到导出）

<!-- docs-updated: 2026-10-13 -->

状态：本页记录两种必须分开的状态。

- **已发布：** 下文标注“已发布”的小节随 1.7.29（270）源码（标签 `v1.7.29`；内部可用性记录见 [CURRENT_STATUS.md](CURRENT_STATUS.md)）交付。此后的 1.7.30（271）热修复只调整服务商名称归一化与蓝牙授权时机，不改变本流程。
- **未发布进行中：** 分支 `codex/design-workflows-20261013`（基线 `734e97f5`）新增自然语言对话入口、三种工况（制作/修改/重构）、服务原生可信重构授权门、实时能力矩阵与诚实的画布来源分类，另含 CAD 新建/导入与运行时回执修复。该源码未提交、未发布；已于 2026-10-14 完成本地全 App 编译、定向 App 测试与一项真实模型代表闭环（见 Local/Private/design-workflow-repair-20261013/integration/CONTINUATION-EVIDENCE.md），图形界面细节验收仍由主协调进行。标注 **[未发布]** 的小节属模块级工作：core/runtime 部分通过聚焦模块测试，而撰写本页时 CAD 新建/导入与演示文稿读取器仍在验收中。具体按钮文案与面向模型的工具接线仍由集成线校准（见[工具契约](DESIGN_WORKFLOW_TOOLS.zh-CN.md)）。

## 快速上手——已发布的画布面板（实际操作路径）

1. 打开一个画布，选中要作为设计来源的节点（文本/卡片、媒体/文件，或内置 Markdown/HTML/SVG 卡片），先放入或导入内容。
2. 打开画布视图菜单并选择 **设计流程**（`canvas.designWorkflow`）。面板作用于当前选中节点，并显示该节点的真实能力。
3. 编辑并保存简报/规格（**保存简报**、**保存规格**）；**将此规格应用到整个画布** 会在同一次画布 CAS 提交中写入工程规格权威，已有与新建设计子文档都会继承。
4. 冻结来源：**使用当前节点内容** 经由适配器守卫读取节点真实的文本、已留存素材字节、已绑定 CAD/Office 工作区文档或内置卡片来源；**导入源文件…** 用于外部文件。
5. 由助手/工具提出新修订，在候选区查看（**显示预览**）后选择 **采纳** 或 **拒绝**。助手采纳还需先在面板 **授权助手采纳**，以签发一次性、带过期时间的凭据。
6. **导出（已验证）…** 只按记录格式导出，并先用真实解析器重开字节；**恢复上一修订** 以追加新修订的方式恢复，不覆盖历史。

## [未发布] 对话入口：同一任务，三种工况

本轮在源码中实现的产品规则（模块级已验证；界面与工具接线仍待完成）：

- **自然语言在同一任务里开始与继续。** 用一段创意描述即可经既有原子任务启动创建普通任务；不再有类型选择菜单和必填简报/受众表单，也不存在可达的隐蔽同款表单。已保存的简报、规范、历史与候选全部保留，并显示为可编辑摘要；旧目标在有绑定原任务时恢复原任务，仅读取旧数据不会启动模型运行。
- **四个入口共用一个服务。** 普通聊天、创作首页、可写工作区文件、原始聊天附件共用同一设计所有者工作流、目标绑定、修订权威与采纳确认；画布节点在相同服务上保留其既有面板与工具。不新建隐藏画布、第二套聊天、第二个工程或平行运行时。
- **设计页只是一种展示。** 真实预览/对比为主区域，对话与之并列；摘要/规范/素材/候选按需展开；按类型显示页列表、视频时间线、服务/端口等侧栏，而不是所有类型都显示终端和文件树。关闭展示不取消运行、不停止服务；任务结束后不会静默复活。
- **画布保持自己的图形能力范围。** 布局、连线、shape/group/card 操作、图片模型与原生编辑器仍走画布事务。画布不能启动 Linux，不获得普通任务的完整工具集，不存放网页工程目录、依赖与开发服务。
- **文件与附件绑定必须显式。** 目标固定为原文件或原任务附件，绝不用变化中的“当前选择”；文件写入限制在受控工作区根内；聊天附件结果只回到原任务。

三种工况（Core API：`DesignWorkMode`、`DesignWorkIntent`、`DesignWorkScope`，位于 `FloeAgent/Sources/FloeCore/DesignWorkflow.swift`）：

| 工况 | 开始前 | 执行 | 预览与完成 |
|---|---|---|---|
| 制作 | 一句自然语言目标；仅在确实缺少实质输入时简短追问；不填表单 | 经已接通服务创建真实可编辑成果；保留素材、输入与工作区归属 | 展示真实成果并用自然语言继续修改；只有保存/重开与格式验证后才标为完成 |
| 修改 | 冻结指定修订；把用户指出的位置映射到真实页面、选区、片段或对象 | 只在冻结范围内编辑；范围外内容与原稿/手动草稿保持可恢复 | 展示变化与范围外检查；采纳更新明确的原目标 |
| 重构 | 读取现状；先用对话确认必须保留的内容、数据、功能与格式，以及允许改变的范围 | 在独立候选中重组；原成果绝不先被覆盖；手动编辑使旧基线失效 | 逐项对比并验证保留要求；只有用户采纳才替换原成果；可另存变体 |

“优化一下”不会自动当作重做：局部可逆改动按修改处理，整体结构/功能变化先确认重构。切换工况时当前成果与约束保留在同一任务。`DesignWorkIntent.validated(family:)` 会拒绝没有完整保留约束的重构、空对象 ID、负页码、非正区域/时间范围以及格式与内容族不匹配（`DesignWorkIntentError`）。

## [未发布] 重构授权：数据不是权限

- `DesignPreservationConstraints` 与 `DesignPreservationConfirmation` 记录的是*用户确认过什么*。它们是 `Codable` 数据、摘要可公开计算，原始模型 JSON 完全可以复刻——因此它们永远不是权限。
- 权限只能来自真实单次领取后由可信处理器（`DesignRestructureAuthorityHandler`）铸造的**非 Codable** `DesignRestructureAuthorityReceipt`。服务自行构造精确的 `DesignRestructureAuthorityRequest`（所有者目标稳定键、操作 ID、原任务归属、已解析基线修订、约束摘要）并逐字段校验回执（`DesignRestructureAuthority.validate`）。
- 该门在**暂存任何候选字节之前**（`DesignOwnerWorkflow.propose`）与生成之前（`DesignWorkflowEngine.freezeRun` / `proposeCandidate`）执行。nil 钩子、被拒/过期授权、陈旧/错主/错摘要/错操作的伪造回执都会在零暂存字节下失败闭合；新增的 throws `freezeRun` 重载不影响旧非 throws 签名的源码兼容。重放已记录操作返回已记录候选且不会二次领取；保留要求不同的重放按 `replayMismatch` 拒绝。
- 采纳时的单次领取（`claimAuthorization`）保持不变，采纳重构候选仍必须提供，否则 `DesignOwnerWorkflowError.restructureRequiresTrustedConfirmation`。任何工具参数字符串/布尔/JSON 字段都不能铸造该权威；模型提供的 `source`/`digest` 只是数据。
- 集成状态：领取既有审批授权的 App 侧处理器与传递工况的工具参数由集成线负责，**尚未接线**。在落地前，这些规则只有模块级测试证明，界面尚未验收。

## [未发布] 能力矩阵与来源分类

- `DesignCapabilityMatrix.assess` 按 `(工况, 内容族, 操作, 环境)` 回答：可用性 = 静态接线**且**实时探测；不可用结果带真实原因与恢复动作（`DesignCapabilityAssessment`）。环境键把 `officeEngineSession`、`linuxGuest`、`mediaGenerationModel`、`cadKernelSession`、`notesPDFService` 分开：离线 OOXML 操作不要求引擎会话，需要会话的操作在缺失时如实报告不可用。
- **捕获不等于生成。** `importSource` 标记为 `isCaptureOperation`；`DesignRevisionOrigin.isCapture`（导入/当前节点）与 `.isGeneration`（仅 `.generate`）严格区分。网页捕获形成的修订永远不会被描述成“制作网页”。
- **布局不是网页。** 画布布局对象（卡片/shape/group/audio/生成任务）分类为 `.composition`；无法识别但真实存在的格式为 `unsupported(format:)`；未知输入保持 `unknown` 并检查，绝不猜成网页。旧的卡片→网页回退已移除。
- **各类型边界保持独立。** 图片/视频生成使用既有持久化媒体任务与提供商实际已配置的模型——未接通的能力不作承诺；PDF 工作继续走既有 `PDFKitGate`；手记页面/存储是独立工作区，不是设计子文档或聊天状态；办公/演示区分可离线执行的 OOXML 操作与需要实时引擎会话的操作，绝不用 PDF/HTML/截图代替真实可编辑格式（例如验证通过的 PPTX）。
- 集成状态：实时探测由集成线用真实服务装配。在完成前，矩阵如实返回“未连接 + 原因”，不声称就绪。

## 模型与位置

| 组成 | 位置 |
|---|---|
| 流程状态机 | `FloeAgent/Sources/FloeCore/DesignWorkflow.swift` |
| 工况、保留约束、权威回执 **[未发布]** | `FloeAgent/Sources/FloeCore/DesignWorkflow.swift` |
| 共享所有者工作流（propose/adopt、权威钩） | `FloeAgent/Sources/FloeCore/DesignOwnerWorkflow.swift` |
| 能力矩阵与来源分类 **[未发布]** | `FloeAgent/Sources/FloeCore/DesignCapabilities.swift`、`DesignCanvasService.swift` |
| DESIGN.md 导入/编辑/导出 | `FloeAgent/Sources/FloeCore/DesignMDCodec.swift` |
| 子文档编解码（绑定与上限） | `FloeAgent/Sources/FloeCore/DesignCanvasMetadata.swift` |
| 画布权威服务 + 采纳凭据 | `FloeAgent/Sources/FloeCore/DesignCanvasService.swift` |
| 共享 UI/工具事务（决策、应用模板、使用当前节点） | `FloeAgent/FloeApp/Workspace/DesignWorkflowActions.swift` |
| Agent 工具（`canvas.design*`、`design.*`） | `FloeAgent/FloeApp/Workspace/DesignAgentTools.swift` |
| 面板（独立视图） | `FloeAgent/FloeApp/Workspace/DesignWorkflowPanel.swift` |

设计状态是**绑定画布节点的类型化子文档**（节点元数据键 `canvas.design`），只通过既有 `FileCanvasDocumentRepository` + `CanvasProjectFileWriter` 比较交换权威持久化——备份、同步、分叉、修订冲突全部沿用画布机制。**没有独立的设计存储、画廊或工程身份**：节点 ID 是唯一身份，必须提供，解码时校验绑定，不匹配即失败关闭。节点、连线与布局仍在 `CanvasProject`。画布级工程简报/规格权威存放在 **`CanvasProject` 自身**（`designProjectAuthority`，附加可选字段，旧工程解码为 nil），不是平行存储。

## 生命周期保证

- **简报**：可选目标/受众/约束；**规格**：可选配色/字体/布局/间距/品牌资产/语气/禁止项，外加原始 `DESIGN.md`。
- **运行冻结**：`freezeRun(operationID:inputRevisionID:targetRevisionID:)` 在生成/编辑前固定输入修订、规格哈希与目标；之后的编辑不能悄悄改变某次运行的依据。**[未发布]** 新增重载在*生成前*校验重构的可信回执，并把工况、保留摘要与期望格式写入冻结运行（`DesignRunFrozen.desiredFormat/workMode/preservationDigest`，可选 Codable 字段，旧负载解码为 nil）。
- **修订只追加且可恢复**：每次保存都是新修订；`restore` 追加指向恢复字节的新修订。修订比较交换（`expectedRevisionID`）把过期编辑器变成冲突，绝不覆盖。
- **锚定反馈**绑定 `artifactID + revisionID + 锚点`（区域/时间/页码/稳定对象 ID）。产物修订变化后，未处理锚点标记为 `staleAnchor`，必须由用户重新定位。校验拒绝空/负锚点。
- **反馈解决必须基于真实变更**：引用修订必须是产物*当前*修订，且内容哈希与锚定修订不同。模型文字永远不能解决反馈。
- **候选只是提案**：`propose` 记录建议修订与候选，产物不变。`adopt` 要求候选处于 pending、存在真实内容变更，并可要求当前修订匹配；`reject` 不改动产物。**[未发布]** 提议重放指纹绑定工况 + 保留摘要：重放同一操作返回同一候选，保留要求不同的重放以 `replayMismatch` 拒绝。
- **采纳模式**：`updateOriginal` 保留产物及其画布身份（名称/位置/尺寸/连线）并提升建议修订；`variant` 创建分支产物并记录分支点，不影响原产物。**修订冲突保护原稿**：手动编辑已移动基线时，更新原件的采纳抛 `revisionConflict`（绝不覆盖），变体则安全分支——新增模块测试锁定。
- **通知只回原任务**：聊天/创作采纳结果经既有存储只返回原始任务；持久决策 outbox 在 CAS 之前记录意图，并按完整指纹去重。
- **DESIGN.md 完整保留**：已知小节往返稳定；前言与所有未知小节按原文重新输出（测试验证逐字节稳定）。
- **持久化安全**：写入经由画布 CAS（每次变更只前进一个修订）；子文档带 schema 版本与 2 MiB 上限；更新 schema 或绑定不符时失败关闭；operationID 记录在子文档中以保证重放幂等。
- **模板**如实描述能力/输入/依赖/格式/许可/来源/哈希/版本及可选的回滚版本与哈希。签名内容服务仍是安装通道，此注册表只描述已接通内容；签名模板必须通过包规范摘要、`DESIGN.md` 入口与真实 LICENSE 校验，存储负载与清单摘要不一致时拒绝应用。
- **画布工程规格权威**：`canvas.designSetProjectSpec` 与面板的简报/规格/传播操作在**同一次画布工程 CAS**中写入权威——现有设计子文档在同一次提交中继承，新建节点在创建时继承；重放同时校验 operationID 与**完整负载身份**（同一 operationID 换负载会被拒绝，负载相同则去重且不增加修订）。无关节点编辑不会改变权威内容，冻结运行保留其已记录的规格哈希。
- **使用当前节点**：`canvas.designUseCurrentNode` 与面板“使用当前节点内容”把节点上已有的内容冻结为 `currentNode` 修订：文本/Markdown 正文、已留存素材字节、已绑定的 CAD/Office 工作区文档，以及内置 Markdown/HTML/SVG 卡片的类型化文本；复用既有适配器守卫，无需外部导出/再导入；没有可冻结内容时给出本地化的明确原因，且不改动可变的编辑器状态/草稿。
- **日志化决策**：面板与工具的采纳/拒绝共用同一事务（`DesignWorkflowActions`）：候选来源取候选自身持久化的原始任务（缺失即失败关闭，绝不回退到当前会话）；在 CAS 之前写入带精确节点与完整操作指纹的持久 outbox 意图；可抛出的持久入口只有真正写入后才确认送达，崩溃或送达失败会保留待恢复记录，由启动对账补送；重复决策按指纹去重。

## 类型化适配能力（已发布状态）

`DesignCapabilityRegistry` 只登记**实际接通**的操作。每个不可用操作必须带清晰原因。`canvas.designCapabilities` 向模型暴露该信息；App 注册诚实默认值。各类型实际接通的来源/导出操作：

| 类型 | 已接通操作 | 真实路径 |
|---|---|---|
| image | 导入、生成（已配置图像模型时）、预览、验证导出 | 素材入库、媒体生成、CGImageSource 重开 |
| video | 导入、预览、验证导出 | 素材入库、AVAsset 重开（时间锚点） |
| pdf | 导入、预览、验证导出 | 素材入库、PDFKitGate 重开 |
| notes | 导入、预览、验证导出 | Markdown/纯文本（md/markdown/txt），UTF-8 与格式重开 |
| webpage/prototype | 导入、采集（作为修订）、验证导出 | 绑定精确任务的浏览器采集、仅定位快照；HTML/JSON 与 SVG 经有界 XML/SVG 解析重开 |
| cad | 2D dwg/dxf：导入、预览、源导出、验证导出（同引擎重解析）。**3D 验证导出当前不可用**——glb/step/stl/obj/3mf/usdz/floecad 显式失败，不冒充“已验证” | CadDocumentCenter；引擎编辑仍走 CAD 提案流程 |
| office/presentation | 仅对具有显式画布所有工作区绑定（`canvas.designBindDocument`）的节点接通导入、预览、源导出、验证导出，经 OfficeCommandCenter 与有界 OOXML 重开（docx/xlsx/pptx） | 引擎命令编辑仍走办公提案流程；未绑定节点给出的原因是“需要先绑定工作区文档”，而不是“完全未接通” |

**[未发布]** CAD 新增工具级 `create` 与 `import`（见[工具契约](DESIGN_WORKFLOW_TOOLS.zh-CN.md)）：由内置工厂创建合法 `.floecad` 包并回读；把 STEP/IGES/STL/OBJ/GLB/glTF 几何导入既有包时只起草提案，在预览 + UI 授权 + apply 之前不改动任何内容。导入几何绝不伪造参数化特征树，IGES 壳体/面和网格格式保持只读渲染体，上述验证导出门槛不变。

### 内置画布来源节点

画布“添加内置”菜单创建的是类型化来源**卡片**（`metadata.builtinPlugin`），卡片文本即来源，并由专门视图渲染：

- `markdown` 卡片 → `notes` 内容类型，记录格式 `md`
- `html` 卡片 → `webpage`，记录格式 `html`
- `svg` 卡片 → `webpage`，记录格式 `svg`

“使用当前节点”按插件格式冻结卡片的精确字节（先由适配器解析器重开）；提案/采纳会通过原始渲染路径把新文本写回**同一张卡片**，保留节点 kind、`builtinPlugin` 元数据、布局与标题。强制格式兼容：例如 SVG/HTML 字节不能被采纳进 Markdown（notes）卡片，重命名为 `.svg` 的非 SVG 字节会被拒绝。未知/非文本内置节点（如没有已留存素材的 `panorama3D`）给出本地化的明确原因，不回退为普通卡片文本。绝不用截图/PDF 冒充可编辑原件。

## Agent 工具

`canvas.designGetState`、`canvas.designCapabilities`、`canvas.designCreate`、`canvas.designUpdateBrief`、`canvas.designUpdateSpec`、`canvas.designGetProjectSpec`、`canvas.designSetProjectSpec`、`canvas.designRegisterRevision`、`canvas.designImportSource`（负载先发布再单次 CAS 提交；重放返回已记录结果，参数改变即拒绝）、`canvas.designUseCurrentNode`、`canvas.designExportRevision`（只按记录格式导出，真实重开校验）、`canvas.designAddFeedback`、`canvas.designPropose`、`canvas.designAdopt`（先校验重放、后消耗凭据；持久决策 outbox 在 CAS 前记录意图，启动对账补送）、`canvas.designReject`、`canvas.designRestore`（恢复真实节点内容）。

全部需要显式 `canvasID` + `nodeID`（变更还需 `expectedRevision` 与 `operationID`），只通过画布权威读写。`adopt` 额外要求由面板签发的一次性、带过期时间的用户凭据（`DesignAdoptionGrantStore`）中的 `grantID`——助手无法自行采纳。`adopt`/`restore` 有副作用并要求审批。输入数据不能授予权限。

**[未发布]** `cad.document` 新增 `create` 与 `import` 动作；`design.*`/`canvas.design*` 的名称与参数不变。把工况与重构权威传入面向模型的参数、以及让画布动作可选携带工况，由集成线负责；绝不允许新增原始字符串/布尔形式的“授权”参数。

## 模板

内置模板随 App 提供；用户模板存放在 `Application Support/FloeAgent/DesignTemplates`，使用不可变版本目录与原子指针切换（回滚会恢复真实的上一版字节）。由**签名内容更新服务**（kind `templates`）交付的模板经哈希校验后只读物化到同一库；安装/更新/回滚仍留在“内容更新”设置中。模板界面在设计面板（创作）中，不在技能中。

## 测试

**已发布引擎套件：** `Tests/FloeCoreTests/DesignWorkflowTests.swift` 覆盖：冻结、候选在采纳前不生效、无变更提案被拒、分支采纳、锚点过期/重定位、需要真实变更才能解决反馈、修订冲突、恢复、DESIGN.md 往返与规格哈希、画布子文档绑定/损坏/新 schema 安全、operationID 去重与能力诚实性。引擎套件之外还包括：整工程采纳（同一次 CAS 写入真实节点内容、布局保留、重放跳过内容工作）、工程规格权威（三节点在一次提交中继承、同 operationID 换负载被拒、过期修订冲突、无关节点编辑、冻结运行保留、新节点继承、重开）、决策 outbox（跨重启完整指纹去重、旧信封回填、首次写入/重开、损坏/新 schema 只读并暴露错误、pending 不被裁剪、硬上限）、负载存储（路径穿越/符号链接/覆盖/跨画布）、模板持久化与签名包摘要权威、保留图像证据策略，以及 FloeAppTests 集成（图像端到端 导入→采纳→导出 与送达失败对账、缺失来源失败关闭、工程规格工具跨三节点、使用当前节点文本 + 精确本地化不可用原因、内置 Markdown/HTML/SVG 卡片 来源→提议→采纳→恢复→已验证导出 与精确的不支持状态、跨任务采集失败关闭）。

**未发布源码的模块级证据（2026-10-13，分支 `codex/design-workflows-20261013`，Xcode 27.0/Swift 6 聚焦 SwiftPM harness）：** FloeCore 跑过 495 项测试（含 20 项新增工况/分类测试）；随后的权威修正轮跑过 141 项聚焦测试（含 8 项新权威用例：伪造匹配 source+digest 被拒且零暂存字节、可信绑定 claim 被接受、陈旧/错主/错摘要/错操作被拒、幂等重放不二次领取）。运行时/日志修复证据见[工具契约](DESIGN_WORKFLOW_TOOLS.zh-CN.md)。这些只是模块级证据；2026-10-14 接续已完成全 App 编译、15 个变更 App 套件（78+53 例）、CAD 26 个 App 测试、创意入口 UI 测试与一项真实模型设计闭环，PPT 真实产物通过 python-pptx/openpyxl 独立回读。界面细节与真机表现仍由主协调验收。

## 待办门禁

办公/演示的引擎命令编辑仍委托给办公提案流程（即使已绑定工作区文档支持导入/验证导出）；3D CAD 验证导出（交换/网格格式与 `.floecad` 包）尚无可用的单负载读取器，不能声称已验证；真实模型提供商的生成闭环需要已配置凭据。**[未发布]** 对话界面、工况/权威工具接线与能力实时探测均尚未集成，界面细节与真机验收仍由主协调完成，且不会因为单元测试通过或构建变绿而自动成立。
