# FloeMacSelfCore

> **2026-11-17 当前验证：** Xcode 27.2 已实际对象编译 `FloeAgentRuntime` 和 `FloeMacSelfCore` 目标；后续新增的账本安全修复也在定向测试构建中编译，8 项内存 SQLite 定向安全测试通过。详见 [组合层构建证据](Evidence/selfcore-target-build-20261117.md)和[账本测试证据](Evidence/request-journal-safety-20261117.md)。账本的 dispatch 和终态确认仍明确不可用，保留的正向测试尚未实现；完整测试、真实宿主、授权和 provider 运行均未验证，生产 gate 不得开启。

> **2026-11-17 历史验证：** authority 文件系统基础曾单独进行 Swift 6 对象编译及合成测试；随后完整包编译因 `sessions` 声明缺失失败，原始失败和组件结果见 `Local/Scratch/floe-mac-selfcore-authority-evidence-20261117-C9D65DC8/`。声明已补回，后续构建结果以上方当前证据为准。生产 gate 依然关闭，启动、关停、取消、审批与恢复竞态仍须修复和实际验证。

> 2026-11-17 用户已确认 Mac、Linux 都采用现有 Floe 自研核心。共享领域、Linux 平台边界和独立同步见[当前方案](../docs/FLOE_SHARED_SELF_CORE_AND_TASK_SYNC_20261117.zh-CN.md)。本包仍是 Mac 宿主组合原型，以下启动保护和未验证项继续有效；本次路线确认不表示 Linux 适配已完成。

> **2026-11-17 第二轮安全修复：仍然禁止接入实际 App 或执行任务。**
> 本包仍是**源码状态**：未编译、未类型检查、未链接、未运行任何测试、未解析依赖、未连接 Mac App/Bridge、未执行真实 provider 或工具。下文描述的是本次修复后的目标语义与已写入的回归源码，不是已观测的运行保证。
> 随后的独立复核发现锁文件所有权和数据库别名风险，以及启动、停止与审批仍存在竞争。协调者已让 authority lock 在打开任何路径前直接拒绝；因此 runtime 当前无法初始化。不得移除保护，直到这些问题修复并完成适当验证。

Floe Mac 自研运行时的**组合层**。它把现有的 Floe Swift 运行时接上 Mac 宿主，不实现第二套 agent loop、第二套审批策略或第二套持久化模型。

当前阶段只支持 **普通聊天会话（chat）** 和 **macOS 原生宿主**。Goal/Plan、附件/图片、自动恢复、真实 provider 推理、真实工具执行、Mac UI 和跨进程 IPC 均未完成或未验证；相关入口失败关闭。

## 本次修复的核心

1. **durable 会话准入**：宿主私有数据库新增 `floe_mac_self_admission` 表，每个 conversation 一行，phase 为 `admitting → prepared → starting → settledConfirmed / settledUnconfirmed`。每次迁移都是一次短小的 `(conversation_id, run_id, epoch)` CAS 写事务；不嵌套 `SQLiteRunLaunchStore.prepare` 的写事务，不修改任何 upstream 表或 migration。
2. **崩溃对账**：durable claim 之后、prepare 之前崩溃，或 prepare 之后、dispatch 之前崩溃，都会留下 unresolved 行；新进程**不会自动重放**。只有前一条 run 通过了严格 durable terminal 证明，才允许替换同一 conversation 的 admission。`abandonUnstartedAdmission` 只允许宿主显式清除“仍处于 admitting 且没有 run/message 行”的记录。
3. **跨进程 authority lock**：数据库旁的 `.floe-self-authority.lock` 由 `FloeMacSelfAuthorityLock` 以 `O_NOFOLLOW`、0600、单 link 方式创建并持有 `flock`；路径 inode 在每次 admission 前重新验证，路径被替换/删除会失败关闭。
4. **run fence + 真实任务 epoch**：`FloeMacSelfRunFence` 只在短临界区内持锁，记录 stop intent 与 stop epoch；`startPrepared` 之前必须先 durable 写 `starting` 并 `commitDispatch`，之后才可调用运行时。stop 在 dispatch 前到达时不会启动运行时，而是走可证明的 `abortedBeforeDispatch` 结算。
5. **严格终态证明**：`FloeMacSelfDurableRunProbe` 只接受 exact run + terminal state + 匹配的 terminal/status payload；completed run 还必须证明 `finalMessageID` 对应的 assistant message（同 run、同 conversation、assistant role、非空内容）或运行时写下的 `noFinalText` 标记。缺任何证据都保持 unconfirmed，不释放 claim。
6. **工具边界**：工具启用必须提供显式 `FloeMacSelfHostGate`（workspace id/root、精确 tool set、审批源和 corpus 标识）。它只是宿主声明，组合层只验证一致性，不认证宿主。`FloeMacSelfFencedToolExecutor` 在执行每个工具前检查 exact task epoch 和 stop；没有工具绑定时仍是 deny-only policy + 空 descriptor executor。
7. **串行关停**：并发 `shutdown` 共享一个任务；设置 `shuttingDown` 后阻止新 admission/close，等待 in-flight admission/close 与 bootstrap 结束，关闭所有 session 后再关闭数据库。`allowUnconfirmed` 只释放进程资源，不改变 durable phase、不清除 claim、不授权重跑。

