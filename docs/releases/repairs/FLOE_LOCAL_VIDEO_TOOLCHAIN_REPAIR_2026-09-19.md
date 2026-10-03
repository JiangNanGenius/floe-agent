# 本地模型 / 视频选择 / 工具上下文链路修复记录（2026-09-19）

- 触发来源：用户 2026-09-19 反馈（`Floe工具链路测试记录_v3.md`）与本地模型反馈续作。
- 范围：`FloeLocalModels`、`FloeProviders`、`FloeAgentRuntime`、`FloeTools`、`FloeApp`、定向测试与本文档。
- 明确未做：完整 App 构建、UI 矩阵、发布/上传、Office、思维导图、APT、真机运行。
- 状态：代码改动位于工作区（未提交）。真机项见第 5 节。

## 1. 根因

### 1.1 本地模型：测速成功、普通聊天首次真实消息等待后闪退

线上证据（Build 178/191 崩溃表）把终止点定位在 MLX Qwen
GatedDeltaNet 分块 prefill（`gatedDeltaUpdate`），基准测速与普通聊天的差别在
**请求上下文**，而不在引擎：

1. **云看门狗会取消本地生成。** `FloeAgentRuntime.startProviderWatchdog`
   对所有 provider 使用 120 s“首个事件”超时（`AgentRuntime.swift:293-300`、
   原 `:3040`）。本地 MLX 适配器在 `completeMeasured` 返回前**不产出任何
   provider 事件**（`LocalProviderAdapter.swift:599-607` 先把完整生成 await
   完再 yield），因此一次较大的首次 prefill + 解码一旦超过 120 s，看门狗会
   报“Cloud model stream stalled”、调度重连并 `streamTask.cancel()`
   （`AgentRuntime.swift:3093-3104`），随后 `onTermination` 取消 MLX 生成任务
   （`LocalProviderAdapter.swift:704`）。在分块 prefill 中途取消正是
   `docs/qualification/build191-feedback/local-model.md` 记录的危险路径。
   测速只用 31 字符提示、96 token、`tools: []`（`LocalProviderAdapter.swift:335-352`），
   几秒完成，永远碰不到该超时——与“测速成功、聊天闪退”完全一致。
2. **首次聊天提示远大于测速。** 适配器此前无上限地拼接 harness 系统信封
   （`LocalProviderAdapter.swift:808-812` 原实现），首次消息实测
   `sourceCharacters=12015`、prepared≈4.8K token（`FloeAgent/Qualification/LocalInference/README.md`）。
   首次 prefill 因此是多分块大内存路径，测速路径不覆盖。

修复：
- `.local` provider 不再启动云看门狗（保留用户停止/取消），并输出
  `providerWatchdogDisabled reason=onDeviceGeneration`；等待文案改为
  on-device 语义（`AgentRuntime.swift:3076-3090`、`:1535-1540`）。
- 本地系统信封按 tier 截断（head+tail 保留运行上下文与实时时钟）
  （`LocalProviderAdapter.swift:855-866`、`:1196-1250`）。
- 未宣称修复上游 GDN 融合内核 abort；它仍是上游残余，需真机确认（第 5 节）。

### 1.2 视频：已配置方舟视频模型无法发现、被迫提供内部 UUID

- `video.generate` 的 `modelID` 是 `UUID` 且 schema 为 `format:uuid`
  （原 `RemoteVideoTools.swift:107/129`），公开名（`doubao-seedance-2-5-260628`）
  会解码失败；`resolveAgentVideoRoute` 只接受内部 UUID
  （原 `ConversationCenter.swift:3420-3439`）。
- 画布 agent 的 ceiling `CanvasAgentToolPolicy.nativeToolNames` 不含任何
  `video.*`，而 `canvas.generate` 的 video 分支硬性要求 `modelID`
  （原 `CanvasAgentTools.swift:1035-1037`、`:537-539`），因此画布中无法发现候选、
  只能向用户索要 UUID。
- 发现层：`ToolAliasTable.synonyms` 把“视频”归到 `canvas` 组，普通聊天里
  canvas 工具随后被移除，`video.*` 不会被加载；`ToolDiscovery.index` 也没有
  视频选择说明。

修复：
- `VideoModelRegistry.resolve(modelID:selection:routes:)`：支持 UUID 拼写、
  `remoteModelID`、显示名、忽略大小写/分隔符的精确/前缀/包含匹配；歧义或未知
  时返回公开候选列表且**不回显内部 UUID**（`VideoModelRegistry.swift:146-212`）。
  新增 `publicModelID`（`:66`）与 `publicCandidates`（`:215-224`）。
- `video.models` 每个条目新增 `"model"`（公开名）并更新 policy；`video.generate`
  新增可选 `model` 参数并在描述中明确“由当前对话模型在公开候选间自行选择，
  不得向用户索要 UUID”（`RemoteVideoTools.swift:26-28/58-76/105-140/157-166`）。
