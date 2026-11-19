# Floe Mac M00 — 单 App、双模式、真实 Bridge 身份与生命周期

> **更新（2026-11-18）：** Agent 页接入 Floe 自研核心，提供模型设置、文本对话、停止和 SQLite 历史。在打包的 Debug App 中，以合成回复验证了发送、持久化和重新打开对话。工具授权和完整工具箱仍待接入及验证。下文有关 OpenCode 的描述属于历史方案。Bridge fixture 的网络与 Keychain 隔离仍待修复和验证，暂停使用该 fixture。

> **同一应用接线（2026-11-18）：** OTA 工程以现有 Bridge App 为入口，在同一进程打开原生 Agent 和工具箱窗口。Bridge 继续使用原配对存储及签名身份。签名 Debug App 以临时旧格式配对和合成模型回复通过了 Bridge 认证请求、对话持久化、活动期间延迟更新和退出验证。实际旧客户端 OTA、生产钥匙串及完整工具箱仍待验收。下文的嵌入式 helper 描述对应开发工程。

> **直接 OTA 方向：** 用户明确现有 Bridge 与未来完整 Mac 版是同一 App，正式版应继承已发布 Bridge 的身份、更新信任与版本序列，直接从现有更新链升级。M00 的 `org.floeagent.mac` 是隔离开发身份，不能用于证明正式升级；真实发行、配对与数据保持以及 OTA 尚未验收。见[升级核查](../docs/FLOE_BRIDGE_OTA_AND_MAC_MIGRATION_20261117.zh-CN.md)。

> **生产与测试边界：** 生产共享存储入口仍失败关闭：已发布的旧版独立 Bridge 不参与新 `flock`，不能声称共享数据持续排他。旧的 `verify_m00.sh` 含真实 Keychain/生产探针，不得用于隔离验收；`verify_m00_isolated.sh` 也因上述隔离缺口暂不可运行。打包 host/UI 的 fixture 接线和实际 GUI 验收仍未完成；组件/CLI 证据不能替代它。

日期：2026-11-16。范围：仅 `FloeMac/` 新增文件。未修改 `FloeMacBridge/`、`FloeAgent/`、iOS 目标或 Git/发布状态。
完整 GUI 点击、审美和正式分发签名仍由主负责人验收。

## 目的

M00 验证后续 Mac 测试版的地基，不声称完整 Agent 或完整 Bridge：

- 一个可安装入口：`Floe.app`。`FloeMacAgentUI.app` 与 `FloeMacBridgeService.app` 位于
  `Floe.app/Contents/Helpers/`，是内部组件，不是第二个产品。
- 首次启动选择 Agent/Bridge 模式，保存到独立的小型 JSON 偏好文件，重开、切换和退出行为一致。
- **Agent 模式直接使用同一个 Bridge**：Agent 页和 Bridge 页观察并控制同一个
  `BridgeComponentController` 实例。Agent 模式可以启动/使用同包 Bridge，不必先切换模式。
- **Bridge 模式独立初始化**：Bridge 页不初始化 Agent 核心、模型、OpenCode 适配器或 Harness；
  Bridge 服务也可由嵌套 helper 单独启动。
- **生产身份与数据就地复用（设计目标；当前生产入口失败关闭）**：生产 helper 设计为读取现有 Floe Bridge 的 Keychain 身份和真实
  `Application Support/Floe Bridge` 下的 State、Tasks、Workspaces、Skills、Environments，
  不生成 synthetic 密钥、不覆盖 `paired-clients.json`、不在每次启动时重置服务器身份。
- **测试与生产严格分开**：测试使用显式 `--mode test --test-fixture`，fixture 内单独保存
  `service-home`、`worker-home`、`Control` 和 fixture 身份；不读真实 Keychain，不写真实数据。
- **单一服务所有者**：host 只停止自己启动或重新连接的同包服务。若 43871 已被占用，先只读识别
  进程、Bundle 版本和真实数据数量，不启动、不抢占、不终止、不覆盖外部服务。
- **真实配对 consent**：host 通过认证的 Unix domain control channel 收到配对请求，显示服务端
  计算的指纹；用户可以批准、拒绝或取消请求，并可撤销已有配对。服务端再次校验 clientID 与指纹，
  不信任模型文本。
- **签名身份与任务状态**：control challenge 用 helper 身份签名；host 以首次信任的 pin 验证，
  后续 key 变化失败而不是静默重 pin。测试 RPC ping 使用同一个 pin，不再 `pinnedKey=nil` 自验。