## 它实际做什么

1. 宿主显式提供一个 SQLite 数据库文件；`init` 先取得 authority lock，再打开数据库。`bootstrap()` 调用现有 `DatabaseManager.migrate()`，确认 schema 为当前版本后安装 self-core authority 表，然后构造 `SQLiteRunLaunchStore`、`SQLiteConversationStore`、`SQLiteRunStore`、`SQLiteRunCheckpointStore`。
2. `startSession` 校验 provider/model/tool binding（包括 host gate），在写任何 durable run 之前完成能力校验；然后取得 durable admission，调用现有 `SQLiteRunLaunchStore.prepare(...)` 原子写入 conversation/workspace/run/user message，再核对精确身份。
3. 用 prepared 的同一组身份构造现有 `ConversationRunService`，并调用 `startPrepared(goal:userMessageID:)`；不会重新生成 conversation、run 或 user-message ID。
4. 原样转发现有 `ConversationRunService.events()` 的 `HarnessEvent`，并额外给出事实性的 `.prepared` / `.startFailed` / `.ended` 生命周期事件。事件仍有界、可丢、无 replay。
5. 审批命令必须同时携带 `conversationID`、`runID`、`workspaceID`、`callID`、`toolName`；只有与当前 live snapshot 的 pending approval 完全一致、且 stop/epoch fence 仍有效时才转发给现有 `resolveApproval(_:for:)`。
6. `cancelAndWait` 立即记录进程内 stop intent，并尝试 durable 记录；dispatch 尚未开始时等待可证明的 `abortedBeforeDispatch` 结算；dispatch 可能已开始时调用现有取消路径。超时返回 `.dispatchUnknown`，保留 admission，不伪装成 cancelled/finished。
7. `close`/`shutdown` 只有在严格 terminal receipt confirmed 时才正常释放；未确认终态需要显式 `allowUnconfirmed`，且只释放进程资源。

## 关键安全边界

