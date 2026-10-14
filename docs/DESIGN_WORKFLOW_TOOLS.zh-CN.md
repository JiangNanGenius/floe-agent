# 设计工作流工具（AI 与界面共用）

状态：由 T5 实现（强类型共享目标工具）。下表的 schema 即模型实际看到的
已编译工具契约；本文是人类可读参考。

交付状态：本页描述的画布侧设计工具随 1.7.29（270）源码（标签 `v1.7.29`）
交付。分支 `codex/design-workflows-20261013`（基线 `734e97f5`）带有**未发布**
新增内容：所有者工作流的工况与可信重构授权缝、`cad.document` 新建/导入、
结构化子代理回执、未知结果对账与逐调用计时、可选演示文稿要点。2026-10-14 接续已完成本地全 App 编译、15 个变更 App 套件、CAD 26 个 App 测试、创意入口 UI 测试与一项真实模型设计闭环；PPT 真实产物通过 python-pptx/openpyxl 独立回读。界面细节验收仍由主协调进行。标注 **[未发布]** 的小节尚未进入任何已安装构建。TestFlight／安装可用状态以
[CURRENT_STATUS.md](CURRENT_STATUS.md) 为准，不在本页声明。

设计工作流只有一个状态机（`DesignWorkflowEngine` 基于 `DesignProject`）
和两个所有者权威：

- **画布节点** —— 画布文档 CAS（`DesignCanvasService`，节点元数据
  `canvas.design`），通过既有 `canvas.design*` 工具与设计面板使用。
- **其他所有者** —— 文件、原始聊天附件、创作（Creative）目标，通过共享
  所有者工作流（`DesignOwnerWorkflow`，所有者信封 + 负载存储沿用既有
  产物权威目录）。

两者共用同一套校验、绑定修订的 propose/candidate/adopt/reject/restore/
export 以及同一套持久化决策事件。通用所有者工作流拒绝 `.canvasNode`
（不存在第二个画布权威）；对画布的强类型变更会返回明确的兼容工具指引。

## 强类型目标描述

每个 `design.*` 工具都接收一个冻结目标：

```json
{
  "kind": "fileDocument",
  "ownerID": "<工作区 UUID / 会话 UUID / 画布 UUID / 创作所有者>",
  "documentID": "画布文档 / 文件文档 / 消息 ID，可为空",
  "sourceID": "节点 UUID / 工作区相对路径 / 附件引用 / 创作 ID",
  "environmentID": "可选",
  "revision": "由 design.resolveTarget/freezeInput 返回的冻结基线令牌",
  "originConversationID": "仅来源标注",
  "requestedOutputKind": "仅 Creative 启动请求"
}
```

规则：

- `kind` 取 `canvasNode`、`fileDocument`、`chatAttachment`、
  `creativeDocument` 之一。
- 文件 `sourceID` 是工作区相对引用，经实时工作区权限/书签服务解析；绝对
  路径或 `../` 永远不构成权威。
- 聊天 `ownerID` 是**原始会话**，`sourceID` 是附件引用。原附件永不被修改
  或删除；采纳结果只以**新附件**回到同一原始任务。
- `originConversationID` 不能扩大权限：运行存在持久任务绑定时，不一致即
  拒绝；存储的来源取自实时运行上下文。运行只能使用自己任务的聊天附件。
- `revision` 是冻结基线令牌。手动修改会移动它；基线已不匹配的候选在采纳
  时以 `revisionConflict` 失败，绝不覆盖新编辑。

## 工具清单

只读：

| 工具 | 用途 |
| --- | --- |
| `design.resolveTarget` | 解析目标并返回经验证元数据（格式、内容族、当前修订令牌、可否原位更新、来源），不可用时给出真实原因 |
| `design.getState` | 读取共享设计状态：brief、spec、冻结运行、产物/修订、反馈、候选（画布类型经画布服务读取） |
| `design.compare` | 基于保留字节比较候选与基线；摘要哈希为变更证据，另附有界统一 diff 与 `diffTruncated`/`diffNote` |

变更类（必须有 `operationID`，按所有者修订做比较交换）：

