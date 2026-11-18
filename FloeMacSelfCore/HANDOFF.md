# FloeMacSelfCore 交接（2026-11-17 安全修复）

范围：仅 `FloeMacSelfCore/`。未修改 `FloeMac/`、`FloeMacBridge/`、`FloeAgent/`、iOS/Android、Git 历史、发布文件或用户数据库。
状态：**源码与测试源码已写；未编译、未类型检查、未链接、未运行测试、未解析依赖、未连接 App。** 本文件不是运行验收。

## 1. 本次修复相对上一版的变更

上一版的关键缺陷与本次对应修复：

| 上一版缺陷 | 本次修复 |
| --- | --- |
| claim 只在本进程 RAM；两个 runtime/进程或重启可同时 prepare 同一 conversation | `floe_mac_self_admission` durable 表 + `(conversation_id, run_id, epoch)` CAS；未知记录阻塞自动重试 |
| prepare 提交后 identity mismatch / shutdown / start failure 可以释放 claim，留下 durable unknown run | 进程内“未 dispatch”证明 + `abandonBeforeDispatch` 写入 `failed`/`abortedBeforeDispatch` 终态；无法证明时保留 unknown，绝不释放 |
| 没有跨进程 authority lock | `FloeMacSelfAuthorityLock`：0600、O_NOFOLLOW、单 link、flock、路径 inode 复核 |
| startPrepared vs stop / stop vs approval 的 actor reentrancy 竞争 | `FloeMacSelfRunFence` 短临界区 + stop epoch；durable `starting` 写完后才 `commitDispatch`；approval token 在 await 后复核 |
| dispatch 后超时可能被当成已取消/未启动 | `.dispatchUnknown`：保留 admission 与 session；不声称 cancelled/finished |
| terminal receipt 接受任意 terminal event，只要 run 行像终态 | `FloeMacSelfDurableRunProbe`：exact run/conversation/state/payload、finalMessageID/message identity、noFinalText、later-status 冲突 |
| 并发 shutdown 没有串行化/没有 join prepare | 单 shutdown task + `shuttingDown` 阻断新 admission/close + drain in-flight admission/close + join bootstrap；session 关闭后才 close DB |
| `allowUnconfirmed` 可能释放 durable claim | 只释放进程资源；`markProcessReleased` 不改变 phase、不删除行、不授权重跑 |
| 工具可以直接启用，没有真实 host gate/epoch | `FloeMacSelfHostGate` 必填 + `FloeMacSelfFencedToolExecutor` 执行前检查 exact task epoch 与 stop |
| 测试 fixture 可能在未知状态下删除现场 | residual admission / inventory unavailable / shutdown failure 都保留 fixture；新增 `allowResidualAdmissions` 显式 opt-in |

**保留的协调者修复**：`FloeMacSelfCapabilityResolver` 的 duplicate descriptor 使用 `updateValue` 返回 typed error（不是 `Dictionary(uniqueKeysWithValues:)` trap）；fixture 的失败保留语义保留并加强。未修改 upstream。

## 2. Durable admission 语义

表在宿主私有数据库中，由 `bootstrap()` 在 upstream `migrate()` 之后安装；不改变 `user_version`，不修改 upstream 表：

```sql
floe_mac_self_admission(
  conversation_id PRIMARY KEY, run_id, phase, epoch,
  admitted_at, updated_at, owner_host_id, owner_pid,
  stop_requested_at, stop_epoch, previous_run_id, previous_phase, detail
)
```

phase：

- `admitting`：durable claim 已写，prepare 是否提交未知。崩溃 → 未知，不自动重试。
- `prepared`：prepare 已提交且精确身份已核对；尚无 dispatch intent。
- `starting`：dispatch intent 已 durable 记录。从这一刻起崩溃/超时都按未知处理。
- `settledConfirmed`：严格 terminal probe 通过。
- `settledUnconfirmed`：session 结束但无严格终态证明；继续阻塞自动重试。

`admit` 只有在**前一条记录的 run 通过严格 probe**且该 conversation 没有其它非终态 run 时，才允许替换；否则 `.admissionUnknown`。`abandonUnstartedAdmission` 只允许宿主显式清除 `admitting` 且没有 run/message 行的记录。

**跨进程限制**：authority lock 和 admission 表只约束使用同一代码/同一 lock 路径的协作实例。直接打开同一 SQLite 文件的非协作写入者不受约束；SQLite 只保证文件一致性，不保证逻辑单 run。该数据库必须是 self-core 私有的，不应与 iOS App、旧版本或其它 helper 共享。

## 3. 终态证明

`FloeMacSelfDurableRunProbe` 在一个 reader/同一 writer 事务中读回：