- **没有默认 provider / 默认工具 / 默认权限。** 生产 `startSession` 必须注入真实 `ProviderAdapter`、provider/model profile 和 credentials。没有工具绑定时，`toolsEnabled=false`，使用 deny-only policy 与无 descriptor 的 executor。
- **工具启用的前置条件**：现有 `CatastrophicActionGate` 非可选；`allowedToolNames` 非空且有界；每个 descriptor 必须存在、不能需要 host scope、不能 child-only、不能是 `user.ask`；boundary workspace 必须等于请求 workspace；`FloeMacSelfHostGate` 的 workspace/root/tool set/审批源/corpus 必须一致。失败发生在 durable admission 之前，不会留下 run 或 admission 行。
- **工具 gate 不是认证。** 组合层无法证明宿主真的取得了 workspace 授权、审批源可信或 corpus 未被替换；它只拒绝内部不一致的声明。宿主必须从自己的可信授权路径构造 gate。本阶段不是用户可用的工具能力。
- **一个 conversation 同时只有一个 unresolved/live admission。** 进程内 `FloeMacSelfConversationClaims` 仍防止同一进程的重复 start；跨实例/重启用 durable admission 行裁决。旧 run 的 late close 不能释放新 run 的 claim。
- **未知就未知。** `startFailed`、unmatched terminal、dispatch 后超时、prepare 后身份不一致且无法证明未 dispatch、settlement 写失败，都保留 unresolved admission 或 unconfirmed receipt；不会自动重试、不会清除、不会用事件流代替 durable 证明。
- **事件流不是完成证明。** 上游 `HarnessEventChannel` 和本层 channel 都是 newest-bounded、无 replay。`snapshot + stream` 不是原子重放；消费者必须用 durable reads 对账。`.ended` 的 `confirmed=true` 才表示 run 行 + terminal 记录 + final message 证明都已读回。
- **取消语义沿用现有运行时。** 用户 stop 的真实 durable 终态是 `checkpointed`（receipt outcome 为 `.interrupted`），不是伪造的 `.cancelled`。dispatch 前 stop 由组合层写入 `failed` + `abortedBeforeDispatch` 状态，outcome 为 `.abortedBeforeDispatch`。
- **durable owner 必须在长生命周期 host 进程。** `FloeMacSelfHostIdentity.processIdentifier` 在 runtime 创建时校验；这只是进程内检查，不是代码签名、OS 认证或审批源认证。当前 Mac Catalyst UI helper 会被强制终止，不能把本层放进 UI 子进程；跨进程 IPC/退出所有权未实现。
- **跨进程限制（必须明确）**：authority lock 和 admission 表只约束使用同一 self-core 代码与同一 lock 路径的实例。任何直接打开同一 SQLite 文件的非协作写入者（旧版本、iOS App、测试 helper、其它工具）不会被阻止，仍可能创建并发 run 或修改 run 行。不要把该私有数据库与其它写入者共享；SQLite 自身只保证文件一致性，不保证逻辑上的单 run。

## 公共接口（源码示例，未编译验证）

```swift
let owner = FloeMacSelfHostIdentity(displayName: "Floe Mac")
let runtime = try FloeMacSelfRuntime(
    databaseURL: databaseURL,   // 宿主显式选择；父目录必须已存在
    owner: owner
)
_ = try await runtime.bootstrap()  // migrate + self-core authority schema

let handle = try await runtime.startSession(
    FloeMacSelfSessionRequest(goal: "Hello", mode: .chat),
    provider: providerBinding,   // 真实 adapter + credentials
    tools: nil                   // 默认无工具
)

for await event in handle.events() { /* .harness / .ended / .startFailed */ }
let terminal = await handle.waitForTerminal(timeout: 30)
let close = try await handle.close()
```

工具启用时（**必须**有宿主 gate）：

```swift
let boundary = FloeMacSelfTaskBoundary(
    workspaceID: workspaceID,
    workspaceRootURL: workspaceRootURL,
    allowedWorkspacePaths: [],
    ownership: .nativeHost
)
let tools = FloeMacSelfToolBinding(
    executor: realExecutor,          // 宿主真实实现
    policy: HumanApprovalPolicy(),   // 现有 Floe policy
    gate: try CatastrophicActionGate.withBundledPatterns(),
    auditSink: realAuditSink,
    boundary: boundary,
    allowedToolNames: ["workspace.readFile"],
    hostGate: FloeMacSelfHostGate(
        workspaceID: workspaceID,
        workspaceRootPath: workspaceRootURL.resolvingSymlinksInPath().path,
        approvalPolicySource: "host.approval-policy.v1",
        toolCorpusIdentifier: "host.tool-corpus.v1",
        approvedToolNames: ["workspace.readFile"],
        issuer: "host.process"
    )
)
```

宿主对账/查询：

```swift
let unresolved = try await runtime.unresolvedAdmissions()   // 自动重试必须保持阻塞
let record = try await runtime.admissionRecord(conversationID: conversationID)
try await runtime.abandonUnstartedAdmission(
    conversationID: conversationID,
    runID: record!.runID,
    expectedEpoch: record!.epoch
) // 只允许 admitting 且无 run/message 行的显式清理
```

## 明确不支持 / 未验证