| 工具 | 用途 |
| --- | --- |
| `design.updateBrief` / `design.updateSpec` | 更新 brief / 设计规范（支持 DESIGN.md 导入） |
| `design.freezeInput` | 将实时解析的源冻结为基础输入修订 |
| `design.registerEdit` | 将手动/生成保存登记为新修订（工具自行读取并校验负载字节摘要） |
| `design.addFeedback` / `design.resolveFeedback` | 锚定反馈；只有经验证的变更修订才能完成 |
| `design.creativeBegin` | 在素材存在前保存 Creative 启动请求（目标类型 + brief/spec） |
| `design.creativeBindFirstResult` | 绑定首个真实生成结果（校验字节）；后续编辑走 `registerEdit`/`propose` |
| `design.propose` | 从应用产物目录真实字节提出绑定修订的候选；在采纳前保持 pending |
| `design.adopt` | 凭用户确认的一次性授权采纳（见下） |
| `design.reject` | 拒绝待定候选；持久事件只发给原始任务 |
| `design.restore` | 恢复历史修订（保留字节重新校验） |
| `design.exportVerified` | 通过真实格式重开验证后导出保留字节；不做格式转换 |

## 受信确认（模型无法自造）

采纳必须持有用户明确确认产生的一次性授权，且绑定**精确的**目标稳定键、
候选、基线修订、提议修订与模式：

```swift
let grantID = await DesignOwnerAuthorization.shared.issueOwnerAdoption(
    targetStableKey: target.stableKey,
    candidateID: candidate.id,
    baselineRevisionID: candidate.baseRevisionID,
    proposedRevisionID: candidate.proposedRevisionID,
    mode: .updateOriginal,
    scope: .aiTool)   // 交给运行时；直接界面采纳用 .trustedUI
```

随后：

```json
{
  "target": { "……": "……" },
  "operationID": "adopt-brief-1",
  "expectedOwnerRevision": 2,
  "candidateID": "cand-…",
  "mode": "updateOriginal",
  "grantID": "grant-…"
}
```

- 授权在共享采纳事务内、首个副作用（持久意图/所有者写入）之前被**原子
  领取并核销**：精确的目标稳定键、候选、基线修订、提议修订、模式与调用
  面在同一次 `ApprovalGrantStore` 调用中校验并核销。缺失、过期、已撤销、
  已被领取或字段不匹配的授权在零副作用下失败，且不匹配不会消耗授权；给
  `updateOriginal` 的授权不能以 `variant` 重放。
- 被领取的授权只授权**一个**冻结操作。领取之后的失败（即使已证明零写入）
  都必须重新取得用户确认；存储不会自动重新武装已领取的授权。
- 重放已记录操作返回原结果，不再领取授权，也不产生重复文件或事件；模式
  改变的重放按不匹配拒绝。
- `design.propose` 的精确重放位于共享服务内：操作 → 候选记录（候选 ID、
  提议修订与负载指针，以及 artifact/基线/格式/字节/summary/diff/反馈/
  来源的规范指纹）与候选在**同一次**封套事务中提交。重复的 `operationID`
  返回已记录的候选与负载，不新增修订、候选或暂存负载；字节、格式、
  artifact、基线、summary、反馈或来源任一改变都会在任何暂存之前以
  `replayMismatch` 拒绝。相同字节在**不同** operationID 下是合法的新提案；
  该记录在重新打开工作流与持久化编解码后依然有效。
- 默认采纳（`updateOriginal`）更新原始授权目标（工作区文件原位提交并
  回读校验）；不可变所有者（聊天/创作）结果经既有存储**返回为新目标**。
  `variant` 显式分支新建。

## [未发布] 工况与重构权威（所有者工作流）

本轮为共享所有者工作流增加可选 `DesignWorkIntent`（工况
`create`/`modify`/`restructure`、真实期望格式、精确范围、保留约束、原任务
归属、确认记录）。核心 API 源码兼容：所有新参数都有默认值，
`DesignRunFrozen`/`DesignCandidate` 新增的可选
`workMode`/`preservationDigest`/`desiredFormat` 字段对旧负载解码为 nil。
缺少完整保留约束的重构意图会被拒绝
（`DesignWorkIntentError.preservationConfirmationRequired`）。

权威规则（数据 ≠ 权限）：

- `DesignPreservationConfirmation` 只是用户确认内容的**记录**：它是
  `Codable`、摘要可公开计算，模型 JSON 可以完全复刻。它永远不是权限。
- 权限只能来自真实单次领取后由可信 `DesignRestructureAuthorityHandler`
  铸造的**非 Codable** `DesignRestructureAuthorityReceipt`。服务自行构造
  精确请求（所有者目标稳定键、操作 ID、原任务归属、已解析基线修订、保留
  摘要）并逐字段校验回执。
