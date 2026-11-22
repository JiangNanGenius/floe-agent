# FloeDesktopSync

日期：2026-11-16。状态：独立持久基础实现，未接入 iPad App 或 Mac/Linux/Windows 接入服务。

本包把[跨设备数据协议 v1 草案](../docs/FLOE_CROSS_DEVICE_DATA_PROTOCOL_V1_DRAFT.zh-CN.md)和[桌面与跨设备工程契约 v1](../docs/FLOE_DESKTOP_CROSS_DEVICE_CONTRACT_V1.zh-CN.md)中已经固定的数据语义落成可编译、可测试的 SQLite 持久层：稳定身份、命令幂等回执、执行代次、共同基线、持久变更游标、一致快照分页、可靠墓碑、持久冲突记录、完整快照清单与逐页摘要、有界入站暂存、范围专属订阅游标、已认证增量扫描区间，以及记录、冲突、游标与回执的单事务提交。

本轮新增已认证快照与增量协议：发送端从本机连续变更范围扫描并生成带 HMAC-SHA-256 证明的批次；接收端在应用前验证证明、已认证 peer、专属 scope 授权、订阅代次、精确起点和扫描终点，再在同一事务内应用变更、持久冲突、CAS 推进范围游标并保存有界重放回执。完整性摘要不等于身份认证：没有可信认证器时公开增量入口一律拒绝。

2026-11-17 用户已确认 Mac、Linux 共用 Floe 自研核心。本包保持独立，新增本地 run 来源投影事务；[当前共享核心路线](../docs/FLOE_SHARED_SELF_CORE_AND_TASK_SYNC_20261117.zh-CN.md)与 Bridge、工作区同步分别定义职责。

它仍不实现网络配对、TLS/QUIC/WebRTC、密钥交换与持久化、文件分块续传、APNs、UI 或双端集成；也不复制任何 Harness/OpenCode 私有数据库。

## 已实现