- **未编译/未类型检查/未链接/未运行测试**。本次只做了 `swiftc -parse` 语法检查和只读源码审查；上游 9 个 target 在本 package 的完整 typecheck、GRDB 7.8.0/swift-asn1 1.7.1 解析、测试执行都没有发生。
- Goal / Plan、continuation/pause/edit、附件/图片、compaction store、恢复/续跑、Mac UI、审批卡、事件消费、跨进程 IPC。
- 真实 provider 推理与错误路径；真实工具执行（文件、shell、媒体、远程、Office/CAD）。
- 工具执行期间的强制撤销：wrapper 在 dispatch 前检查 epoch/stop，运行时 cancellation 也检查；但一个已经开始的副作用无法被追溯取消。没有持有锁跨越整个工具执行。
- authority lock 不能抵御对父目录有写权限的恶意进程替换 lock 文件；`verifyHeld()` 会在下一次 admission 前发现并失败关闭，但不能追溯阻止已经并发完成的写入。非协作 SQLite 写入者不受约束。
- 与 `FloeMacGoal`/`FloeMac` 的最终模块布局、真实用户数据库的选择/迁移/备份、签名与分发。

## 包结构与新增文件

`Sources/` 下的 9 个目录是指向 `FloeAgent` 原始源码的目录符号链接；本包不复制或修改 upstream 文件。

新增 self-core 源码：

| 文件 | 作用 |
| --- | --- |
| `FloeMacSelfAuthorityLock.swift` | 0600/no-follow/flock/路径 inode 验证 |
| `FloeMacSelfAdmission.swift` | authority 表、CAS phase、严格 terminal probe |
| `FloeMacSelfRunFence.swift` | 短临界区 run fence、stop epoch、dispatch 记录 |
| `FloeMacSelfHostGate.swift` | 宿主工具声明 + task epoch/stop wrapper |
| `FloeMacSelfRuntime.swift` | 组合根、admission 接入、串行 shutdown |
| `FloeMacSelfSession.swift` | 单 run 生命周期、严格回执、审批/stop fence |

原有 `FloeMacSelfError.swift`、`FloeMacSelfIdentity.swift`、`FloeMacSelfCapabilities.swift`、`FloeMacSelfSessionRequest.swift`、`FloeMacSelfEventChannel.swift`、`FloeMacSelfApproval.swift`、`FloeMacSelfDeniedCapabilities.swift`、`FloeMacSelfCoreExports.swift` 继续提供公共类型/请求/事件/deny-only 能力。

## 回归源码

- `RuntimeLifecycleTests`：真实 `prepare` + `startPrepared` + durable completion；final message 证明；bootstrap/relaunch。
- `OwnershipAndTeardownTests`：同 conversation claim、close/shutdown 栅栏、审批中取消、并发 shutdown。
- `ApprovalAndToolsTests`：allow/deny、错误身份拒绝、duplicate descriptor、host gate 不一致在 durable 写入前失败、host scope/environment/model/adapter/boundary、跨 session 审批、duplicate model 身份漂移后的 aborted settlement。
- `AuthorityAndAdmissionTests`：跨进程 lock（真实子进程）、symlink/路径替换、admission CAS、pre-prepare 崩溃、dispatch-intent 崩溃、confirmed replacement、并发 shutdown。
- `DurableProbeTests`：bare terminal、最终消息缺失/不匹配、exact final proof、noFinalText、checkpointed/mismatched status、ended_at 缺失。
- `FenceAndTaskEpochTests`：stop-before-dispatch、approval token 失效、wrapper epoch/stop 拒绝、host gate 结构校验。
- `FixtureCleanupTests`：shutdown 失败/已关闭/未确认/residual admission 时保留 fixture。

## 构建/测试交接

**尚未运行**。内部 SSD 约 22 GiB，仓库要求 ≥30 GiB 才能开始完整 App/M00 构建；本包也必须由协调者批准专属 scratch 的串行命令。准备命令见 `HANDOFF.md`，但不要在本轮自行执行。

本次已执行的检查仅限：

- 每个新增/修改的 Swift 源文件和测试文件 `swiftc -parse`（语法通过）
- 只读 API/源码审查；未解析依赖、未编译、未测试

首要未知：9 个 upstream target 在 macOS SDK 上的完整 typecheck；`FloeAgentRuntime.Configuration` 命名解析；GRDB 依赖解析；真实 provider/tool/UI；以及本包与 `FloeMacGoal` 的模块布局冲突。