- run 行存在、conversation 匹配、state 是 `completed/failed/checkpointed/interrupted/cancelled/canceled`、`ended_at` 非空；
- launch 的 user message 存在（若传入 expected id 则必须精确匹配 role/run/conversation）；
- completed：最高 terminal event 的 `stopReason` 合法且非 `cancelled`；terminal 之后没有 status 行；`finalMessageID` 必须解析为 exact run/conversation 的 assistant 行且内容非空；没有 `finalMessageID` 时必须存在 terminal 前的 `noFinalText` error marker；
- failed/checkpointed 等：最高匹配 state 的 status 行存在，且之后没有 status/terminal 冲突；
- `abortedBeforeDispatch` 仅由组合层在证明未 dispatch 后写入，outcome 为 `.abortedBeforeDispatch`。

无法证明 → `confirmed=false` + stable reason code；session 不释放 claim。release 只在 `receipt.confirmed` 时发生。

## 4. Run fence、stop 与 approval

- `FloeMacSelfRunFence` 的锁只覆盖几条同步语句，**不跨** `startPrepared`、数据库 await 或工具执行。
- `recordStopIntent()` 在任何 await 之前同步执行；随后 durable `recordStopIntent` 写入。
- `runStart`：`prepareDispatch` → durable `requestDispatch`（prepared→starting）→ stop 复核 → `commitDispatch` → `startPrepared`。任一步失败/stop 都不调用运行时。
- dispatch 前 stop：`abandonBeforeDispatch` 验证 run 仍为 `preparing`、只有 preparing status、无 assistant/tool/usage/terminal，写 `failed` + `abortedBeforeDispatch` status，然后确认回执。
- dispatch 后 cancel：启动现有 `service.cancel()`，有界等待；confirmed → `.stopped`/`.terminalUnconfirmed`；超时 → `.dispatchUnknown`，保留 admission 和 session。
- approval：工具 bindings 有效、run 未结束、fence 处于 dispatching/无 stop 才发 token；`service.snapshot()` 后复核 token，再在无 suspension 的紧邻位置转发；stop/settlement 后返回 `.sessionEnded`。

## 5. 工具 gate / epoch

`FloeMacSelfToolBinding` 新增必填 `hostGate: FloeMacSelfHostGate`。`FloeMacSelfCapabilityResolver.validateHostGate` 只验证：

- 非空且有界的 issuer/approvalPolicySource/toolCorpusIdentifier；
- workspaceID 等于 boundary workspace；
- workspaceRootPath 等于 symlink-resolved boundary root；
- approvedToolNames 精确等于 allowedToolNames。

**这不是认证**：组合层不能证明宿主真的取得 workspace 授权，也不能证明审批源/corpus 可信。宿主必须从自己的可信路径构造 gate；否则不要启用工具。`FloeMacSelfFencedToolExecutor` 在每次执行前检查 exact `FloeMacSelfTaskEpoch`、allowed set、descriptor、fence stop/epoch，然后检查 runtime cancellation。已经开始的副作用无法追溯取消。

## 6. 并发 shutdown 与 close

- `shutdown` 的并发调用共享一个 `Task`；`shuttingDown` 在创建任务前同步设置。
- `shutdown` 先 join bootstrap，再等待 in-flight admission/close 清空；超时则失败关闭，不关闭数据库。
- active session 先按 `cancelActive` 取消并确认；所有 session close 成功后才关闭 DB。
- 关闭前读取 unresolved admission 列表（失败则 `admissionInventoryAvailable=false`）；shutdown **不清理**这些行。
- `allowUnconfirmed=true` 只允许 close 释放进程对象；`markProcessReleased` 只改 `settledUnconfirmed` 的 detail/time，不改 phase，不删行。
- `close` 对任何未确认终态（包括 `startFailed`）都要求显式 `allowUnconfirmed`；不再有“startFailed 自动放行”。

## 7. 测试源码

新增/更新：

- `AuthorityAndAdmissionTests.swift`
  - 真实子进程（`/usr/bin/perl` flock）验证跨进程互斥；0600；symlink 拒绝；路径替换检测；两个 runtime 同一 DB 互斥。
  - admission CAS phase/stop epoch/settlement；pre-prepare 崩溃阻塞 + 显式 reconciliation；dispatch-intent 崩溃阻塞 + shutdown 保留；
  - confirmed terminal replacement；并发 shutdown 串行化。
- `DurableProbeTests.swift`
  - bare terminal 无 final proof → unconfirmed；final message 缺失/不匹配 → unconfirmed；exact final proof → confirmed；noFinalText → confirmed 但无 final answer；
  - checkpointed → confirmed interrupted；mismatched status → terminal_state_conflict；ended_at 缺失 → unconfirmed。
