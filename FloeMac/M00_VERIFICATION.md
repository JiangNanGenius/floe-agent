# Floe Mac M00 — 实际验证记录（交接）

> **当前状态更新（2026-11-16，追加 fixture 隔离恢复）：** 生产共享存储入口仍失败关闭：旧独立 Bridge 不参与新锁，不能声称共享数据持续排他。helper CLI fixture 已在“任务自有 mkdtemp 0700 根 + helper 自应用内核 Seatbelt + root-fd no-follow”边界内恢复，并由 `verify_m00_isolated.sh` 实测 34/34。旧的 `verify_m00.sh` 仍含真实 Keychain/生产探针，不能用于隔离验收。打包 host/UI 的 fixture 接线和实际 GUI 验收尚未完成；组件/CLI 证据不能替代它。本文件上文旧段落中的“fixture 启动不可用”是本次恢复前的历史状态。

日期：2026-11-16。工具链：Xcode 27.2（27B52），`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
源码基线：`main` `17c1e27a4`；`FloeMac/` 仍是未提交的本任务目录。未安装、未公证、未上传、未执行 Git 操作；
未启动或停止用户已有 Bridge 服务。

## 结论摘要

本轮把 M00 从“隔离 synthetic Bridge 探针”推进到“生产就地复用真实身份/数据 + 测试严格隔离”的
同包服务源码，并补齐认证 control IPC、用户配对 consent、实时任务状态、停止/退出/崩溃生命周期、
generation fencing、签名 pin 和失败恢复探针。**本轮源码尚未在资源门槛允许时完成真实对象编译**；
因此不能把下列源码路径当作已编译或已运行证据。旧 M00 的 15/16 失败和根因证据完整保留。

## 旧产物失败（保留，不追溯改写）

旧 M00 包（修复前/部分源码之后）：

- 路径：`~/Library/Caches/CodexBuild/floe-mac-m00/0dd039b5b74b/25400.63.5/package/Floe.app`
- `M00_VERIFICATION` 旧记录：`verify_m00.sh` 15/16；唯一失败是 packaged Bridge-mode smoke：
  `bridgeState=failed`、`bridgePID=0`、`bridgeLogTail=FLOE_BRIDGE_READY pid=46700 port=43871`。
- 旧 summary：`.../evidence-final/results/summary.json`（checks 16, failures 1）。
- 旧 helper 的 ready 文件已写出并被 host 读到，随后 helper 退出 `terminationStatus=5`（SIGTRAP）。

### 实际复现与根因

证据副本：`FloeMac/Evidence/20261116/`（旧 summary/bridge probe/build manifest、SIGTRAP 摘要、
旧 helper 复现记录、typecheck 与 build gate 记录）。完整旧包仍保留在原缓存。

本轮对旧包做了两组只读复现（隔离 home，端口空闲）：

1. 不带 `--parent-pid`：helper 持续监听 6 秒以上，SIGTERM 后正常退出（status 0）。
2. 带 `--parent-pid <python pid>`（父进程保持存活）：helper 约 1.2 秒后以 status `-5` 退出；
   ready 文件已是 `state=ready`，日志仅有 `FLOE_BRIDGE_READY`。

关键证据：

- 旧 helper 二进制实际引用了 `_exit`（`nm` 显示 `external _exit`），说明“把 exit 改成 _exit”的
  修复已经在旧产物里，但 SIGTRAP 仍然发生；因此 `_exit` 不是根因修复。
- 崩溃报告：`~/Library/Logs/DiagnosticReports/FloeMacBridgeService-2026-11-16-200100.ips`
  - `exception type=EXC_BREAKPOINT, signal=SIGTRAP`
  - faulting thread queue `com.apple.root.utility-qos`
  - frames：`_dispatch_assert_queue_fail` → `dispatch_assert_queue` →
    `_swift_task_checkIsolatedSwift` → `swift_task_isCurrentExecutorWithFlagsImpl` →
    `closure #7 in main.swift` → `_dispatch_source_latch_and_call`