| 能力 | 位置 | 语义 |
| --- | --- | --- |
| 稳定身份 | `Identifiers.swift` | `DeviceID`、`TaskID`、`RunID`、`WorkspaceID`、`CommandID`、`SnapshotID`、`EntityID`、`ConflictID` 等只接受规范 UUID；路径派生字符串拒绝进入稳定身份。 |
| 首次打开身份 | `SyncStore.ensureIdentity` | 单事务 `INSERT OR IGNORE` 后立即读取核对；两个不同设备并发首次打开同一新库时只有一个身份获胜，失败方看到获胜身份并拒绝打开。 |
| 命令清单 | `SyncStore.accept` | 先持久保存 `commandID`、载荷摘要和完整意图摘要，再允许调用方执行。同 ID 同意图返回原回执；同 ID 不同载荷/种类/作用域/代次/目标记录返回冲突。 |
| 回执状态 | `CommandState` | `accepted`、`started`、`completed`、`failed`、`cancelled`、`outcomeUnknown` 分开保存；终态不可回退。旧代次的迟到终态不能覆盖新分支。 |
| 执行代次与入口绑定 | `establishExecutionHead` / `markStarted` | 每个 `runID` 只安装一个当前 epoch 与 owner。标记 `started` 时在同一写事务内核对认证设备、store 设备、当前 owner、run 的 taskID 和 epoch；`markStarted` 必须显式传入 `authenticatedDeviceID`。 |
| 预期修订 | `SyncCommand.expectedRevision` / `targetKey` | `expectedRevision` 必须同时指定 `targetKey`。执行开始时在同一事务内读取目标记录并比较实际 revision；不一致则拒绝开始。它是执行前置条件，不是对后续外部写入的 CAS。本地记录更新可用 `baseRevision`/`baseDigest` 做受事务保护的基线校验。 |
| 结果未知 | `recoverInterruptedCommands` | 重启后只把已 `started` 的命令改为 `outcomeUnknown`；`accepted` 但未开始的命令保持 `accepted`，不自动重试。迟到的真实结果可以一次性核对为完成/失败/取消。 |
| 记录变更与共同基线 | `commitLocalRecord` / `commitLocalRecords` | 单条或一组本地任务/执行/消息记录与 append-only 变更行同事务提交；整批失败则全部回滚。批次限制记录数和累计 payload 字节，拒绝重复身份及非本机 origin。本地连续写入会记录实际当前行作为 `baseRevision`/`baseDigest`，供对端证明因果。 |
| 自研核心来源投影 | `applyLocalRunProjection` / `runProjectionCheckpoint` | 可信宿主提供已归一化记录与实际读取的 run 事件范围；在同一事务核对 task/run/owner/epoch、提交记录与变更、CAS 保存本机来源游标。重复范围同内容返回原回执，缺口/回退/换绑定/不同内容拒绝；检查点不进入设备同步。实际 RunStore 生产者尚未接入。 |
| 入站增量批次 | `applyAuthenticatedIncrementalBatch` | 新入口只接受已认证、已授权、精确起点与连续扫描终点的批次；认证失败、无授权、代次不符、缺口、回退、重放不同内容或结构性越界都在写入前拒绝。两个旧入口 `applyRemoteBatch` / `applyScopedRemoteBatch` 仍明确拒绝。 |
| 认证边界 | `IncrementalAuthenticator` / `HMACIncrementalAuthenticator` | 认证发生在不可信载荷之外：可执行真实验证的 HMAC-SHA-256 证明按 `(peer, keyID)` 查密钥并校验精确批次摘要；没有安装认证器时公开增量入口拒绝。布尔值、调用方自述 peer 或裸 SHA-256 摘要都不能通过。 |
| 范围授权 | `grantScopeAccess` / `revokeScopeAccess` | 本地用户按 `(peerDeviceID, scope)` 显式授权；授权不会从快照、批次或另一台设备推导。撤销会原子撤销授权、丢弃相应暂存和回执、清除订阅游标并换用不可预测的新代次；已可见记录保留，重新授权后必须建立新快照。 |
| 连续扫描与墓碑 | `nextIncrementalBatch` | 发送端按本机变更序号扫描连续区间，只保留目标 scope 的记录，包含显式墓碑；`throughCursor` 是实际检查到的区间末尾，不是最大匹配事件。异 scope 变化形成允许的空洞，过滤后为空的区间仍可推进游标。 |
| 重放回执 | `incremental_receipts` | 每个 `(peer, scope, version, from, through)` 保存内容摘要与小结果；完全相同内容的重试返回原结果并标记 `isDuplicate`，同区间不同内容拒绝。每个订阅只保留近期回执，超出窗口的旧重放按缺口拒绝。 |
| 持久冲突 | `commitSnapshotImport` / `conflicts` / `resolveConflict` | 被拒绝的远端版本不会只在内存返回：双方完整记录、摘要、原因、观察游标和状态在同一事务写入 `conflicts`。崩溃重启后仍可读取，并由调用方显式 `keepLocal` 或 `acceptRemote`；本地已变化时 `acceptRemote` 报 `conflictStale`。 |
| 变更游标 | `changes(after:)` / `pruneChanges` | 游标是本地序号，不是时钟。过期检查、修剪位置读取和分页查询在同一 SQLite 读事务内完成，另一连接并发 prune 不会造成静默缺页。已修剪范围以前的游标报 `cursorExpired`。 |
| 分页内存边界 | `changes` / `snapshotPage` | 条数和累计 payload 字节同时受限；超预算时返回当前页并在下一页继续，不丢行。 |
| 一致快照（发送端） | `openSnapshot(scope:)` / `snapshotPage` | 在单事务内冻结明确范围（全部/任务/工作区）的记录到 `snapshot_entries`，返回 `baseCursor`。分页只读冻结行；有效性检查、token 校验和分页查询在同一读事务内完成。 |
| 完整快照清单 | `snapshotManifest` / `SnapshotManifest` | 为冻结快照生成零基、连续的页清单：每页起始/结束 position、条数、payload 字节和页摘要；根摘要覆盖 snapshotID、已认证来源设备、scope、baseCursor、计数、时间与全部页摘要。清单可规范 JSON 往返，接收端持久保存并在每次使用前重算校验。 |
| 发送页信封 | `snapshotPageEnvelope` | 按清单的固定 position 范围取页，重新计算页摘要后返回 `SnapshotPageEnvelope`；冻结数据与清单不一致时拒绝发送。 |
| 入站快照暂存 | `beginAuthenticatedSnapshotImport` / `receiveAuthenticatedSnapshotPage` | 将认证的 manifest、peer、scope、订阅版本和 baseCursor 持久成一个 staging 会话；每一步都校验认证和本地授权。每页与导入计数在同一写事务内提交；重复同内容页幂等，不同内容同页冲突；乱序、缺页、摘要不符、跨 peer/scope 与重复记录拒绝。暂存数据不进入 `records`/`changes`，不推进任何游标。 |
| 快照范围与订阅版本绑定 | `sync_subscriptions` / `beginAuthenticatedSnapshotImport` | 订阅键为 `(peerDeviceID, scope)`，携带调用方协商的 `subscriptionVersion`。版本不匹配的快照不能暂存或提交；显式 `resetSubscription` 用更高版本废弃旧代次，旧可见记录保留，订阅游标重置且必须重建基线。同 peer 新增 scope 会建立独立订阅行，不能复用另一 scope 的快照。 |
| 快照提交 | `commitAuthenticatedSnapshotImport` | 只有全部页、计数、position、页摘要、manifest 根摘要和 scope 归属重新核验通过，才在一个事务中发布可见记录、墓碑、持久冲突、未对账本地记录报告和对应范围游标。失败或取消回滚整个事务，旧记录、旧冲突和旧游标不变。 |
| 范围集合对账 | `commitSnapshotImport` / `SnapshotImportResult.unreconciledLocalKeys` | 快照内显式墓碑会按因果规则应用。不在完整快照中的本地行不会被缺页推断为删除：无论本地是否 dirty 都保留，并持久写入提交回执的 `unreconciledLocalKeys` 供上层核对。源端从未见过的本地记录因此不会因一次完整集合而被静默清除。 |
| 本地脏数据保护 | `commitSnapshotImport` | 本地未确认修改与不同远端内容冲突，远端版本进入持久冲突，本地行保留。本地脏行与快照内容完全相同且 revision 相同时会被确认并清除 dirty；不同内容不会被快照覆盖。显式 `acceptRemote` 才替换，且已有实体不允许通过入站数据或冲突解决改变 task/workspace。 |
| 范围增量与独立游标 | `applyAuthenticatedIncrementalBatch` / `nextIncrementalBatch` / `subscription` | 每个 `(peer, scope)` 保留独立代次与游标。完整快照建立初值后，已认证批次必须从该精确游标连续推进；CAS、变更、冲突和回执同事务提交。 |
| 暂存边界与过期 | `SyncStoreConfiguration` / `pruneExpiredSnapshotImports` | 限制并发 staging 快照数、单清单 entries/pages、单页大小、全部 staging 的 payload 字节（限制另计每行固定元数据开销）、条目与页总数；会话按本地生命周期和发送端过期时间取较早者失效。`snapshotImportStatus` 可恢复查看已收页数/payload 字节，`abortSnapshotImport` 只丢弃暂存。 |
| 设备本地数据 | `setLocalWorkspaceBinding` | 根路径、书签只存本地表，快照/变更查询完全不读取；不进入协议载荷字段。 |
| 旧 Bridge 映射 | `registerLegacyBridgeIdentifier` | 路径派生 ID 作为设备本地别名显式映射到稳定 ID，不写入 `records`/`changes`，不做全局唯一。 |
| 数据库安全边界 | `SyncStore.init` | 默认要求数据库目录 owner-only（0700；目录不存在时创建），数据库和 WAL/SHM 设为 0600，拒绝符号链接路径。POSIX 权限不可用的平台可显式关闭该检查。 |
| 入口资源上限 | `SyncCommand(wireJSON:)` / `validateBatch` / `beginSnapshotImport` / `IncrementalBatch` | 先限制原始 wire 字节和 JSON 节点数，再解析/哈希；批次、增量帧、快照页、清单和 staging 分别限制记录数、累计 payload 字节和页字节；增量回执按订阅保留最近 N 条。 |