- 画布：`canvas.generate` 新增公开 `model` 参数、省略时解析首选路由；
  coordinator 新增 `resolveVideoModel` 闭包（`CanvasAgentTools.swift:224/246/373-391`、
  `:1035-1067`、`registerCanvasAgentTools :1145-1155`）；画布 ceiling 增加只读
  `video.models` 供选择候选（`CanvasAgentToolPolicy.swift:17-22`）。
- 发现层：新增 `video` 同义词组并在索引中说明选择方式
  （`ToolAliasTable.swift:49-50`、`ToolDiscovery.swift:155-157`）。

### 1.3 工具调用/结果回灌不稳定导致模型遗忘

- **跨 run 断裂（主因）**：工具调用/结果只写入 append-only run_events
  （`ConversationRunService.swift:856-893`），对话消息表从不含工具行；新 run 由
  `ConversationHistoryAssembler` 仅按消息构建历史（工具证据为 0）。
- **本地模型从不回放**：`LocalProviderAdapter` 只渲染当前 pending 的
  `suffix(2)`，从不读取 `request.replayedToolPairs`。
- **压缩后回注被过滤**：压缩摘要前缀 `[Context compaction notice]`
  （`ConversationHistoryAssembler.swift:252-260`）与手动快照
  `[Manual context snapshot]`（`ConversationCenter.swift:224`）都不在
  `seedConversationHistory` 白名单（原 `AgentRuntime.swift:646-651`），续跑 run
  会丢失摘要。
- **上下文预算未计回放字节**：压缩触发只估算 `messages`，回放通道最多再加
  ~96 KiB（`ToolReplayPlanner` 预算）。
- **重试快照缺工具全集**：`ProviderDispatchRequestSnapshot` 未持久化
  `allToolNames`，重启后 compat 反向命名映射退化。

修复：
- 新增跨 run 脱敏工具证据：只读最近 4 个 run 的 `.toolResult` 事件，仅取
  tool/status/callID/有界摘要，2,400 字符预算，head+tail 截断，作为
  `FloeAgentRuntime.priorToolEvidencePrefix` 系统消息注入
  （`ConversationCenter.swift:2072-2132`、`:2178-2183`、`:2294`），并在 seed
  白名单中放行（`AgentRuntime.swift:654-665`）。
- 本地 prompt 增加有界回放投影（tier 600–2,000 字符、2–6 对，最新优先，输出按
  时间顺序）（`LocalProviderAdapter.swift:968-1000`、`:1196-1250`）；Apple FM 的
  重建 transcript 也带上已提供 schema 的历史工具对
  （`LocalProviderAdapter.swift:580-600`）。
- 压缩摘要前缀放行（同上）；回放字节计入压缩触发
  （`AgentRuntime.swift:1162`、`replayEvidenceTokenEstimate :2790-2802`）。
- 派发快照新增可选 `allToolNames`（`AgentCheckpoint.swift:168-172`、`:192-227`）。
- 新增脱敏生命周期日志：`toolEvidenceReplayed pairs/evidenceBytes`、
  `toolEvidenceRecovered runs/results/characters`、`providerWatchdogDisabled`、
  `localPromptPrepared … replayedToolPairs/systemCharacters`、
  `videoRouteResolved` / `videoRouteResolutionFailed`。日志只含计数、工具名与
  公开模型名，不含参数、结果正文或密钥。

会话隔离：跨 run 证据只按同一 `conversationID` 读取，且仅用于 `.ordinary`
run；画布/手记的专用会话不会拿到普通聊天证据，画布仍走 `canvas.generate`。

## 2. 修改文件

| 文件 | 内容 |
| --- | --- |
| `FloeAgent/Sources/FloeProviders/VideoModelRegistry.swift` | 公开候选解析、`publicModelID`、`publicCandidates` |
| `FloeAgent/FloeApp/Conversations/RemoteVideoTools.swift` | `model` 参数、schema/描述、`video.models` 公开名与 policy、解析日志 |
| `FloeAgent/FloeApp/Remote/ConversationCenter.swift` | `resolveAgentVideoRoute(selection:)`、跨 run 工具证据恢复 |
| `FloeAgent/FloeApp/Workspace/CanvasAgentTools.swift` | coordinator `resolveVideoModel`、`canvas.generate` 公开选择、日志 |
| `FloeAgent/Sources/FloeTools/CanvasAgentToolPolicy.swift` | 画布 ceiling 增加只读 `video.models` |
| `FloeAgent/Sources/FloeTools/ToolAliasTable.swift` | `video` 同义词组 |
| `FloeAgent/Sources/FloeAgentRuntime/ToolDiscovery.swift` | 视频选择索引说明 |
| `FloeAgent/Sources/FloeAgentRuntime/AgentRuntime.swift` | 本地免看门狗、seed 白名单、回放字节预算、日志 |
| `FloeAgent/Sources/FloeAgentRuntime/AgentCheckpoint.swift` | 快照持久化 `allToolNames` |
| `FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift` | 回放投影、Apple 工具历史、系统信封上限、日志 |
| `FloeAgent/Tests/FloeProvidersTests/VideoModelRouteResolutionTests.swift` | 新增公开候选解析测试 |
| `FloeAgent/Tests/FloeLocalModelsTests/LocalPromptHarnessTests.swift` | 新增回放/预算测试 |
| `FloeAgent/Tests/FloeAgentRuntimeTests/ProviderRecoveryTests.swift` | 本地免看门狗、快照工具全集测试 |
| `FloeAgent/Tests/FloeAgentRuntimeTests/AgentRuntimeTests.swift` | seed 白名单测试 |
| `FloeAgent/Tests/FloeAgentUITests/CanvasAgentToolContractTests.swift` | 适配 coordinator 新闭包 |