- 旧 `main.swift` 是顶层代码。Swift 6 顶层代码受 MainActor 隔离；parent watchdog 的
  `DispatchSourceTimer` handler 在全局队列执行并访问顶层隔离状态，首先触发 actor 隔离断言，
  根本没走到 `_exit`。这与“父 PID 正确时仍在 watchdog 首次触发附近退出”完全吻合。

本轮修复思路不是再次替换退出函数，而是：

- `@main struct` 入口，不使用顶层可变状态；
- watchdog、signal、control connection 的 handler 只捕获 Sendable 局部变量；
- 运行时状态由 `BridgeServiceRuntime` 内部锁保护；
- 在 listener/control channel 关闭并写出最终状态后才 `_exit`，并记录这是受控退出，不再把它
  冒充为根因修复。

## 本轮源码实现

| 区域 | 实际源码 |
| --- | --- |
| helper 入口 | `FloeMac/Sources/FloeMacBridgeService/BridgeServiceMain.swift`：production/test 模式、身份解析、fixture 预置、preflight、失败 ready |
| 身份 | `BridgeIdentity.swift`：Keychain `org.floeagent.bridge.server` 只读解析、`kSecUseAuthenticationUIFail`、无配对时才允许正式签名创建、fixture 持久身份 |
| control IPC | `BridgeControlProtocol.swift`、`BridgeControlServer.swift`、`BridgeControlClient.swift`：0600 Unix socket、同 UID + token、status/consent/revoke/stop/challenge |
| 运行时 | `BridgeServiceRuntime.swift`：真实 `BridgeService`/`BridgeJobs`、实时 active/unknown tasks、consent、orphan、generation、SIGTERM 活动任务保护 |
| host 控制器 | `BridgeComponentController.swift`：production/fixture、attach、pin、live stop、generation fencing、窗口/退出分离 |
| 外部 Bridge | `BridgeEndpointInspector.swift`：lsof/ps/Bundle/真实数据只读盘点、未配对签名 ping 的 self-signed 密钥指纹 |
| 生命周期 | `HostAppDelegate.swift`、`HostModel.swift`：窗口关闭不终止、活动工作时拒绝 Quit、空闲才停止 |
| UI | `HostRootView.swift`：身份/存储/任务/配对/consent/冲突/权限/孤立状态；诚实说明不声称目标完成 |
| 自动审批 | `AutoApprovalIntegration.swift` 保留 Floe-owned seam，M00 仍为 reserved |

### 生产与测试边界

- 生产：`--mode production`，真实 user home、真实 Keychain、真实 `Application Support/Floe Bridge`；
  不传 `--probe-client-key`，不写 synthetic pair，不在身份缺失/不可读时生成替代身份。
- 测试：`--mode test --test-fixture <path>`，`service-home` 与 `worker-home` 分开；fixture 身份持久化；
  只有测试模式接受预置 probe client。控制/ready/discovery 文件在显式路径；fixture 校验拒绝真实
  Bridge 目录。
- 外部 43871 在线：只读识别 PID、bundle、版本、真实配对/任务数量；发送**未配对**签名 `ping`
  观察服务端密钥，并用现有 paired-clients 的 verification 字符串核对是否为已配对客户端批准过的
  身份；不匹配时明确标注 self-signed/not anchored。不创建 pending pairing，不读取客户端私钥，
  不启动/停止/终止外部进程。

## 已执行的检查（本轮）

| 检查 | 实际结果 |
| --- | --- |
| `xcodegen generate --spec FloeMac/project.yml` | 成功；共享 control 源分别进入 host/helper target |
| Host Swift 前端 `-typecheck` | **通过**（0 error）；见下方命令 |
| Helper Swift 前端 `-typecheck` | **通过**（0 error）；见下方命令 |
| `swift-format lint`（本轮新增/修改 Swift 文件） | 无语法 error；仅格式/长度 warning |
| `bash -n FloeMac/scripts/build_m00.sh` / `verify_m00.sh` | 通过 |
| `python3 -m py_compile FloeMac/scripts/probe_m00_lifecycle.py` | 通过 |
| 旧 helper 父进程/无父进程复现 | 上述 status 0 vs -5；崩溃报告定位到 Swift 6 actor 隔离断言 |
| 旧 M00 summary | 保留 15/16，失败原因未被掩盖 |

