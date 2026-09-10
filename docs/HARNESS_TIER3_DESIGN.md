# Tier-3 Harness 演进设计（快照回滚 / 模型 failover / iOS 形态 hooks）

> 2026-09-11 调研结论存档。对标 OpenCode / Claude Code / Kimi Code 后确认的三项结构性缺口，本轮只出设计，不进码。证据与出处见各节。

## G2. 工作区写操作快照与回滚

**现状**：`workspace.delete` 明示不可撤销；OpenCode 有 /undo /redo，Claude Code 有 checkpointing + /rewind（每条用户消息前自动快照文件，保留 100 个检查点）。

**设计**：
- 触发点：`WorkspaceFileService` 的 write/edit/delete/createFile(overwrite) 在落盘前，把受影响文件的先前字节复制到 `Application Support/FloeAgent/WorkspaceSnapshots/<conversationID>/<seq>/`（无先前文件记 tombstone）。
- 预算：LRU 保留最近 50 次写操作或 200MB，超出逐旧。快照元数据（runID/toolCallID/path/原 sha256/是否 tombstone）入 GRDB 新表，随会话删除级联清理。
- UI：会话菜单"撤销最近一次写入"（逐次回退）+ 快照列表；恢复 = 把快照字节写回（走既有审批通道）。
- 边界（照抄 Claude Code 的教训）：jobs/后台下载产物不入快照；Office 文档既有 DocumentRecovery 不动；快照不回滚对话状态，只回滚文件。

**风险**：存储预算与用户磁盘敏感（当前主卷紧张）；必须默认开 + 设置项可关 + 用量可见。

## G7. 模型 failover 列表

**现状**：仅 web search 有 provider failover；run 级主模型停滞（日志实证 45s stream stall ×2）只能靠重试同一模型。

**设计**：
- 模型配置加 `fallbackModelIDs: [UUID]`（有序）。
- 触发：同一 run 内 provider 层连续 N=2 次可恢复失败（stall/network/server），runtime 在写 checkpoint 后切换下一个 fallback 续跑，事件流记录 `modelFailover`（UI 可见、可导出）。
- 禁区：审批中的 run 不切（grant 绑 toolAuthorizationIdentity 不绑模型，安全）；本地↔云端互切要重新评估 schema 注入策略（本地走 adapter 自有目录）。
- 与重试的关系：fallback 发生在 maxProviderRetries 耗尽之后、判 fail 之前。

## G3. 生命周期 hooks 的 iOS 形态

**现状**：无用户可配 hooks；Claude Code 有 30+ 事件 shell hooks，Kimi Code 有 lifecycle hooks（门控/审计/通知）。

**设计（iOS 适配，不做 shell）**：规则化后置动作表 `hooks.json`（全局 + 每工作区）：
- 事件子集：`toolFinished`（matcher: 工具名 glob + status）、`runTerminal`、`jobTerminal`（已有通知逻辑可迁移进来）。
- 动作白名单：本地通知、写审计行到可导出日志、播放提示音。**不做**任意命令执行（iOS 沙盒无 shell 语义，且安全面不收）。
- 门控型 hook（PreToolUse deny）不在本形态内——审批策略已覆盖该职责。

**优先级**：低。jobs 通知已覆盖最痛的"后台完成提醒"；此表主要服务可观测性诉求。

## 明确不做（对标后确认形态不同）

- 自定义斜杠命令 md（iOS 无此交互习惯，固定集合够用）
- LSP/formatter 集成（桌面开发工具场景）
- worktree 隔离（workspace lease 已是等价物）