- 该门在暂存任何候选字节之前（`DesignOwnerWorkflow.propose`）与生成之前
  （`DesignWorkflowEngine.freezeRun`/`proposeCandidate`）执行；nil 钩子、
  被拒/过期 claim、陈旧/错主/错摘要/错操作回执都会在零暂存字节下失败
  闭合。重放已记录操作不会二次领取；保留要求不同则 `replayMismatch`。
- 采纳重构候选仍必须提供既有采纳期单次领取（`claimAuthorization`），
  否则 `restructureRequiresTrustedConfirmation`。任何工具参数（字符串、
  布尔或 JSON）都不能铸造权威；模型提供的 `source`/`digest` 只是数据。
- **集成状态：** 领取既有审批授权的 App 侧处理器与承载工况/权威的工具
  参数尚未接线。在落地前这些规则只有模块级验证，不得展示为已接通界面。


## 设计冻结与普通写工具（原稿保护）

**[未发布]** 候选未采用期间，被绑定为设计目标的原始工作区文件处于冻结态：
模型的普通 `workspace.writeFile`/`createFile(overwrite)`/`applyPatch`/`moveFile`/
`deleteFile`/`copyFile`（目标侧）/二进制写入对该路径返回结构化拒绝
（`DesignFreezeError.sourceFrozen`，含任务归属与恢复动作——把改动作为
design.propose 候选暂存，或让用户先拒绝/取消）。冻结按规范路径与
(设备, inode) 双重身份匹配：`../` 穿越、symlink 交换、删重建与 hard link
别名都不能绕过。读、新文件、暂存目录、无关文件与包安装不受影响；
可信手动编辑（UI 路径）不被拦截，但会使候选基线失效，采用时乐观门
失败闭合并保留用户修改。采用成功或最后一个候选被拒绝后冻结解除。
Linux guest 的 VFS 原始写不在 Swift 门控范围内（标注为 unsupported
backend）：guest 若改动原文，采用端冻结-SHA 乐观门拒绝覆盖并保留现状。

## Creative 源授权

Creative 创作目标独立于任何工作区或画布包含关系而存在，因此仅凭包含关系
不能授权。Agent 运行调用 `design.creativeBegin` /
`design.creativeBindFirstResult` 时必须携带**该次调用的运行时审批**
（`ToolContext.approvalGrantID`，由策略/人工关卡签发，并在执行前校验工具
描述符）；缺失时以明确原因失败。此外，创作目标及其绑定的结果素材必须归属
运行自身的任务（实时 run→task 关联）——外部或未知所有者的素材一律失败。
应用内受信 UI 直接调用工作流（`runID == nil`），不受影响。不存在私有授权
存储，也不存在无条件放行。

## 示例

解析并冻结工作区文件：

```json
{ "tool": "design.resolveTarget",
  "target": { "kind": "fileDocument", "ownerID": "<工作区 UUID>",
              "sourceID": "specs/home.md" } }
{ "tool": "design.freezeInput",
  "target": { "kind": "fileDocument", "ownerID": "<工作区 UUID>",
              "sourceID": "specs/home.md" },
  "operationID": "freeze-1" }
```

提出候选并比较：

```json
{ "tool": "design.propose",
  "target": { "……": "……" },
  "operationID": "propose-1",
  "expectedOwnerRevision": 1,
  "artifactID": "<freeze 返回的 artifact>",
  "payloadRelativePath": "ChangeArtifacts/edit-1.md",
  "summary": "收紧引言" }
{ "tool": "design.compare",
  "target": { "……": "……" }, "candidateID": "<propose 返回的候选>" }
```

采纳聊天附件结果（只通知原始任务，并只在该任务返回新附件）：

```json
{ "tool": "design.adopt",
  "target": { "kind": "chatAttachment",
              "ownerID": "<原始会话 UUID>",
              "documentID": "<消息 UUID>",
              "sourceID": "att-original" },
  "operationID": "adopt-1",
  "expectedOwnerRevision": 2,
  "candidateID": "<候选>",
  "mode": "updateOriginal",
  "grantID": "<用户确认的授权>" }
```

素材尚不存在时启动 Creative：

```json
{ "tool": "design.creativeBegin",
  "target": { "kind": "creativeDocument",
              "ownerID": "<创作所有者>",
              "sourceID": "<创作 ID>",
              "requestedOutputKind": "image" },
  "operationID": "creative-start-1",
  "goal": "产品主视觉",
  "audience": "发布页" }
```