### 前端 typecheck（不是对象构建/链接）

本轮在无目标对象输出的条件下运行了 Swift 6 前端 typecheck，使用缓存中的
`FloeMacBridgeProtocol.swiftmodule`（另一 lane 的构建产物，路径
`~/Library/Caches/CodexBuild/FloeMacBridge/ios-internal-354/.../Products/Release`）。该模块与
`main` 源码 API 的最终一致性仍由完整对象构建/链接验证：

- Host：`swiftc -typecheck -swift-version 6 -target arm64-apple-macos15.0 -sdk <SDK> -I <protocol-module>`
  + `BridgeControlProtocol.swift` + `FloeMacHost/*.swift` → 0 error。
- Helper：同上 + `FloeMacBridgeProtocol` 模块、`CBridgePTY` module map，并只读编译
  `FloeMacBridgeApp` 的 `BridgeService/BridgeJobs/BridgeHTTPServer/BridgePaths/BridgeCapabilities/
  BridgeUpdateActivity/BridgeAbsoluteFileRead` 源文件 → 0 error。
- 警告：`kSecUseAuthenticationUIFail` 在 macOS 11+ 标记 deprecated；当前仍按无交互读取使用，
  不会静默创建/重置身份。
- typecheck 发现并修复了真实问题：helper 入口原为 `main.swift` 且使用 `@main`，Swift 会把
  `main.swift` 当顶层代码并拒绝 `@main`；已改名为 `BridgeServiceMain.swift`，重新生成 Xcode 工程。
- typecheck 还发现并修复了 `BridgeControlClient.close(Int32)` 与实例 `close()` 的名字冲突、
  `BridgeEndpointInspector` 跨 MainActor 访问 `fixedPort`、HostProbes 辅助函数缺少
  `@MainActor` 等问题。

这仍**不是**完整对象编译、链接、签名或打包；随后实际运行的 `build_m00.sh` 资源门禁按预期
拒绝了完整构建（见下文）。

## 本轮未完成的真实编译与验证

**没有启动完整对象构建。** 交接时内部 SSD 可用空间低于 30 GiB 硬门槛，且有其他
FloeAgent/Android 编译在运行；`build_m00.sh` 保持硬门禁，没有使用任何绕过环境变量。已完成的
Swift 前端 typecheck 不生成目标对象、不链接、不签名；旧包不能代表本轮源码。

因此以下均未执行、不能声称通过：

- `FloeMac/scripts/build_m00.sh` 的 host/helper/Catalyst 真实编译与 ad-hoc codesign verify；
- 新 helper 的 `--identity-and-permissions-check`（真实 Keychain 可读性、签名身份、屏幕录制/
  辅助功能当前状态）；
- `verify_m00.sh` 的 fixture 共享 Bridge、真实 PTY 任务与文件读回、活动停止拒绝、配对批准/
  拒绝/撤销、pin、父进程 PID、快速重启、崩溃恢复、父进程退出、外部 listener 冲突和
  packaged GUI smoke；
- 生产 helper 对本机现有 Keychain 身份/真实数据的实际访问；
- 物理 GUI 点击/视觉验收。

### 资源状态（交接时）

- 最终复测 `df -Pk "$HOME"`：`399,879,744 KiB` 可用（约 27.0 GiB），仍低于
  `30 * 1024^3` 字节门槛。
- 实际执行 `FloeMac/scripts/build_m00.sh`：脚本在构建前拒绝并输出
  `Internal SSD has 26.98 GiB (28974489600 bytes) free; M00 requires at least 30 GiB (32212254720 bytes). No build was started.`，
  退出码 2。该次没有启动 `xcodebuild`、编译或签名。