绝对路径、书签、Keychain 内容、凭据和设备权限没有可同步字段。`PortabilityPolicy` 对载荷中的 `rootPath`、`bookmark`、`credential`、`accessToken`、`devicePermissions` 等键递归拒绝；工作区记录的逻辑路径只接受相对路径，反斜杠、盘符、`..`、`~` 和 `file://` 均报冲突而不静默改名。

## 入站快照协议语义

### 身份、范围与版本

1. 宿主在配对后把每个 peer 的独立密钥注册到 `HMACSnapshotAuthenticator`，并单独在本地授予 `(peer, scope)`；清单、页和远端自述都不能创建授权。认证标签覆盖接收设备、key ID 和完整清单摘要，清单绑定来源、scope、版本、基线、页及内容摘要。公开旧快照入口一律拒绝；begin、page、commit 每次验证标签，并在其写事务中核对授权、持久清单和订阅版本。
2. 不同 peer 不得使用相同或 HMAC 等效的密钥。内置认证器在快照、增量注册表之间检查此限制；自定义增量认证器及不同进程的凭据管理由宿主保证隔离。安装认证器、授权、撤权、reset、查询状态、abort 和清理是本地特权管理操作，不能直接映射给不可信网络调用者。
3. 撤权原子清理本 scope 的暂存与回执、清除游标并产生新的不可预测递增版本；重新授权必须使用新代次和快照。版本空间不足时拒绝重新授权，必须使用新的配对身份。显式 reset 也使旧代次的暂存和证明失效；宿主必须将当前代次通过认证握手交给来源。已可见记录不会删除。
4. 完整快照只建立一个基线，不表示已经追平。来源可把旧冻结快照包装进新版本，因此版本与有效 HMAC 本身不能证明快照新鲜或来源诚实。宿主必须核实从基线到可信目标水位的增量历史仍可连续取得并完成认证续传；历史过期、缺口或无法确认目标水位时不能声明已追平，应重新捕获快照。
5. 本包不实现网络配对、密钥分发或多进程凭据同步。HMAC 只能证明配置密钥的持有者；换钥、撤销或重配对时宿主须同步停用所有旧 store/进程中的认证器并撤销 scope，避免旧进程继续持有过时凭据。
### 页顺序、幂等与完整性

1. `snapshotManifest` 生成固定页序列：页号从 0 连续递增，position 从 1 连续覆盖全部冻结行，记录顺序稳定。页边界由请求的 `pageSize` 和发送端页字节预算共同决定，并写入清单。
2. `SnapshotPageEnvelope` 携带 `snapshotID`、来源设备、页号、position 范围、有序记录和页摘要。接收端同时校验清单描述、信封字段、重算摘要、条数、payload 字节与 scope 归属。
3. 同一页重传：若已暂存页的内容摘要、position、条数和字节与信封完全一致，返回相同进度，不重复写入；若不一致，报 `snapshotPageConflict`，已有页和计数不被修改。
4. 页号大于下一个期望页报 `snapshotPageOutOfOrder`；页号小于期望且没有对应暂存页报冲突；跨页重复记录键、包内重复键和范围外记录均拒绝。
5. `commitAuthenticatedSnapshotImport` 不信任调用方“已收完”的声明。它在写事务内重新读取每个暂存页，逐页重算摘要，核对 1…entryCount 无缺口、记录/墓碑计数、总行数和 scope，再开始发布。缺少任何一页只报 `snapshotPagesIncomplete`。

### 原子发布与恢复

1. 提交和旧状态变更在同一个 `BEGIN IMMEDIATE` 事务内。任何一页校验失败、范围错误、写入失败或注入的崩溃点都会回滚：可见记录、`changes`、冲突、未对账回执和 scope 游标全部保持原值。
2. 暂存会话按页持久化。进程重启后 `snapshotImportStatus` 返回已收页数、条目数、字节和过期时间；继续接收剩余页即可。页事务中途崩溃只会丢失该未完成页，不会留下半页或推进计数。
3. `abortSnapshotImport` 只删除该 staging 会话；已存在的订阅、记录和游标不变。过期会话由 `pruneExpiredSnapshotImports` 清理，认证 begin 也会先清理过期 staging。
4. 提交成功时保留一条小的 committed 回执供重试返回相同结果；同一 scope 只保留最近一条快照回执，避免无限积累旧暂存数据。

### 墓碑与本地记录对账

1. 快照页包含显式墓碑（`deleted = 1`）。墓碑按与普通记录相同的 revision、dirty 和共同基线规则应用；已有本地脏行不会被墓碑删除，而是持久化为 `localUnsyncedEdit` 冲突并保留本地内容。
2. 完整快照没有列出的本地记录不会被当作删除。它们被保留，并出现在 `SnapshotImportResult.unreconciledLocalKeys` 和持久提交回执中。这包括本地 dirty、源端从未见过的本地创建，以及源端已删除但接收端仍有副本而快照未提供墓碑的记录。上层必须逐项核对后再决定发送、合并或显式删除。
3. 只有快照携带的墓碑能证明删除。缺页、范围不符或“看起来没有”不构成删除依据，避免一次残缺或恶意快照清空本地工作。

## 已认证增量协议语义

### 信任边界

1. 传输层必须先完成设备配对/连接认证，得到确定的 peer 身份，并把**该连接**与一组按 peer 注册的 HMAC 密钥绑定。配对、密钥交换、TLS/QUIC、密钥轮换和凭据存储不属于本包；本包只接受集成层显式安装的 `IncrementalAuthenticator`。
2. `HMACIncrementalAuthenticator` 用 `keyID` 查密钥，要求密钥登记的 peer 与批次声明的 peer 一致，并校验 HMAC-SHA-256。密钥只存在于集成层内存/凭据存储，不进入同步库、批次或日志；`SyncProofKey` 的 `description` 已脱敏。**每个设备对必须使用独立密钥**：HMAC 是对称证明，持有同一密钥的对端或第三方可以生成同一标签；不能用群组共享密钥，也不要把 HMAC 说成不可否认签名。测试使用固定夹具密钥，只证明协议验证逻辑，不证明真实配对或网络接入。
3. 批次中的来源 peer、接收设备、scope、订阅代次、起点、终点和每条变更都被证明覆盖；接收设备必须等于接收 store 的持久身份。`ContentDigest` 只是完整性摘要；把内容摘要当成标签、只比较摘要、或由调用方传入 `authenticated: true` 都不能通过。未安装认证器的 store 对所有公开增量输入抛 `incrementalAuthenticationUnavailable`。
4. 本地 scope 授权是独立于传输认证的用户决定：`grantScopeAccess(peerDeviceID:scope:)` 按 peer 与 scope 精确记录。设备 A 的授权不能让设备 B 通过；快照或批次不能创建授权；撤销同时使快照和增量旧代次失效，已提交记录保留，订阅游标需通过新快照重建。