随后用既有媒体服务生成，再以 `design.creativeBindFirstResult`
（`boundResultID` + 校验后的 `payloadRelativePath`）绑定结果。

## 旧版画布工具（兼容）

`canvas.designGetState`、`canvas.designCreate`、`canvas.designUpdateBrief`、
`canvas.designUpdateSpec`、`canvas.designRegisterRevision`、
`canvas.designImportSource`、`canvas.designUseCurrentNode`、
`canvas.designExportRevision`、`canvas.designAddFeedback`、
`canvas.designPropose`、`canvas.designBindDocument`、`canvas.designAdopt`、
`canvas.designReject`、`canvas.designRestore` 以及项目级 spec 工具的名称、
参数与返回结构保持不变，仍是 `DesignCanvasService` 的包装（画布整数修订
CAS、`canvas.designAdopt` 用户授权）。用 `kind:"canvasNode"` 调用强类型
`design.*` 变更会返回
`{"migrationError": true, "compatibleTool": "canvas.designPropose", …}`
（状态码 2）——明确迁移指引，绝不走第二条画布路径。

## [未发布] CAD 新建与导入（`cad.document`）

在既有单一工具上新增两个动作；两者都只属原生引擎（DWG/DXF 二维图纸保留
自己的读/编辑界面）：

| 动作 | 参数 | 契约 |
| --- | --- | --- |
| `create` | `path`（新 `.floecad` 位置）、可选 `name` | 经宿主工厂创建**空**原生包：名称清洗并去重、受控本地工作区路径、非覆盖原子提交，随后真实存储回读。模型绝不写包字节，也绝不猜内部目录/清单结构。 |
| `import` | `path`（**已存在**的 `.floecad`）、`source_path`、可选 `format`、`unit_scale`、`name`、`summary` | 把工作区 STEP/STP、IGES/IGS、STL、OBJ、GLB 或 glTF 文件的几何加进既有包：在一次性副本上起草提案并返回预览；在用户在 CAD UI 确认并用 UI 签发的授权 apply 之前，不改动任何内容。 |

格式边界由工具按格式明确给出（capabilities 回复中的 `geometry_class` 与
`note`）：STEP/IGES 实体导入为精确 B-rep（IGES 壳体/面保持只读渲染；
本构建不提供 IGES 导出）；STL/OBJ/GLB/glTF 导入为渲染网格且**没有参数化
历史**；散装 `.obj`/`.gltf` 保留其材质/贴图兄弟文件；源文件经工作区守卫
读取且从不修改。错误区分文件不存在、非文档包、清单不可读、格式/引擎不
支持与权限拒绝。无文档的 `capabilities` 分别报告二维与原生三维引擎，避免
把二维限制读成“三维不可用”。新建/导入是写操作、继续受审批约束；对已暂存
画布草稿调用 `create` 会被拒绝（该暂存只授权一个既有文档，不是新包）。

## [未发布] 运行时回执：子代理、未知结果、逐调用计时

- **委派子代理返回结构化结果。** `SubagentOutcome.Status` 为
  `completed`/`partial`/`budgetExhausted`/`cancelled`/`providerError`/
  `toolError`，只有 `completed` 是成功。`delegate` 工具回执对完成渲染
  `status=ok`，其余渲染真实状态名，且总是携带 `iterationsUsed=N` 与有界
  `evidence:`/`unfinished:` 列表。非 ok 映射到 `exitStatus=1`，因此
  `ToolResult` 为 failed——partial/预算耗尽/取消/错误绝不会被读成 ok 子
  任务。最终摘要上限 8 KiB，超出时追加明确的 `[summary truncated]` 标记，
  而不是静默丢弃尾部；最后一个预算槽保留给有界收尾，不开启无界循环。
- **未知结果按类别记录，且只有狭窄对账。** 持久抑制收据记录
  `interruptedDispatch`（派发后 App 重启或挂起）、`capabilityRemoved` 或
  旧版 `unattributed`。抑制文案如实说明类别（应用重启中断绝不会被描述成
  “能力被移除”）并给出可读逃生路径。类型化 reconciler 只能消解
  `interruptedDispatch` 收据，Linux reconciler 还只限 start 类
  `environment.startLinux` 路由，且必须由权威只读状态证明安静停止（无注册
  实例、引擎未运行、未隔离）并且重试的显式形状与已保存启动形状一致。
  arbitrary 命令、restart 与未知付费提交永不消解；证据不足维持抑制。
  账本溢出哨兵永不消解。