## 3. 本地验证（实际执行）

| 命令 | 结果 |
| --- | --- |
| `swiftc -parse -swift-version 6`（全部改动 .swift） | exit 0 |
| FloeProviders 全模块 `swiftc -typecheck`（Swift 6，CLT） | exit 0 |
| FloeTools 全模块 `swiftc -typecheck` | exit 0 |
| FloeAgentRuntime 全模块 `swiftc -typecheck`（Xcode-beta 6.4.0.30.4 + 预编译依赖） | exit 0 |
| FloeLocalModels 定向 `-typecheck`（真实 LocalProviderAdapter/LlamaTextEngine/Apple 运行时 + MLX 引擎桩） | exit 0 |
| 视频路由探针（真实 `VideoModelRegistry` 源码编译运行） | 15/15 PASS |
| 工具发现探针（真实 `ToolDiscovery.matches` + 新同义词） | PASS：中文“生成视频”与英文 video 查询均加载 `video.models`/`video.generate`，无关文件查询不加载 |
| 本地 prompt 探针（真实 `LocalProviderAdapter.buildPrompt`） | 13/13 PASS |
| `bash FloeAgent/scripts/tests/local_model/run_local_model_lifecycle_checks.sh` | `RESULT: PASS`（15 夹具、39 生命周期夹具、macOS SIL、iPhoneOS27.0 SDK SIL/object） |
| 新增/修改测试文件 `-typecheck`（Testing 宏） | 全部 exit 0 |

说明：App target 源文件（`FloeApp/`）本机无法做完整语义编译（未做完整 App 构建），
本轮对它们使用 `-parse` + 逐处符号核对；`CanvasAgentToolContractTests` 的构造点已
同步更新。

## 4. 未验证 / 需真机与云端确认

- 本地模型前台 GDN `gatedDeltaUpdate` abort 未宣称修复；本轮只关闭了“云看门狗
  取消本地 GPU 工作”这一可复现的取消竞态并压缩首次提示。需要云端 App 构建 +
  真机：观察长 prefill 是否仍在 `localInferencePrefillFailed` 处终止。
- 真机若仍闪退，请取 `.ips` 与 build191 帧表比对，并回传
  `providerWatchdogDisabled` / `localInferencePrepared` / `localInferencePrefillFailed`
  日志。
- 未在本机触发真实方舟视频提交（凭证、付费调用与网络不在本轮范围）；公开名解析、
  歧义报错、省略选择走首选路由由源码级探针覆盖，端到端出片仍需真机 + 有效 Key。
- 画布/普通聊天中“模型自主选候选”的实际模型行为需要真机对话验证。
- 跨 run 工具证据恢复的端到端效果（长对话、重启后续跑）需真机/云端回归。
- 未提交、未推送、未构建 IPA、未上传。

## 5. 中文摘要

本轮修复三条链路：(1) 本地模型：普通聊天首个真实请求在 120 s 云看门狗处被误取消，
取消落在 MLX 分块 prefill 上（崩溃邻近路径）；现对 on-device provider 关闭该看门狗
（保留用户取消），并把无上限的 harness 系统信封按上下文档位截断，减少首次 prefill
规模；上游 GDN abort 仍需真机确认。(2) 视频：新增公开候选解析，`video.generate` /
`canvas.generate` 接受 `model`（remoteModelID 或显示名），省略时用首选路由；画布
ceiling 增加只读 `video.models`，发现层新增 `video` 同义词与索引说明——用户不再需要
提供内部 UUID，多候选由当前对话模型自行选择。(3) 工具上下文：跨 run 从 run_events
恢复有界脱敏工具证据、seed 白名单放行压缩摘要与工具证据、本地模型回放
`replayedToolPairs`（Apple FM 同步）、回放字节计入压缩预算、重试快照补齐
`allToolNames`；并补充多条脱敏生命周期日志。所有本地定向检查通过，未做完整 App
构建与发布。