### 版本与迁移

增量帧从 1.0 升为 1.1，并使用新的 HMAC 描述符域；1.1 必须携带 `receiverDeviceID`，来源应通过可信配对或会话确定。缺字段、1.0 旧证明和发给其他接收者的帧一律拒绝，不自动降级。此变更不更改其他同步协议的版本。双方必须同时支持 1.1；升级时先核对接收端持久游标，从该精确位置生成新的 1.1 帧。未获确认的旧帧不能直接重放；游标或历史无法确认时重建已认证快照。已有旧格式内容摘要回执不会被视为新格式证明；不得通过忽略回执冲突来恢复。认证器和配对密钥仍由宿主安全配置，设备对必须使用独立密钥。

### 发送端扫描

1. `nextIncrementalBatch` 在单个读事务内读取本机 `changes` 中 `(after, latest]` 的一段连续区间。它先按 `maxIncrementalScanRows` 确定实际检查终点，再过滤目标 scope 的记录；`throughCursor` 是该检查终点，不是最大匹配事件。
2. 目标 scope 的变化按 `sequence` 升序携带每条 `sourceCursor`，包含删除/墓碑。异 scope 变化形成允许的序号空洞；区间内没有目标记录时仍返回 `throughCursor > fromCursor` 的空变更批次，接收端会推进游标，证明“已扫描但无本范围变化”。
3. 记录条数、累计 payload 字节和单记录 payload 受 `maxBatchRecords`、`maxBatchBytes`、`maxPayloadBytes` 限制。达到预算时批次在最后一条已包含记录处结束，下一次从该 cursor 继续，不会用未检查的范围冒充 `throughCursor`。
4. 返回的批次默认无证明；集成层必须用配对密钥调用 `signed(keyID:key:)`。发送端从握手获得 `scope`、`subscriptionVersion` 和精确 `after`，不能自行猜测；批次来源固定为本 store 的设备身份；目的设备必须取自已认证配对/会话，并写入 `receiverDeviceID` 与证明。网络重试必须重发同一份已签名批次，而不是重新生成不同内容。

### 接收端校验与原子提交

`applyAuthenticatedIncrementalBatch` 按以下顺序失败关闭：

1. 结构校验：协议主版本、正数订阅代次、`fromCursor <= throughCursor`、变更 cursor 严格递增且都在 `(from, through]`、记录属于声明的 scope、墓碑与 task/workspace 归属合法、条数/字节/payload 上限。
2. 认证：安装的认证器验证精确批次摘要，返回的 peer 必须等于批次声明；本地设备不能作为自己的 peer。认证失败、无证明、未知 key、错 key、被篡改 payload 或摘要都拒绝。
3. 事务内：必须存在该 peer/scope 的本地授权、已由完整快照建立的订阅、完全一致的 `subscriptionVersion`，且 `fromCursor` 精确等于订阅当前 `appliedCursor`。`from < applied` 是重叠/陈旧重放，`from > applied` 是缺口，都不能推进。
4. 完整重放：相同 `(peer, scope, version, from, through)` 且内容摘要相同，返回持久回执并标记 `isDuplicate`；相同区间不同内容抛 `incrementalReplayConflict`。每个订阅只保留最近 `maxIncrementalReceipts` 条回执，超出窗口的旧重放按缺口拒绝。
5. 应用：所有变更按顺序应用，本地脏数据不会静默覆盖，冲突双方持久保存；随后用 `WHERE applied_cursor = from AND subscription_version = ? AND established = 1` 做 CAS 推进游标，并写入回执。任何一步抛错都回滚记录、变更、冲突、回执和游标。
6. `from == through` 且无变更的已认证批次是幂等空操作；`from < through` 且无变更的批次仍提交空范围并推进游标。订阅代次重置后，旧代次的证明因版本不匹配而失败；新代次在重新完成快照前 `established = 0`，增量入口继续拒绝。

### 接入步骤

1. 配对层建立 peer 身份、订阅 scope、订阅代次和双方 HMAC 密钥/`keyID`，把密钥放入平台凭据存储。
2. 接收端用户在本地对 `(peer, scope)` 调用 `grantScopeAccess`，再执行已认证的完整快照建立订阅游标。
3. 发送端按认证握手给出的接收设备和 `after` 调 `nextIncrementalBatch`，用凭据存储中的密钥 `signed(keyID:key:)`，经认证传输发送规范 wire 帧。
4. 接收端解析 `IncrementalBatch(wireJSON:)`，安装的认证器完成验证后调用 `applyAuthenticatedIncrementalBatch`；成功回执才能让发送端释放该批次。
5. 重连时发送端重发同一个已签名批次；接收端返回 `isDuplicate` 或明确缺口，发送端据此回退到完整快照流程。游标过期、代次变化和无法证明的缺口都应重建快照，而不是猜测。

## 公共接口