- **活动任务实时、可恢复**：status 从真实 `BridgeJobs` 和 `Tasks` 目录读取，不再用 ready 快照
  判断停止；有活动任务时拒绝停止和退出。无 `result.json` 的任务标记为未确认并保留，不自动重跑。
- **生命周期分离**：关闭窗口不停止服务；切换模式不重启/迁移任务；退出 App 在活动工作时被拒绝；
  用户显式停止服务时才按现有任务生命周期处理。UI 崩溃时 helper 在活动任务结束前继续运行，
  空闲后按 grace 退出。快速 stop/start 的进程回调与异步状态用 generation fencing。
- **Floe-owned 自动审批 seam**：M00 只保留 Floe 任务范围/风险类别/provider 接口和只读状态，
  不实现审批引擎，不把 OpenCode 自带审批当成 Floe 审批。Bridge 模式不使用该 policy。
- **目标协调器不在本轮**：Floe 自己实现目标模式；OpenCode 只负责实际执行。当前 Bridge 状态只报告
  服务和执行工作，不声称 Floe 任务或目标已完成；Agent 与 Bridge 的执行归属保持独立。

## 目录

```
FloeMac/
  project.yml                     # XcodeGen；host、helper、Catalyst 三个 target
  Sources/FloeMacBridgeControl/   # 认证 control 协议 + fixture 根身份工厂
  Sources/FloeMacHost/            # 原生 macOS 模式宿主、共享 Bridge 控制器、probes
  Sources/FloeMacAgentUI/         # Mac Catalyst UI target
  Sources/FloeMacBridgeService/   # 同包 Bridge helper 入口、control server、身份/生命周期
  Sources/CBridgePTYModule/       # 现有 CBridgePTY 的只读 module map
  Resources/                      # Info.plist、双语字符串
  scripts/build_m00.sh            # 本地构建 + 组装单包（硬资源门禁、签名失败即失败）
  scripts/verify_m00.sh           # 旧的生产/Keychain 完整验证（不得用于隔离验收）
  scripts/verify_m00_isolated.sh  # 隔离 fixture/内核沙箱/PTY/stop 验收
  scripts/fixture_session_probe.swift # 认证 control + PTY 会话探针
  scripts/fixture_sandbox_probe.c    # 独立内核沙箱探针
  scripts/probe_m00_lifecycle.py  # UI 崩溃/父进程退出/活动任务/孤立服务测试
```

## 生产与测试

| 项目 | 生产 | 测试 fixture |
| --- | --- | --- |
| 启动 | `--mode production`（默认，当前失败关闭） | `--mode test --test-fixture <mkdtemp root>` |
| 根目录 | 真实 user home | 直接位于 canonical per-user temp 的 0700 根，名称 `floe-mac-m00-fixture.XXXXXX` |
| 身份 | 现有 Keychain `org.floeagent.bridge.server` | fixture 内持久 synthetic 身份；`lstat`/`O_NOFOLLOW` 读写 |
| 数据 | 真实 `~/Library/Application Support/Floe Bridge` | `<root>/service-home/Library/Application Support/Floe Bridge` |
| 任务 HOME | 用户真实 home | `<root>/worker-home`（`HOME`/`CFFIXED_USER_HOME` 显式设置） |
| 控制/端口 | 固定 `127.0.0.1:43871` | `<root>/Control` Unix socket；HTTP `127.0.0.1:0`，ready/status 记录实际端口 |
| 沙箱 | 无（生产未启用） | helper 启动即 `sandbox_init` Seatbelt；真实 home/Bridge/Keychain/外部网络/43871 拒绝 |
| 配对 | 用户 consent；只通过 `BridgeService.approve` 写入 | fixture 内预置测试 client；不进入生产 |
| 停止 | 实时检查活动任务；活动时拒绝 | 同样检查；测试完成后停止 |

生产 helper 对 Keychain 的读取使用 `kSecUseAuthenticationUIFail`，不弹出交互窗口，也不在失败时
创建替代身份。若 Keychain 中存在身份但当前 ad-hoc 构建无法读取，服务会明确失败；只有正式签名
且无现有配对时才允许创建首次身份。是否存在旧配对、旧 State/Tasks 以及 Keychain 可读性都由
`--identity-and-permissions-check` 在 helper 自己的签名进程中实测并记录。

