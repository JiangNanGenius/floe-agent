# 视频凭证解析链路审计（Volcengine Ark 401）

日期：2026-09-19 · 状态：代码缺陷已最小修复，待真机复测

## 现象

真机上 `video.models` 能列出已配置的 Seedance 2.5 / providerID，同设备方舟生图与模型测速均正常，但 `video.generate` 返回 HTTP 401（missing or invalid API key）。

## 实际调用链（修复前）

1. `video.generate` → `RemoteVideoGenerateTool.submit`（`FloeAgent/FloeApp/Conversations/RemoteVideoTools.swift:155`）
2. `conversation.resolveAgentVideoRoute(modelID:selection:)`（`FloeAgent/FloeApp/Remote/ConversationCenter.swift:3501`）→ 按公开候选名/preferred 选择路由；`providers.first(where: { $0.id == route.providerID })`（:3519）——**路由按 route.providerID 取供应商，不使用当前聊天模型供应商，无跨供应商串用**。
3. `mediaGenerationService.submitVideo`（`FloeAgent/FloeApp/Platform/BackgroundRunCoordinator.swift:2009`）→ `configurationStore.provider(id: model.providerID)` 取同一供应商；job 快照 `credentialReference = provider.secretRef`（:2035）。
4. `videoCredential(for:)`（旧 :2100）→ `environment.keychain.read(account:)`；`environment.keychain = KeychainStore(service: "org.floeagent.ios.providers")`（`FloeAgent/FloeApp/App/AppEnvironment.swift:931`）。
5. `VolcengineVideoAdapter.submit` → `VideoHTTP.request`：`credentials.apiKey == nil` 时**不写 Authorization 头**（`FloeAgent/Sources/FloeProviders/VideoProviderAdapter.swift:155`）→ 方舟返回 401 `The API key is missing or invalid`。

## 对照正常路径

| 路径 | 凭证读取 | 命名空间 |
| --- | --- | --- |
| 方舟生图 `generateImages` | `center.resolveCredentials(for:)`（BackgroundRunCoordinator.swift:1664） | `org.floeagent.ios.secrets` ✓ |
| 模型测速/连接测试 | `center.resolveCredentials` / `KeychainSecretStore` | `org.floeagent.ios.secrets` ✓ |
| 聊天流式 | `center.resolveCredentials`（ConversationCenter.swift:425 等） | `org.floeagent.ios.secrets` ✓ |
| 视频提交/轮询/取消（旧） | `environment.keychain` | `org.floeagent.ios.providers` ✗ |

唯一写入路径是 `ProviderEditorViewModel.save` → `KeychainSecretStore.storeSecret(scope: .provider)` → 服务名 `org.floeagent.ios.secrets`、账户 `provider.<uuid>`（`FloeAgent/Sources/FloeSync/KeychainSecretStore.swift:105`）。**历史上无任何代码向 `org.floeagent.ios.providers` 写入供应商密钥**（自 8131fddd 起即为 secrets 命名空间），故旧视频读取恒为 nil，无需迁移。

## 修复（最小）

- `FloeAgent/Sources/FloeSync/KeychainSecretStore.swift`：新增 `readSecret(reference:)` —— 与 `ConversationCenter.resolveCredentials` 完全一致的语义（声明的 synchronizable 域优先、另一域兜底、secrets 命名空间）；内部 reader 可注入以便无 Keychain 的确定性测试。
- `FloeAgent/FloeApp/Platform/BackgroundRunCoordinator.swift`：`videoCredential(for:)` 改走 `KeychainSecretStore().readSecret(reference:)`；空/空白密钥归一为 nil；日志只记录 provider/model 标识、keychainAccount 与 key 是否存在（`videoSubmitAuthenticated` / `videoCredentialMissing`），不记录密钥内容。

## 验证（轻量，未跑完整 App 构建）

- `swiftc -parse`：KeychainSecretStore.swift、BackgroundRunCoordinator.swift、VideoCredentialResolutionTests.swift 均通过。
- 内存伪 Keychain harness 编译**真实** `KeychainSecretStore.swift`（Swift 6，副本经 diff 校验仅差 import 行）：11 项全过 —— 声明域优先、双域兜底、旧命名空间诱饵不被读取、多供应商假凭证互不串用、重启后轮询解析一致。
- 新增 `FloeAgent/Tests/FloeSyncTests/VideoCredentialResolutionTests.swift`（假凭证 + 注入 reader，留待 CI 的 SwiftPM 测试执行）。
- 未发起任何真实付费视频调用；未读取/打印/持久化真实密钥。

## 仍需真机验证

1. 真机 `video.generate`（Seedance 2.5）一次提交成功，provider 控制台可见任务；观察 `videoSubmitAuthenticated keyPresent=true`。
2. 重启 App 后 `video.status` 轮询/续传成功（job 凭引用快照解析）。
3. 供应商关闭"凭证同步"（纯本地域）后视频仍可用（兜底路径）。
4. Google/Alibaba 视频路由各自使用自己的密钥（多供应商隔离）。