- **Linux 通道如实措辞。** 命令通道现在追踪
  admitted/sent/guestAccepted/cancelRequested/stopConfirmed/completed/
  guestExited/poisoned，携带环境/代际/租约/请求身份，但**不记录命令
  正文**。exit=125/超时文案说明会话已拆除、下一命令按上次成功配置冷启动
  新来宾，不声称被中断的命令是否执行过。所提供日志中的通道停顿根因未能在
  本机复现；交付的是分阶段追踪与对账桥，不是已证实的根因修复。
- **逐调用计时真实且单调。** 工具结果负载持久化 `durationMs`（真实
  派发→结束的执行时间，用单调时钟测量）、`queuedMs`（仅真实派发的调用）
  与 `dispatched` true/false。被抑制、拒绝、取消或恢复而未派发的调用记录
  `durationMs=0`、`dispatched=false`——缺失的测量绝不捏造成非零时长，
  排队时间不计入执行时间。此项只改遥测，不改变执行并发。
- **集成状态：** 类型化运行时缝已存在，但提供 Linux reconciler 的 App 侧
  适配器（绑定 run 的环境身份，绝不从模型文本推断）尚未接线；在接线前，
  未知结果仍按旧行为完全抑制。

## [未发布] 演示文稿 schema：要点可选

`document.presentation.createDeck` 接受只有对象的幻灯片：每个 slide 只要求
`title`，省略 `bullets` 解码为空列表。显式 `null` 或错误类型仍然拒绝，
不会静默接受；JSON schema 的 required 与解码器一致（`["title"]`）。图表
内嵌真实可编辑 `.xlsx` 工作簿，图片/形状为原生 OOXML——是验证通过的
PPTX，绝不用 HTML/PDF/截图冒充。模块级 DTO 编译与对象检查已通过；撰写
本页时完整 PPTX 生成、独立读取器与完整 App 编译仍在等待。

## 诚实的边界

- 工具结果是状态报告：在 `resultPublication` 为 `published` 之前，候选
  并未被采纳、不可变所有者的结果并未返还。`resultPublication:"pending"`
  意味着持久记录仍开放给启动时对账，不得展示为已完成返还。
- `diffTruncated:true` / `diffNote` 表示展示的 diff 不是完整变更集；摘要
  哈希才是变更证据。
- 格式能力反映真实接入的解析器：不支持的格式返回不可用原因，绝不回退。
- 远端提交状态不猜测：重复操作重放已记录结果；持久 outbox 对账负责重试。
- **[未发布]** 工况/权威、CAD 新建/导入、运行时回执与计时新增内容只有模块
  级验证。它们的 App 编译、工具参数接线、界面呈现与真实模型行为均未运行；
  撰写本页时 CAD 工作线的新建/导入验收测试与完整 PPTX 读取器检查仍在进行；
  不得把本页读作集成或发布声明。

## [未发布] 预览优先设计页、入口判定、创意路由与写前保护（2026-10-14）

- **预览优先设计页。** 绑定任务的设计工作台以真实成果预览为主（网页引擎/图片/视频/Quick
  Look/文本）并与同一会话并排；需求/规范/工况/反馈收进默认折叠的详情面板，不再以表单作为
  落地页。全屏是同一视图树上的页内模式（唯一明确的“完成”按钮、不再嵌套呈现），预览、会话、
  输入草稿与选择在 全屏/旋转/分屏 间原样保留。各格式限制如实说明：CAD 无内联渲染入口，走
  既有专业编辑器交接；Office 预览明确标注只读并提供真实编辑器入口；PPT/Office 成果绝不冒充
  可编辑 HTML/PDF。
- **入口判定（共享、可测）。** 设计入口只依据持久事实：显式绑定 + 真实存在且确实可预览的
  成果（按格式的预览能力表，与生成/编辑能力分开）。普通问答、关键词、仅有附件或空绑定都不
  显示入口、也不自动弹出。默认制作/修改按原流程完成；入口只是轻量“查看成果”，仅用户点击才
  打开。重启/恢复从持久记录恢复同一状态。
- **候选操作按需出现。** 选中待处理候选时：一个主操作“采纳”加紧凑“更多操作”菜单（对比/
  另存变体/拒绝/授权助手）；当前成果不保留常驻决策条，候选解决后即收起，不挤占长期预览。