## Control IPC 与配对

`BridgeControlServer` 在 app-owned `0700` 目录创建 `0600` Unix socket；peer 必须是同 UID，且必须
提交 discovery 文件中随机 token。支持：

- `status`：实时 pid/parent、端口、存储、身份来源与指纹、活动/未确认任务、配对列表、活动请求数、
  consent、orphan 状态、屏幕录制/辅助功能当前权限。
- `pairingDecision`：只批准/拒绝当前已展示且指纹完全匹配的 pending 请求。
- `revoke`：撤销指定 client 的配对并取消其任务。
- `stop`：活动任务或 in-flight 请求非空时拒绝；空闲时请求 helper 关闭 listener 并退出。
- `challenge`：helper 用服务器身份签名 host nonce；host 用 pin 验证，随后才信任该身份。

control 消息不能携带 shell 命令、任意文件路径或模型生成的权限决定。真实终端/文件仍走原有
paired-client RPC，并继续由 `BridgeService`/`BridgeJobs` 的任务归属和权限路径处理。

## 现有 Bridge 在线时

`BridgeEndpointInspector` 只读检查 43871 的 listener PID、可执行路径、Bundle ID/版本、真实数据
的配对/任务数量。它发送一个**未配对、签名、只读**的 `ping` 以观察服务端签名密钥；随后用现有
`paired-clients.json` 中保存的 `verification`（clientKey + serverKey + nonce 的配对校验串）核对
该密钥是否就是已配对客户端批准过的服务端身份。匹配时报告为已绑定到现有配对；不匹配时明确标注
“self-signed, not anchored to a trusted pin”。检查不会创建 pending pairing、不会启动/停止/终止
外部进程、不会读取客户端私钥、不会修改真实数据。

若 listener 是本 App 上一次留下的同包 helper，且 discovery/token/socket 匹配，host 会通过认证
control channel **重新连接**，而不是误报冲突或再启动一个服务。

## 跨进程单所有者与平台边界

- 新的 embedded helper 和新的 standalone Bridge 在启动时对
  `<Bridge 数据根>/State/bridge-store.lock` 取 `flock(LOCK_EX | LOCK_NB)`，并持有到进程
  退出或崩溃。`BridgeServiceMain` 在读取/创建身份、配对、任务和工作区之前取锁；取不到就失败关闭，
  不写真实配对文件。锁文件本身是普通文件、0600，owner 记录只用于诊断，真正的互斥由内核锁提供。
- 旧版 1.1.4/1.1.5 standalone 不取该锁。它们仍绑定固定 `127.0.0.1:43871`；host 对已占用 listener
  只做只读识别并拒绝启动/替换，embedded 的 listener 也会绑定失败并退出。因此旧版并发保护仅由
  端口互斥和 host 检查提供；不能声称新旧双跑、迁移或双写安全。
- 复用边界：配对快照与逐次精确决定、stop/signal/orphan admission、host claim 状态机和控制协议
  是平台无关的领域逻辑；`flock`、Unix domain socket、PTY、TCC、Keychain、NSAlert 和
  `NWListener` 是 macOS 适配层。本轮没有 Linux/Windows 实现，也不声称这些 Swift 组件已经在
  Linux 或 Windows 运行；桌面平台继续统一使用 OpenCode 作为执行 Harness。

## 退出与恢复

- 关闭窗口：App 保持运行，Bridge 服务继续；Dock/Window 菜单可重新打开。
- 切换 Agent/Bridge：只切换界面，不重启服务、不迁移/重跑任务。
- 退出 App：先读取实时 status；有活动任务或 in-flight 请求时拒绝退出并显示原因；空闲时请求
  helper 停止，未确认停止则不强制杀进程。
- UI 崩溃/父进程消失：helper 若仍有活动任务则继续服务并保留结果；任务结束且 grace 到期后退出。
  没有活动工作时不会留下长期孤立服务。
- 显式 Stop：只在实时活动任务为空时执行；未知结果任务保留在磁盘，不自动重跑。
- SIGTERM/SIGINT：有活动工作时拒绝结束；空闲时走同一停止路径。
- 快速 stop/start：进程 termination handler、readiness、status polling 均绑定 generation 和 PID，
  过期回调不能改写新实例状态。

## 构建与验证

要求：Xcode 27.2（`/Applications/Xcode.app`）、`xcodegen`、Apple Silicon、内部 SSD。