- 本轮期间多次观察到其他 `xcodebuild`/`swift-frontend`/`swift-build` 进程；最终检查时暂时空闲，
  但磁盘门槛仍不满足，因此按项目约束未启动完整 M00 构建。
- 旧 M00 缓存约 5 MB；未批量删除其他任务 DerivedData、Simulator 或共享缓存。

## 重编前条件与下一条命令

1. 复测内部 SSD 可用空间 ≥30 GiB。
2. 确认没有其他 `xcodebuild` / `swift-build` / `swift-frontend`。
3. 运行（不要带任何绕过参数）：
   `FloeMac/scripts/build_m00.sh`
4. 运行：
   `FloeMac/scripts/verify_m00.sh`
5. 由主负责人做 GUI 点击/视觉验收。

## 未完成与限制（必须诚实保留）

- 完整 iPad shell、OpenCode 适配器、模型/聊天/任务/设置、Office/格式预览、Mac 工具箱均未接入。
- 正式 Developer ID 签名后旧 Keychain ACL 是否允许同包 helper 读取、是否需要用户迁移授权，
  尚未实测；M00 的 ad-hoc helper 只实现了失败关闭和证据，不承诺自动继承。
- 屏幕录制/辅助功能是独立 TCC 授权，不能因同包或同图标假定继承；helper 只报告当前状态。
- 物理 GUI、菜单/窗口、鼠标键盘、Dock/角色切换未做正式验收。
- Floe-owned 目标协调器未实现；Bridge status 只报告服务/执行工作，不声称任务或目标完成。
- Floe-owned 自动审批引擎未实现；M00 seam 仍为 reserved，不把 OpenCode 审批当 Floe 审批。
- `codex/bridge-115` worktree 的 1.1.5 (8) 只有 Info.plist 版本变化，没有源码改动；本轮未吸收，
  `FloeMac` 继续编译 `main` 的 1.1.4 源码。
- 旧包 `.../package/Floe.app` 仍是修复前构建，不是最终 M00 artifact；重编会覆盖它。

## 2026-11-16 后续并发配对、停止准入与 host takeover 证据

本节是上文的追加记录，不修改旧失败记录或旧结论。源码仍未提交、未安装、未公证、未上传，未操作
现有 Bridge 进程、真实 Keychain 或真实 `Application Support/Floe Bridge` 数据。

- 新增/修改：`FloeMacBridge/Sources/FloeMacBridgeApp/BridgeService.swift`（有界有序配对快照 +
  逐次 attempt identity + 持久化失败保留请求 + 兼容 standalone 回调）、`BridgeUpdateActivity.swift`
  （关闭 admission 原因与同一原子 reservation）、`BridgeStoreLock.swift`（新文件，flock 单所有者）、
  `FloeMac/Sources/FloeMacBridgeService/BridgeServiceRuntime.swift`（stop/signal/orphan 线性化、
  完整 consent 列表、认证后 claim/断线/交接）、`BridgeControlProtocol.swift` 和
  `BridgeControlServer.swift`（claim、connection identity、增量解码）、host controller/UI/probes。
- 测试命令与结果：
  - `swift test --package-path FloeMacBridge --scratch-path ~/Library/Caches/CodexBuild/FloeMacBridge/job-21e098ad0ed84848/xcode-27.2 -j 2 --disable-sandbox`
    → App 39 tests / 6 suites + Protocol 23 tests / 4 suites 通过；包含新增 pairing snapshot 6 项、
    store lock 5 项（含 Python 子进程持有 flock 的真实跨进程拒绝）和既有
    pairing/update/PTY/transfer 回归。
  - `xcodebuild test -project FloeMac/FloeMac.xcodeproj -scheme FloeMacBridgeServiceTests ...`
    → 13 tests 通过（5 host controller + 8 service lifecycle），覆盖多客户端、取消/重试旧批准、
    写失败保留、stop-vs-request/job/consent、in-flight reply、signal/orphan、A 死亡/B 跨 grace
    接管、B 断线、未 challenge 的 claim 和同连接绑定、shutdown 后拒绝新请求。
  - `xcodebuild build` 的 `FloeMacHost` 与 `FloeMacBridgeService` 两个目标均成功编译 Swift 6
    对象代码；未执行 `build_m00.sh` 完整打包。