- **原件写保护生命周期。** 显式的修改/重构绑定在启动与每次继续时冻结原件（无法建立即
  失败关闭）；冻结期间普通/来宾任意执行在派发前被拒（只读检查可用），模型侧决策不能解除
  冻结，验证采用后重建新基线，只在“已完成且无待处理候选”“可信用户处理”或“会话删除”时解除。
  按目标范围释放：解决一个目标不会解除同会话另一目标的待处理原件；多所有者条目各自独立；
  目录/网站根原件冻结既有文件与父级变更。持久化以存储往返为证，保存失败则启动失败关闭。
- **创意去向路由与画布交接。** `creative.chooseDestination` 依据真实能力把创意请求路由到真实
  画布（持久创建并通过既有画布界面打开）或“普通项目+普通任务”（沿用同一已授权供应商/模型），
  以完整请求摘要做幂等身份（同 id 不同负载视为冲突）。`canvas.startOrdinaryTask` 把明确的画布
  素材作为可验证的不可变快照（有界、唯一命名、含节点/哈希/大小的清单）写入原子预留的工作区；
  持久记录在延迟任务启动前落盘，重放/恢复不会重复创建或重发，未知启动结果先查询持久行收口。
  交接不转移执行权限：画布仍是视觉白名单，新普通任务按自身能力与审批运行。
- **诚实边界。** 本轮未执行真实 Linux 来宾验证（仅派发层与模块覆盖）；设计页面观感（视觉、
  旋转手感）归主协调验收，本文不冒称。以上均为 [未发布]，不构成发布或整机验收结论。

## 2026-10-14 第二轮修订（以当前源码为准）

- **画布模型 handoff 工具真正可用。** `canvas.startOrdinaryTask` 已进入
  `CanvasAgentToolPolicy.nativeToolNames`，真实画布运行的允许工具名包含它（画布能力上限
  不会因此引入任何 Linux/shell/工作区写入）。执行与调用运行的持久
  `CanvasRunContextStore` 绑定强校验：入参画布与绑定不符、运行无绑定、节点不在用户
  选中/点名集合内，都在读取任何素材字节之前被拒绝。目的地必须显式（现有工程工作区
  且经验证存在，或 `createProject=true`，二者恰一）；聚合素材字节在加载前按元数据预检；
  暂存文件保留 UTF-8 原始显示名并附加内容哈希后缀；路由记录携带来源文档 id 与检视的
  工程修订号以及每个素材哈希。
- **路由生命周期可抗崩溃。** 陈旧的 `prepared` 记录与真实启动事实对账（RunLaunchStore
  在 provider I/O 前以单事务提交会话+运行）：已启动的目的地归并为 `started` 绝不重发；
  无运行的“裸会话”行关闭式失败；存储读取失败关闭（读取错误绝不当作空库）；并发相同
  请求按每操作 in-flight 归属合并；已是路由目的地的会话不能递归再派生目的地；可恢复
  路径上不再存在 `fatalError`。
- **去向评估基于意图。** Linux 需求一律路由普通工程——`hint=canvas` 永远不能接受
  画布+Linux 组合；原生 CAD 视觉组合可留在画布；Office 原件按真实原生/实时引擎能力
  路由，绝不被 HTML/PDF 替代。模型的显式 `hint` 被尊重（project 恒 honored；canvas 仅
  视觉族，否则带原因拒绝）——绝不只凭 family 默默改写显式选择。
- **导航真实可达。** 前台路由投递会先撤下根级自有覆盖（画布目的地 cover、设计页
  cover）再选中目的地会话；前台探针同时接受“其画布即当前展示画布”的运行。画布目的地
  打开器在失败时给出可重试/可关闭的真实错误，不再无限转圈。
- **设计页布局/全屏。** 页面以根级全屏 cover 呈现（占满可用窗口，无暗淡边缘）；页内
  全屏开关只把会话侧栏裁剪到零宽——同一个实时网页视图、播放器、QuickLook/编辑器宿主、
  聊天、草稿与选区保持挂载。格式/字节徽标在预览上方自留一条区域（不再压住页首标题）；
  详情面板真正 trailing（Spacer 定位、宽 280–360 自适应、不再硬编码 360）；窄屏提供
  显式“预览/聊天”分段切换（`design.page.sectionPicker`，44pt）；编辑器移交不再能把
  设计页递归叠加到自身之上。