```bash
# 完整单包（仍受 30 GiB 与编译互斥门槛约束）
FloeMac/scripts/build_m00.sh

# 历史 fixture 验收命令：当前隔离不足，不要运行；修复并验证后再启用。
FloeMac/scripts/verify_m00_isolated.sh \
  --helper-app <Build/Products/Debug/FloeMacBridgeService.app> \
  --products-dir <Build/Products/Debug>
```

`verify_m00_isolated.sh` 编译两个探针、创建独立 fixture/victim 根、复制已签名 helper 入口、
运行真实 PTY 任务与控制 stop，并从外部用同一 profile 验证 home/Bridge/Keychain/victim/
外部网络/43871 的拒绝。它只停止自己启动的 PID，不清理或重启用户 Bridge。

`build_m00.sh` 的硬门禁（没有环境变量绕过）：

- 内部 SSD 可用空间必须 ≥ 30 GiB；
- 启动时不得存在其他 `xcodebuild` / `swift-build` / `swift-frontend` 编译；
- 使用 `~/Library/Caches/CodexBuild/floe-mac-m00/<checkout-id>/<toolchain>/` 专属 scratch；
- ad-hoc 签名失败或 `codesign --verify --deep --strict` 失败都会使构建失败；
- 仅本地 ad-hoc 签名；不安装、不公证、不上传。

`verify_m00_isolated.sh` 不构建，只运行已组装的 helper；它不会读取真实 Keychain 或 Bridge 内容。
验证覆盖内核沙箱自检与外部独立探针、真实 PTY 子 shell 继承限制、控制 challenge/claim、
活动任务停止拒绝、正常停止、ephemeral 端口、恶意前缀/根符号链接/Control/ready/identity/
祖先替换以及启动后 Control 替换。旧的 `verify_m00.sh` 含真实 Keychain/生产探针，只保留为
生产路径历史记录，不得用于隔离验收。

## Developer ID 版 CloudKit 签名

Mac OTA 使用 `org.floeagent.macbridge`。CloudKit 使用和 iOS / iPadOS 相同的 `iCloud.org.floeagent.ios` Production 容器。在 Apple Developer 为 Mac App ID 关联该容器，并为现有 Developer ID Application 证书生成 Developer ID 描述文件。

在打包工作副本上运行 `python3 FloeMac/scripts/sign_ota_cloudkit.py --check <app> <profile>` 检查描述文件。移除 `--check` 后，脚本将通过校验的描述文件嵌入 `Contents/embedded.provisionprofile`，并用原证书签署 `FloeMacHost-OTA-CloudKit.entitlements`。随后按 OTA 流程公证应用与 DMG，校验旧 Bridge 的签名要求和已发布安装包的更新签名。描述文件从 Apple Developer 下载并保存在构建机的私有配置目录。

签名配置只授予容器访问。实际同步需要应用接入适当的数据源，并在本机与另一台设备验证传输和冲突处理。

## 已验证与未完成

M00 的 CLI/headless 证据见 `M00_VERIFICATION.md`。本轮新增的并发配对/停止准入/host takeover
测试位于 `FloeMac/Tests`，使用临时目录、临时 Unix socket、临时 loopback 端口和注入身份；它们是
fixture 测试，不是实际 App/GUI 验收。以下仍属于主负责人或后续阶段：

- 打包 host/UI 的 fixture 接线（合规根工厂、ephemeral 端口和 host 探针）尚未更新；本轮验收是
  helper CLI + 独立控制/PTY 探针，不是实际 App GUI；实际 GUI 点击、鼠标/键盘/窗口行为和视觉验收
  仍未执行；
- 完整 iPad shell、聊天/任务/设置 UI、OpenCode 适配器、格式化/Office/专业工作台；
- 正式 Developer ID 签名后的旧 Keychain 迁移、公证、安装、自动更新和分发；
- 真实 iPad 远程连接、跨设备同步/交接和 Floe-owned 目标协调器；
- M02 的 Floe 自动审批引擎与审计。

## 并行 Bridge 分支说明

`codex/bridge-115` worktree 的独立 Bridge 只有版本号变化：`FloeMacBridge/Info.plist` 从
1.1.4 (7) 到 1.1.5 (8)，没有源码改动。本轮没有吸收该未完成/未协调分支；`FloeMac` 继续
只读编译 `main` 中的 1.1.4 Bridge 源码，helper 自身版本为 0.2.0 (2)。
