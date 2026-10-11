# 设计工作流工具（AI 与界面共用）

状态：由 T5 实现（强类型共享目标工具）。FloeApp 目标编译与集成行为测试由
T7 在完整 App 中执行；下表的 schema 即模型实际看到的已编译工具契约。面板
文案本地化归 T6；本文是人类可读参考。交付状态：已随 1.7.29（270）源码
（标签 `v1.7.29`）出包；TestFlight／安装可用状态以
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

## 诚实的边界

- 工具结果是状态报告：在 `resultPublication` 为 `published` 之前，候选
  并未被采纳、不可变所有者的结果并未返还。`resultPublication:"pending"`
  意味着持久记录仍开放给启动时对账，不得展示为已完成返还。
- `diffTruncated:true` / `diffNote` 表示展示的 diff 不是完整变更集；摘要
  哈希才是变更证据。
- 格式能力反映真实接入的解析器：不支持的格式返回不可用原因，绝不回退。
- 远端提交状态不猜测：重复操作重放已记录结果；持久 outbox 对账负责重试。
