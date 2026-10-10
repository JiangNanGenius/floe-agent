# 设计流程（简报到导出）

状态：完整流程已接入既有画布/编辑器服务：简报/规格/DESIGN.md → 按真实编辑器能力导入/生成 → 锚定反馈 → 修订绑定的候选 → 比较/采纳（在**同一次画布 CAS 提交中更新真实节点内容**）→ 以真实解析器重新打开验证的导出。无法真实接入的能力（办公/演示画布文件）会注明原因。画布始终是项目图的唯一所有者。

## 模型与位置

| 组成 | 位置 |
|---|---|
| 流程状态机 | `FloeAgent/Sources/FloeCore/DesignWorkflow.swift` |
| DESIGN.md 导入/编辑/导出 | `FloeAgent/Sources/FloeCore/DesignMDCodec.swift` |
| 子文档编解码（绑定与上限） | `FloeAgent/Sources/FloeCore/DesignCanvasMetadata.swift` |
| 能力注册表 | `FloeAgent/Sources/FloeCore/DesignCapabilities.swift` |
| 画布权威服务 + 采纳凭据 | `FloeAgent/FloeApp/Workspace/DesignCanvasService.swift` |
| Agent 工具（`canvas.design*`） | `FloeAgent/FloeApp/Workspace/DesignAgentTools.swift` |
| 面板（独立视图） | `FloeAgent/FloeApp/Workspace/DesignWorkflowPanel.swift` |

设计状态是**绑定画布节点的类型化子文档**（节点元数据键 `canvas.design`），只通过既有 `FileCanvasDocumentRepository` + `CanvasProjectFileWriter` 比较交换权威持久化——备份、同步、分叉、修订冲突全部沿用画布机制。**没有独立的设计存储、画廊或工程身份**：节点 ID 是唯一身份，必须提供，解码时校验绑定，不匹配即失败关闭。节点、连线与布局仍在 `CanvasProject`。

## 生命周期保证

- **简报**：可选目标/受众/约束；**规格**：可选配色/字体/布局/间距/品牌资产/语气/禁止项，外加原始 `DESIGN.md`。
- **运行冻结**：`freezeRun(operationID:inputRevisionID:targetRevisionID:)` 在生成/编辑前固定输入修订、规格哈希与目标；之后的编辑不能悄悄改变某次运行的依据。
- **修订只追加且可恢复**：每次保存都是新修订；`restore` 追加指向恢复字节的新修订。修订比较交换（`expectedRevisionID`）把过期编辑器变成冲突，绝不覆盖。
- **锚定反馈**绑定 `artifactID + revisionID + 锚点`（区域/时间/页码/稳定对象 ID）。产物修订变化后，未处理锚点标记为 `staleAnchor`，必须由用户重新定位。校验拒绝空/负锚点。
- **反馈解决必须基于真实变更**：引用修订必须是产物*当前*修订，且内容哈希与锚定修订不同。模型文字永远不能解决反馈。
- **候选只是提案**：`propose` 记录建议修订与候选，产物不变。`adopt` 要求候选处于 pending、存在真实内容变更，并可要求当前修订匹配；`reject` 不改动产物。
- **采纳模式**：`updateOriginal` 保留产物及其画布身份（名称/位置/尺寸/连线）并提升建议修订；`variant` 创建分支产物并记录分支点，不影响原产物。
- **DESIGN.md 完整保留**：已知小节往返稳定；前言与所有未知小节按原文重新输出（测试验证逐字节稳定）。
- **持久化安全**：写入经由画布 CAS（每次变更只前进一个修订）；子文档带 schema 版本与 2 MiB 上限；更新 schema 或绑定不符时失败关闭；operationID 记录在子文档中以保证重放幂等。
- **模板**如实描述能力/输入/依赖/格式/许可/来源/哈希/版本及可选的回滚版本与哈希。签名内容服务仍是安装通道，此注册表只描述已接通内容。

## 类型化适配能力（实际接入状态）

`DesignCapabilityRegistry` 只登记**实际接通**的操作。每个不可用操作必须带清晰原因（最低限度为 `Not connected in this build`，App 中使用更具体原因）。`canvas.designCapabilities` 向模型暴露该信息，App 注册诚实默认值（`designCoreDefaults()`）：

- 当前所有类型可用：锚定反馈、修订绑定候选、比较/采纳/拒绝/恢复（与载荷无关、持久化、可调用）。
- 尚未接通：源导入、生成、区域编辑、预览、源导出、验证导出——逐类型给出原因。绝不用截图/PDF 冒充可编辑原件。

## Agent 工具

`canvas.designGetState`、`canvas.designCapabilities`、`canvas.designCreate`、`canvas.designUpdateBrief`、`canvas.designUpdateSpec`、`canvas.designRegisterRevision`、`canvas.designAddFeedback`、`canvas.designPropose`、`canvas.designAdopt`、`canvas.designReject`、`canvas.designRestore`。

全部需要显式 `canvasID` + `nodeID`（变更还需 `expectedRevision` 与 `operationID`），只通过画布权威读写。`adopt` 额外要求由面板签发的一次性、带过期时间的用户凭据（`DesignAdoptionGrantStore`）中的 `grantID`——助手无法自行采纳。`adopt`/`restore` 有副作用并要求审批。输入数据不能授予权限。

## 测试

`Tests/FloeCoreTests/DesignWorkflowTests.swift` 覆盖：冻结、候选在采纳前不生效、无变更提案被拒、分支采纳、锚点过期/重定位、需要真实变更才能解决反馈、修订冲突、恢复、DESIGN.md 往返与规格哈希、画布子文档绑定/损坏/新 schema 安全、operationID 去重与能力诚实性。

## 待办门禁

各内容类型的适配器/面板与验证导出仍需实现并做真机验收；界面验收由协调方负责。当前门禁清单见私有验收清单。