```swift
let store = try SyncStore(path: databasePath, deviceID: deviceID)

// 接收端：先持久接受，再执行。
let command = try SyncCommand(/* ... */)
let acceptance = try await store.accept(command)
if acceptance.isDuplicate { /* 使用 acceptance.receipt，不重新执行 */ }
try await store.markStarted(
    command.commandID,
    authenticatedDeviceID: deviceID
)
try await store.complete(command.commandID, result: .object([...]))

// 执行代次与重启恢复。
try await store.establishExecutionHead(
    runID: runID, taskID: taskID, epoch: epoch, ownerDeviceID: ownerDeviceID
)
let interrupted = try await store.recoverInterruptedCommands()

// 本地记录/变更（更高的本地 revision 会记录当前行作为共同基线）。
try await store.commitLocalRecord(record)
// 同一个本地事件更新多个对象时，整批提交，避免半个任务状态可见。
try await store.commitLocalRecords([taskRecord, runRecord, messageRecord])
let page = try await store.changes(after: cursor, limit: 100)

// 自研核心：先经现有 RunStore 读已提交事件并白名单归一化，
// 安装受信执行头后，将来源范围和记录一起提交。不是远端 wire 入口。
let projection = LocalRunProjectionBatch(
    taskID: taskID, runID: runID, executionEpoch: epoch,
    afterSequence: lastSourceSequence, throughSequence: lastReadSourceSequence,
    records: normalizedRecords
)
let projected = try await store.applyLocalRunProjection(projection)
let sourceCheckpoint = try await store.runProjectionCheckpoint(for: runID)

// 发送端：一致快照、完整清单和逐页信封。
let snapshot = try await store.openSnapshot(scope: .task(taskID))
let manifest = try await store.snapshotManifest(
    snapshot.snapshotID,
    pageSize: 100
)
let envelope = try await store.snapshotPageEnvelope(
    snapshot.snapshotID,
    manifest: manifest,
    pageIndex: 0
)

// 接收端：配对凭据由可信宿主提供，并仅本地授予该 peer/scope。
let auth = try HMACSnapshotAuthenticator(peerKeys: [
    .init(peerDeviceID: peer, keyID: "pairing-key-1", key: pairingKey)
])
await store.installSnapshotAuthenticator(auth)
_ = try await store.grantScopeAccess(peerDeviceID: peer, scope: .task(taskID))
// 发送端签名；接入层必须安全传递完整 proof 与清单。
let signedManifest = try manifest.signedForSnapshot(
    receiverDeviceID: deviceID, keyID: "pairing-key-1", key: pairingKey
)
let progress = try await store.beginAuthenticatedSnapshotImport(signedManifest)
_ = try await store.receiveAuthenticatedSnapshotPage(signedManifest, envelope: envelope)
let status = try await store.snapshotImportStatus(peerDeviceID: peer, snapshotID: snapshot.snapshotID)
let result = try await store.commitAuthenticatedSnapshotImport(signedManifest)
// result.applied / unchanged / conflicts / unreconciledLocalKeys / baseCursor

// 增量：本地授权 -> 发送端扫描/签名 -> 接收端认证并原子应用。
let grant = try await store.grantScopeAccess(
    peerDeviceID: peer,
    scope: .task(taskID)
)
let unsigned = try await sourceStore.nextIncrementalBatch(
    receiverDeviceID: peer, // 实际目标，取自可信配对/会话
    scope: .task(taskID),
    subscriptionVersion: 1,
    after: baseCursor
)
let signed = try unsigned.signed(keyID: "pairing-key-1", key: pairingKey)
let incremental = try await store.applyAuthenticatedIncrementalBatch(signed)
// incremental.applied / unchanged / conflicts / fromCursor / throughCursor / isDuplicate

// 范围订阅可查询；两个旧增量入口仍明确拒绝。
let subscription = try await store.subscription(
    peerDeviceID: peer,
    scope: .task(taskID)
)
// 持久冲突：崩溃重启后仍可直接读取；解决时再次核对本地行。
let conflicts = try await store.conflicts()
if let conflict = conflicts.first {
    try await store.resolveConflict(conflict.conflictID, resolution: .acceptRemote)
}

// 仅本机。
try await store.setLocalWorkspaceBinding(
    workspaceID: workspaceID, rootPath: localRoot, bookmark: bookmark
)
try await store.registerLegacyBridgeIdentifier(
    legacyID, kind: .workspaceFile, stableID: stableID
)
```

`SyncCommand(wireJSON:)` 按草案读取 `protocolMajor`、`protocolMinor`、`commandID`、`kind`、`taskID`、`workspaceID`、`runID`、`expectedRevision`、`targetEntityKind`、`targetEntityID`、`executionEpoch` 和 `payload`。`expectedRevision` 与 `targetEntityKind`/`targetEntityID` 必须成对出现。未知可选字段忽略，主版本不是 1 时拒绝。载荷数字只允许 64 位整数，所有大计数按草案使用十进制字符串。

`SnapshotManifest(wireJSON:)` / `wireJSON()` 提供清单的规范 JSON 往返，接收端持久化时使用同一形式。`SnapshotPageEnvelope` 当前是 Swift 值；接入层负责把其中记录编码为自己的传输帧，并在收到后重建成 `SyncRecord`。`AuthenticatedSnapshotManifest` 当前为 Swift 值，接入层须安全传递清单、接收设备、key ID 和 HMAC 标签并重建该值；页摘要与已认证清单绑定内容。

`IncrementalBatch(wireJSON:)` / `wireJSON()` 提供增量批次的规范 JSON 往返：协议版本、来源设备、接收设备、scope、订阅代次、起止 cursor、每条变更的 source cursor 和完整记录（含墓碑），以及可选的 `proof { keyID, tag }`。证明计算 canonical descriptor，不依赖传输封装的字节布局；解析忽略未知可选字段，但证明仍绑定解析后的精确值。

`beginSnapshotImport`、`receiveSnapshotPage`、`commitSnapshotImport`、`applySnapshotPage` 与 `commitAppliedCursor` 仍明确抛 `snapshotImportUnverified`。它们是旧版无身份/无完整页证明的入口，不能被用来绕过上面的清单、暂存和 scope 游标流程。

## 数据库

单个 SQLite 文件，`journal_mode=WAL`、`synchronous=FULL`、`foreign_keys=ON`、`user_version=5`。`metadata()` 返回实际 `journalMode`、`foreignKeysEnabled`、开放冲突数、staging 快照数、已建立订阅数和 schema 版本供接入层诊断。主要表：