- 未完成/限制：运行 `FloeMac/scripts/build_m00.sh` 前内部 SSD 可用空间约 28 GiB，仍低于脚本的
  30 GiB 硬门禁；按资源策略未使用任何绕过参数，因此没有新的完整 `Floe.app` 包、GUI 点击或真实
  Keychain/生产 helper 启动证据。完整 M00 打包、GUI/视觉、正式签名、公证和分发仍由主负责人或
  后续阶段完成。
- 跨进程所有者的旧版限制：新 embedded 与新的 standalone 构建使用 `State/bridge-store.lock`
  的 flock；已发布的 1.1.4/1.1.5 standalone 不取该锁，只由固定 `127.0.0.1:43871` 端口互斥和
  host 只读冲突检查约束。不得据此声称新旧双跑或迁移安全。

## 2026-11-16 fixture 隔离恢复（追加记录）

本节不修改上文的历史失败或旧结论。生产共享存储入口仍失败关闭；本轮只恢复 helper CLI
fixture，并且恢复了比旧 fixture 更强的内核边界。

### 源码范围

- 本轮 source HEAD：`main` `688fe1079` 加未提交的 `FloeMac/` 工作树；`FloeMacBridge/` 中既有的
  未提交修改保持不动。
- 新增 `FloeMac/Sources/FloeMacBridgeControl/FixtureRootLocation.swift`：只接受直接位于
  canonical per-user temp 下的 mkdtemp `floe-mac-m00-fixture.XXXXXX` 0700 根，记录
  device/inode，并用 `openat(O_NOFOLLOW|O_DIRECTORY)` 检查 `Control`、`service-home`、
  `worker-home`、`tmp`。
- 新增 `FloeMac/Sources/FloeMacBridgeService/FixtureSandbox.swift`：在读取身份、配对、
  State/Tasks 之前调用 `sandbox_init`；profile 只允许 fixture 根、系统只读路径、
  `127.0.0.1:0`/control Unix socket 和 PTY 设备，拒绝真实 home、真实 Bridge 根、
  Keychain 目录、`SecurityServer`/`securityd`/`trustd`、外部网络和 43871。PTY 子进程
  继承同一沙箱。profile 与自检结果写入 fixture 根内 `Control/sandbox-profile.sb` 和
  `Control/sandbox-report.json`。
- `BridgeServiceMain.swift`：删除 fixture 入口的提前拒绝；production 仍失败关闭。
  fixture 先校验/固定根，再创建 `BridgePaths`、store lock、身份和配对；HTTP 使用
  `127.0.0.1:0`，ready/status 记录实际端口。
- `BridgeIdentity.swift`：fixture 身份读取改为 `lstat` + `O_NOFOLLOW`，首次创建使用
  `O_EXCL`；不再使用会跟随符号链接的 `URL.resourceValues`/原子重写。
- `BridgeServiceMain.swift` fixture 配对写入改为 `lstat` + `O_NOFOLLOW` 的显式文件写入。
- `FloeMac/scripts/verify_m00_isolated.sh`、`fixture_session_probe.swift`、
  `fixture_sandbox_probe.c`：隔离入口、认证 control/PTY 会话和独立内核探针。

### 实际命令与结果