- `FenceAndTaskEpochTests.swift`
  - stop-before-dispatch；approval token 失效；wrapper 在 stop/stale epoch 后拒绝且 executor 不再执行；dispatchStarted 保留；host gate 结构校验。
- 现有 `RuntimeLifecycleTests` 增加 finalMessageVerified / durableAdmissionRetained 断言。
- 现有 `ApprovalAndToolsTests` 增加 mismatched host gate 在 durable admission 前失败，以及 duplicate model 身份漂移后无 non-terminal run / 无 unresolved admission 的断言。
- `SelfCoreTestSupport.swift` 增加 host gate、唯一 evidence root、seeded DB、static provider binding；fixture 在 residual admission/inventory unavailable 时保留现场。
- `FixtureCleanupTests.swift` 更新 shutdown receipt 字段，保留失败/已关闭/未确认的现场。

所有 fixture 使用唯一 UUID 临时目录；可能产生 unresolved admission 的测试使用 `makeSelfCoreEvidenceRoot` 并**故意保留**现场，不删除。

## 8. 本次实际执行的检查

只执行了**语法 parse**（不是编译/类型检查）：

```bash
cd FloeMacSelfCore/Sources/FloeMacSelfCore
for f in *.swift; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse "$f"
done

cd FloeMacSelfCore/Tests/FloeMacSelfCoreTests
for f in *.swift; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse "$f"
done
```

结果：本次运行每个文件 exit 0（无输出）。证据记录在 `Evidence/20261117/`。`swiftc -parse` 只解析语法，不解析 import、不做类型检查、不链接、不执行。

**未执行**：`swift build`、`swift test`、依赖解析/checkout、真实 provider/tool/UI/Simulator/设备、Git commit/tag/push、签名/发布。

## 9. 仍需协调者决定/授权

1. **编译窗口**：内部 SSD 约 22 GiB；完整构建要求 ≥30 GiB。需要协调者批准串行 scratch 窗口后，先 `swift build` 再 `swift test`；不要直接以 parse 通过声称可构建。
2. **模块布局**：本 package 同时 vends `FloeCore`/`FloeModels`/.../`FloeAgentRuntime`；宿主不能同时链接 `FloeAgent` package 的同名 product。`FloeMacGoal` 内部还有一个只含 `Digest.swift` 的 `FloeCore` target，若进入同一 package graph 会重复模块。必须二选一或让 `FloeMacGoal` 复用本 package。
3. **durable owner 进程**：必须放在长生命周期 host（`FloeMacHost` 或专用 helper），不能放在会被强制终止的 Catalyst UI child。跨进程 API/退出所有权未实现。
4. **真实 provider**：宿主必须加载 canonical `ProviderProfile`/`ModelProfile` 并提供真实 adapter/credentials。本包不持久化、不打印、不代理凭据。
5. **真实工具**：宿主必须提供真实 executor、现有 ApprovalPolicy、非可选 gate、真实 AuditSink、精确 allowedToolNames 和 host gate。当前只验证组合与拒绝路径；没有执行真实工具。
6. **Workspace 记录**：工具启用的 run 需要已存在的 workspace row；`FloeMacSelfTaskBoundary.workspaceID` 必须等于 prepared workspace；root 由宿主验证为真实目录。本包不解析 security-scoped bookmark。
7. **History/Compaction**：仍用 `ConversationHistoryAssembler`；没有注入 `ConversationContextCompactionStore`。
8. **数据库选择/迁移/备份**：本包只接受宿主显式 SQLite 路径，父目录必须已存在；`bootstrap()` 不选择 App 数据库，不迁移用户数据库。是否复用/备份由协调者决定。
9. **Goal/Plan/UI/恢复**：未接入。
10. **非协作写入者**：见 §2；这是明确的限制，不是已解决保证。

## 10. 清理/越界写入事件

- 上一轮的 `Evidence/20261117/CLEANUP_INCIDENT.md` 保留：固定名临时目录曾被执行 `rm -rf`，无法证明删除前内容归属。
- **本轮新增越界写入**：为记录 dirty 路径，我曾执行 `... > /tmp/floe_dirty_now.txt`，在 `FloeMacSelfCore/` 之外创建了一个固定名文件。该文件未被后续删除或修改；只读 `stat` 显示 `birth=modify=change=2026-11-17 01:59:56`，与命令时间一致，证据见 `Evidence/20261117/TMP_WRITE_INCIDENT.md`。我没有读取或复制其内容；它不是交付物。此后所有写入限定在 `FloeMacSelfCore/`。
- 本次没有执行任何 `rm`/`rmdir`/trash 或清理；只写入 `FloeMacSelfCore/` 内的源码、测试、README/HANDOFF/MANIFEST 和 evidence 文本。唯一保留的 `.build/` 是上一轮 `swift package describe` 的元数据，未清理。