| 表 | 用途 |
| --- | --- |
| `records` | 当前可移植记录投影；`local_dirty` 标记尚未确认的本地修改；`base_revision`/`base_digest` 记录写入时的共同基线。 |
| `changes` | append-only 变更日志，`AUTOINCREMENT` 序号即本地游标；变更行携带共同基线。 |
| `commands` | 命令身份、载荷摘要/意图摘要、状态、目标记录、预期修订、结果和时间。 |
| `execution_heads` | 每个 run 的当前 epoch 与 owner。 |
| `conflicts` | 被拒绝的远端版本与当时本地版本的完整快照，含双方 payload、摘要、修订、来源、原因、观察游标和解决状态。 |
| `snapshots` / `snapshot_entries` | 发送端明确范围的冻结快照与分页行（含墓碑）；`ON DELETE CASCADE`。 |
| `sync_subscriptions` | `(peer, scope)` 专属订阅版本、已应用游标、是否已由完整快照建立、最后快照 ID。 |
| `snapshot_imports` | 入站清单、scope、订阅版本、baseCursor、逐页/条目计数、暂存字节、状态、过期时间和提交回执。 |
| `snapshot_import_pages` | 已接收页的页号、position 范围、条数、字节、摘要；每个 staging 会话严格按页持久。 |
| `snapshot_import_records` | 已接收的有序记录和墓碑，不进入可见 `records`，直到完整提交。 |
| `sync_scope_authorizations` | 本机显式授予某 peer 的某 scope；快照与增量入口的授权来源。 |
| `incremental_receipts` | 已提交增量区间的有界重放回执：内容摘要、起止 cursor、小结果；按订阅保留最近 N 条。 |
| `applied_cursors` | 旧 peer 级全局游标，仅为兼容保留；不建立 scope 订阅。 |
| `local_workspace_bindings` | 本机根路径与书签，从不进入同步查询。 |
| `legacy_bridge_mappings` | 旧 Bridge 路径派生 ID 到稳定 ID 的设备本地映射。 |
| `meta` | 设备身份、创建时间、已修剪游标。 |

## 迁移与兼容边界

- schema v1 → v2 为增量迁移：`records`、`changes`、`commands`、`snapshots`、`snapshot_entries` 增加可空列或有默认值的列，并新建 `conflicts`。旧行、旧游标和旧命令保持可读。
- schema v2 → v3 只新增 `sync_subscriptions`、`snapshot_imports`、`snapshot_import_pages`、`snapshot_import_records` 及其索引。已有记录、命令、冲突、发送快照、冲突解决状态和 `applied_cursors` 原样保留；v3 不把任何旧全局游标回填为订阅。
- schema v3 → v4 为旧发送快照增加完整性来源标记，保留历史行但拒绝把不能证明墓碑覆盖的旧快照导出为完整清单；重新打开快照后可生成版本绑定的清单。未绑定版本的旧 staging 保留但不能继续提交，允许按原身份显式中止。
- schema v4 → v5 只新增 `sync_scope_authorizations` 与 `incremental_receipts` 及其索引。已有记录、命令、冲突、快照、订阅和游标原样保留；升级后的 store 初始没有任何 scope 授权和增量回执，增量入口继续失败关闭，直到集成层显式授权并完成快照。
- v1 行没有共同基线（两列为 NULL）。新接收端更新这些行时要求对端提供 `baseRevision` 和 `baseDigest`；缺少任一项会持久化为 `missingBaseRevision` 冲突并保留当前行，不会仅凭更大的 revision 覆盖。
- v1 快照不包含墓碑（旧实现只物化 `deleted = 0`）。迁移后的旧快照不能当作完整集合对账依据；需要墓碑语义时必须重新打开快照。
- 旧客户端若发送 `expectedRevision` 但没有目标记录，新命令会被拒绝；但已持久化的旧命令仍可按原 `commandID` 和原意图摘要返回历史回执（测试覆盖）。旧的一参数 `markStarted(commandID)` API 已改为必须显式绑定认证设备。
- v1 的旧 `changes` 行同样没有共同基线；把旧变更重放到已有记录上会得到 `missingBaseRevision` 持久冲突，而不是靠更大 revision 覆盖。需要继续同步时应从带基线的本地/新快照重建，或由上层补齐基线后再发送。
- 本地更新如果带 `baseRevision`/`baseDigest`，会在同一写事务内与当前行比较；不一致时拒绝。省略基线时，本地写入会记录实际当前行作为基线，这是串行本地写方的便利，不替代对端因果证明。
- 冲突解决是显式操作：`keepLocal` 保留本地脏数据，`acceptRemote` 只在本地完整记录仍与冲突记录一致时替换；接受同修订或更旧的远端记录会生成一个以本地当前行为基线的较新本地修订，避免复用旧 CAS 版本。不会自动合并内容。
- 已提交的入站快照回执每个 scope 只保留最近一条；staging 会话与页/记录行由过期清理删除。旧版本创建的数据库打开时自动升级到 v5，不删除历史行。

## 已提交任务接入层（2026-11-19）

`CommittedTaskProjection.swift` 在既有 CanonicalMessageFeed / RunProjectionProducer / SyncStore 之上提供受限的已提交任务接入层：`bootstrapSnapshot` 以有界 keyset 扫描读取已提交会话的规范消息并返回精确重放水印；`importSnapshot` 把任务头与 user/assistant 消息子集以与运行投影生产者完全一致的记录形状写入本机 store（修订按实体合并，重复导入为无操作）；`projectNextPage` 从宿主分类的已提交运行事件推进运行级投影，崩溃/重启后从持久检查点续传；`changes`/`applyFeedTombstone` 暴露会话级变更流并对墓碑幂等；`readBack` 在重新核验执行头（任务绑定、属主、拒绝过期 epoch）之后回读持久投影。消息一律归一化为 `{runID, role, text}`，不导出原始事件、载荷或凭证，不打开任何监听；跨设备传输仍是独立课题。

接线缝：`FloeMacSelfCore` 的 `FloeMacCanonicalFeedStorage` 提供 `beginBootstrap/bootstrapPage/changes/rotateHistory(in:)` GRDB 事务包装；`FloeMacHost` 的 `HostAgentDatabase.committedSyncStoreURL` 给出与宿主库同目录的 SyncStore 位置。宿主运行时需提供：`CommittedCanonicalFeedSource` 实现（用上述包装在 `DatabaseManager` 读事务内执行）、按 RunStore 事件分类的 `RunProjectionSource` 适配（reasoning→`.excludedReasoning`，assistantText→经持久映射的 `.canonicalMessage`，未知→`.unsupported`）、在受理时 `establishExecutionHead` 的当前 epoch，以及用于导入任务头的会话标题摘要。