工具链：Xcode 27.2（27B52），`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
所有原生编译经 `Local/Private/shared-native-window/with_native_window.py` 串行化，`-jobs 4`。

- helper Debug 对象构建：
  `xcodebuild -project FloeMac/FloeMac.xcodeproj -scheme FloeMacBridgeService -configuration Debug -derivedDataPath ~/Library/Caches/CodexBuild/floe-mac-m00/job-a7f2f036/xcode-27.2-helper -jobs 4 build`
  → `BUILD SUCCEEDED`。
- 现有 owner/consent/lifecycle 测试：
  `xcodebuild ... -scheme FloeMacBridgeServiceTests ... test`
  → `Executed 16 tests, with 0 failures`（`BridgeHostControllerTests` 5，`BridgeServiceLifecycleTests` 11）。
- 隔离验收：
  `FloeMac/scripts/verify_m00_isolated.sh --helper-app .../FloeMacBridgeService.app --products-dir ...`
  → `checks=34 failures=0`。
- 私有原始证据：`Local/Private/floe-mac-fixture-isolation-20261116-233858/`（未纳入 Git）。
  其中 `session.json` 的全部 session checks 为 true；`sandbox-report.json` 的 sandbox checks
  全部为 true；`external-sandbox.log` 为所有独立探针 `true` + `SUMMARY|0`。本轮 scratch
  `~/Library/Caches/CodexBuild/floe-mac-m00/job-a7f2f036/` 已在导出构建/测试日志后删除；
  fixture/victim 临时根也已删除。

### 实际观察

- 正常 isolated session：ready `state=ready`、实际 ephemeral 端口 `52941`、
  `identitySource=test-fixture-persistent`、`storeLockExclusive=true`；认证 challenge/claim
  通过；真实 PTY 任务输出包含 `HOME=<fixture>/worker-home`、`HOME_READ_DENIED`、
  `NET_DENIED` 和 `DONE`；活动任务期间 stop 被拒绝；任务完成后 stop 接受，helper 退出 0，
  control socket 与端口关闭。
- 独立 `sandbox-exec` 探针（使用 helper 写出的同一 profile）：
  home/Bridge/Keychain/victim 目录 `lstat/ open errno 1`；fixture 根可写；victim 写拒绝；
  `1.1.1.1:80` 和 `127.0.0.1:43871` errno 1；ephemeral TCP 与 control Unix socket 可绑定；
  Keychain query `OSStatus -50`；fork/exec 子进程继承限制。
- 恶意路径：错误前缀、根符号链接、`service-home`/`Control`/ready/identity 符号链接、
  `service-home/Library` 祖先符号链接均以 status 2 失败关闭，victim 三个 sentinel 哈希不变；
  identity 场景只写 fixture 根内 failed ready。启动后把 `Control` 替换为指向 victim 的符号链接，
  SIGTERM 后 helper 自然退出，victim sentinel 不变且未写 `ready.json`。

### identity 符号链接原始失败与修复（不得视为通过）

第一次 23:28 的隔离运行中，`service-identity.json` 符号链接没有被拒绝：旧
`BridgeIdentity.resolveTestFixture` 的 `URL.resourceValues(isSymbolicLink)` 实际跟随了目标，
helper 启动并监听，脚本又在无期限 `wait`。协调方观察到该测试子进程 PID 75783 超过 7 分钟，
仅对该 fixture PID 发送 SIGTERM 以释放窗口。该次信号终止不是安全拒绝证据，不能算通过。
修复后使用 `lstat`、`O_NOFOLLOW` 和 `O_EXCL`；重新运行 identity 符号链接场景为自然 status 2，
victim identity sentinel 哈希不变。`verify_m00_isolated.sh` 现在对所有预期失败子进程使用
有界等待，超时只停止自己启动的 PID 并记为失败，不再把信号终止当作通过。

### 未完成与边界

- production 共享存储仍失败关闭；未实现旧 standalone 的持续排他或隔离迁移。
- 未运行 `verify_m00.sh`（其真实 Keychain/生产探针不适用于隔离验收）。
- 打包 host/UI 的 fixture 接线尚未更新：`BridgeComponentController` 仍使用调用方提供的
  fixture 路径和固定 43871，本轮的 helper root 工厂/ephemeral 端口只由 CLI helper 与
  isolated probe 验收。因此实际打包 App GUI、菜单/窗口和视觉验收仍未执行。
- 未读取真实 Keychain 内容或真实 Bridge 文件内容；真实 Bridge 树在运行前后快照不变，
  Keychain 目录元数据快照不变。没有 formal migration、签名、安装、公证、上传或 Git 发布操作。
- Windows/Linux 未实现；只保留逻辑契约。