验证（Xcode 27.2 / Apple Swift 6.4，`xcrun swift test --package-path FloeDesktopSync`，独立 scratch）：150 项 XCTest 全部通过，其中新增 `CommittedTaskProjectionTests` 3 项，使用种子化临时源库（conversations/messages/message_parts + 规范 feed）与临时 SyncStore 覆盖快照导入、增量投影、过期 epoch/重绑定/异主拒绝、墓碑幂等与 feed 轮换后 `wrongGeneration`。`FloeMacSelfCore` 包构建通过且既有 CanonicalFeedStorageTests 2 项通过。未做整包 App 构建（归主任务），未接真实网络或跨设备传输。

## 本轮验证

测试使用独立 SwiftPM scratch 目录，不接触 iOS 工程或其他任务的构建缓存。命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test \
  --package-path FloeDesktopSync \
  --scratch-path ~/Library/Caches/CodexBuild/FloeDesktopSync/<checkout-id>/xcode-27.2
```

增量协议的历史结果（2026-11-16，Xcode 27.2，arm64 macOS；共享原生构建窗口）：

- 当时 `swift test --jobs 2`：95 个 XCTest，0 失败（73 个既有 + 22 个新增），最终日志 `Evidence/incremental-auth-final-20261116.log`；完整命令、源码内容摘要和失败记录见 `Evidence/incremental-auth-20261116.md`。
- 当时 `swift build -c release --jobs 2`：成功，日志 `Evidence/incremental-auth-release-20261116.log`。
- 测试二进制链接 `/usr/lib/libsqlite3.dylib`，未链接 Homebrew SQLite。
- **认证是测试夹具，不是真实网络接入**：端到端测试使用两个独立 SQLite store、固定 HMAC 密钥和同进程调用；真实配对、密钥存储、TLS/QUIC、iPad/Mac 双端没有在本轮运行。

接收端绑定修复后，以共享原生构建窗口及预热 scratch 运行 `swift test -j 2`，真实 Swift 6.4.2 对象编译通过，104 项 XCTest 全部通过，见 `Evidence/incremental-receiver-binding-20261116.log`。新增用例覆盖密钥意外相同、授权与游标相同时跨接收者回放、目标篡改、合法接收与重启后幂等重放、缺字段与旧 1.0 拒绝。该结果不证明真实网络、配对或其他平台接入。

2026-11-17 本地任务批次补充：`commitLocalRecords` 的实际对象编译与 7 项新增测试通过；随后复用该二进制运行同步包，111 项 XCTest 全部通过。覆盖整批回滚、并发共同基线竞争，以及任务/执行/消息的已认证快照、增量与接收端重启后幂等重放，见[验证记录](Evidence/local-task-batch-20261117.md)。这是核心无关的本地投影提交基础，尚未把 OpenCode/Floe 自研运行时的来源游标和记录一起落盘，也未接入真实网络或 App。

随后完成来源投影事务：新增 9 项测试及实际对象编译通过，同步包共 120 项 XCTest 全部通过，见[来源投影验证](Evidence/run-projection-20261117.md)。本机来源游标与规范记录现已可同事务保存；来源事件读取、白名单归一化生产者、完整自研核心、Linux 与真实网络/App 接入仍未验收。前段 111 项记录保留为这一改动之前的历史结果。

快照认证修复后，使用同一预热 scratch、Xcode 27.2 / Apple Swift 6.4，经共享原生构建窗口运行真实对象编译和 `swift test -j 2`：100 项通过（`Evidence/snapshot-auth-final-20261116.log`）。随后新增两条回归，定点 `SnapshotAuthenticationTests` 6 项通过（`Evidence/snapshot-auth-regrant-20261116.log`）；后两条未计入上述全量数。首次先写测试因认证接口尚未实现而编译失败，保留于 `Evidence/snapshot-auth-first-failure-20261116.log`。修复后的 release 配置未单独重新编译。

增量协议的新增覆盖包括：

- 认证原语：HMAC-SHA-256 的 RFC 4231 向量、常量时间校验、短密钥/非法标签/非法 keyID/过长 evidence 拒绝、密钥描述脱敏。
- 发送扫描：按本机变更序号连续扫描、scope 过滤空洞、墓碑、分页预算、`maxIncrementalScanRows` 边界、游标越界/过期、`throughCursor` 不取最大匹配事件。
- 接收认证：无认证器、无证明、未知 key、错 key、peer 重标注、self origin、篡改 payload、截断变更列表、仅用内容摘要伪造标签，全部在写入前拒绝且游标/记录不变。
- 授权与代次：peer 专属且幂等的 scope grant、撤销、跨 peer/跨 scope 拒绝、快照前拒绝、重置到新版本后旧证明失败、重置清理旧代次回执。
- 区间语义：精确起点 CAS、缺口、重叠/陈旧回放、回退、越界/乱序/重复 cursor、过滤后空区间推进、`from == through` 空操作。
- 冲突与墓碑：本地 dirty 与远端更新/墓碑的持久冲突及本地保留、干净墓碑应用、回执与游标同步推进。
- 事务与并发：注入“变更已应用后”异常回滚、批次中途失败回滚、真实双 SQLite 连接并发重放只应用一次、重启后回执/游标/授权恢复。
- 资源与迁移：批次条数/字节上限、回执窗口裁剪后旧重放报缺口、v4→v5 只新增表且保留既有记录、wire JSON 往返与未知可选字段兼容。

历史失败均保留在 `Evidence/incremental-auth-failures-1-20261116.log` 和 `Evidence/incremental-auth-failures-2-20261116.log`：首次全量 94 个测试中 16 个失败（3 个因快照辅助函数未实际发送页；13 个因批次 `peerDeviceID` 初版误建模为接收方，修正为“批次声明来源设备、接收端用认证 peer 对照”后修复）；第二次仍有 2 个断言失败（接收端变更日志包含快照导入产生的行；过滤空区间测试的前置快照已含一条记录），修正预期后通过。没有跳过、删除或放宽任何既有断言，也没有把未观察到的网络/设备行为写成通过。

更早的 24/28/73 测试历史、v3 schema 断言和空快照清单失败见本轮之前的证据日志与说明；本次未重跑无关测试矩阵。只证明 macOS 本地模型与 SQLite 事务，不等于 Linux 构建或两端运行验收。

## 交付与发布归属

本包仍是未接入 App 的独立 SwiftPM 基础实现。本轮交付只包含 `FloeDesktopSync/` 内的源码、测试和证据；没有版本号、tag、IPA、TestFlight/App Store 变更，没有 GitHub/Feather 发布，没有部署或生产服务写入，也没有改动用户当前 Bridge。集成、版本选择、正式构建与分发由 Root/发布 owner 在真实传输与双端接入完成后负责；任何“真实跨设备同步已验收”的声明都必须另有真实配对、密钥、网络和设备证据。

## 未实现与对接需求

1. **传输与配对**：无 TLS/QUIC/WebRTC、二维码、密钥交换、重连与能力协商。增量认证使用的 HMAC 密钥必须由真实配对/传输层建立并保存在凭据存储中；本包只提供验证器和失败关闭的挂接点，不证明网络来源、密钥真实性或密钥未被泄露。快照 HMAC 认证清单并通过摘要绑定页；接入层仍须提供可信密钥和认证会话。`markStarted` 只绑定本地执行入口的认证设备，不等于已验证远端命令发送者。
2. **发送端待发队列**：命令接收端持久幂等接受与执行前置条件已实现；发送端仍需在发送前保存 `commandID`、摘要与作用域，并在重连后查询原回执。`nextIncrementalBatch` 只按调用方给的 `after` 扫描，不持久化“已发送未确认”的发送队列；集成层必须保存已签名批次直到收到 `isDuplicate`/成功回执。`expectedRevision` 在开始时核对目标 revision，但外部副作用发生后的最终写入仍须由调用方保持幂等或再次核对，不能把该前置条件宣传为端到端 CAS。
3. **文件内容**：没有分块、续传、临时写入/校验/原子提交、冲突副本。工作区记录只保存逻辑路径和清单引用。
4. **快照 wire 与路由**：清单与增量批次已有规范 JSON；`AuthenticatedSnapshotManifest` 和 `SnapshotPageEnvelope` 仍是 Swift 值，接入层需固定记录/页的传输编码、HTTP/QUIC 路由、分页请求参数和错误映射。旧 `applySnapshotPage` / `commitAppliedCursor` 继续 fail closed，不能被新接入绕过。
5. **记录来源认证与时间**：批次与快照中的 `originDeviceID` 只做身份/归属记录，不单独决定授权；授权来自已认证 peer 与本地 scope grant。接入层仍须把认证会话与 peer 绑定。`recordedAt` 使用本地接收时间，不代表源端执行顺序；增量批次的 `throughCursor` 是已认证发送端对其自身变更日志的完整性声明，接收端能验证区间连续和条目归属，但无法独立证明发送端没有隐藏其日志中的某条应有变更——这属于发送端信任边界，不是可由摘要补足的性质。
6. **范围集合删除策略**：本包只应用显式墓碑，不把“快照未包含”或“增量区间未包含”自动转成删除。上层若需要在完整集合上删除本地孤儿，必须先持久核对 `unreconciledLocalKeys`、确认来源确实见过该记录并获得明确用户策略；当前没有任何自动删除路径。增量批次的空洞只说明该范围没有目标 scope 记录，不能推断删除。
7. **冲突合并与 UI**：冲突已持久化，`keepLocal`/`acceptRemote` 可恢复，但没有自动文本合并、重基、字段级合并或冲突列表 UI。合并策略需要在上层按 `kind` 定义。
8. **快照规模与保留**：发送快照在 SQL 事务内整体物化（进程内存不随快照总大小增长，但仍占用数据库空间），分页有字节预算；入站 staging 有并发、条目、页和字节上限。本地对账键数现在受 `maxSnapshotEntries` 限制；超限事务回滚并保留 staging。提交回执仍受 16 MiB 读取上限约束；大工作区需实现分页对账和分页回执；`pruneChanges`/`pruneExpiredSnapshots`/`pruneExpiredSnapshotImports` 仍由调用方调度。
9. **iOS/Mac/Linux/Windows 集成**：尚未接入 `FloeAgent`、`FloeMacCore`、Bridge 或 Linux/Windows 应用；没有 UI、App 组网、系统授权或 Keychain 处理。`establishExecutionHead` 只持久 epoch/owner；`handoff.prepare`/`handoff.commit` 的同一交接身份、交出记录验证和原子推进尚未实现，接入层必须先验证交接再安装代次。
10. **Linux 编译**：通过 `CSQLite` 系统库模块支持 Linux 头文件；本轮只在 macOS 实编译和测试，Linux 构建尚未验证。POSIX 权限检查在 Linux 上预期可用，但未实测。
11. **记录载荷 schema**：敏感键/工作区相对路径是结构校验，不是内容分类器；接入层仍须按 `kind` 只写入已定义的允许字段，不能借自由文本字段携带本机路径、凭据或权限。
12. **加密**：SQLite 文件本身未加密；凭据不进入本库。若需要静态加密，应复用平台已有的数据库保护方案，而不是在载荷层自造。
13. **真实服务与 iPad**：OpenCode/DeepSeek 实际服务、网络/TLS、真实 iPad 与 Mac 双端接入不在本包验证范围；本轮没有启动这些服务，也没有执行真实设备传输。

**真实双端逐步同步的边界**：本包只在同进程内用两个独立 SQLite 库和测试夹具验证发送扫描、签名、接收认证与原子应用；没有真实网络、真实密钥、真实配对或 iPad/Mac 双端运行证据。HMAC 是对称证明，持有同一密钥的另一端也能生成同样标签；它证明“持有配对密钥”，不等于不可否认签名或公钥所有权。生产接入必须使用真实配对密钥并保护密钥存储。
