# 内容更新与供应商目录升级（2026-10-09）

Content updates, provider catalog and traditional skills — implementation record.

## 范围 / Scope

- 共用签名内容更新基础：`SignedContentFeed`（Ed25519、严格三段版本、不可变版本、依赖/能力校验）、`SignedContentArchive`（有界解包、原子安装事务）、`ContentUpdateStore`（actor，版本不可变目录 + 单一 `active.json` 原子提交 + ledger + run 快照）、`ContentPackageCodec`（域 schema）。
- `content-hub/`：`index.json` + 签名工具（`build.py --sign/--check/--fixture`）、五类内容包（prompts/help/templates/providers/models）；`skill-hub` 旧入口保持兼容，`OfficialSkillHub` 已改为复用共用基础。
- 设置与运行时接线：设置→内部提示词、设置→通用→内容更新管理、模型供应商可搜索目录；`ContentUpdateCenter` 负责每日检查、失败退避、WiFi 自动下载、内置基线接管与回退。
- 提示词消费链：`AgentPromptOverlay` 只允许 `method/communication/delivery` 三个稳定 section，替换对应内置段；权限审批、工具协议、路由、失败处理与模式层永远由代码固定。任务开始即冻结内容版本与内置字节。
- 传统 Skill：`SKILL.md` + 可选 `floe.json` + scripts/references/assets/agents；无 manifest 时由侧车（安装记录）提供合成 manifest，包内字节不变；Shell/Node/混合脚本复用现有 `exec.shell` 任务环境（本地 Linux guest 或远程主机），Python 纯脚本沿用 `python.local`。
- 运行时修复：DeepSeek `reasoning_effort` 映射（low/low，medium→high 兼容别名，max/max）、`ModelDiscovery` 不再虚构 8192 输出上限（仅信任正数 metadata，否则 unset，合并保留用户显式 limits）、本地安全截断改为本地化 `.notice`（与 `noFinalText`/provider `length` 区分，不误报失败）。
- 本地化：cherry-pick `6f968bff`（3939 键）并为本轮新增字符串继续补齐，catalog 校验通过（4071 键）。

## 验证 / Verification

- 工具链：Xcode 27（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`），Swift 6 语言模式。
- Swift 包定向测试（`swift test --package-path FloeAgent --scratch-path ~/Library/Caches/CodexBuild/floe-content-upgrade/content-upgrade -j 6`）：
  - `FloeSkills` 66、`FloeProviders` 62、`FloeCore.AgentPromptOverlay` 3、`FloeAgentRuntime`（overlay + run service）20，全部通过。
  - 覆盖：签名/篡改/未知键、严格版本、同版异构、降级/pin/依赖/能力、批量原子提交与故障回滚、ledger、rollback 兼容与依赖、内置字节冻结、run 快照释放、provider 目录严格校验与搜索排序、合并保留显式 limits、传统包与侧车 manifest。
- `content-hub`：`python3 content-hub/test_build.py` 9/9；`build.py --check --fixture Local/Private/content-update-fixtures/basic` 验证本地签名 fixture。
- 官方签名目录已由 coordinator 发布并独立验证通过（签名 workflow run 37877603979：5 个内容包全部从不可变 commit `8121c9d4d435178d46f07f0088aec7196977210f` 下载并在本地完成签名/哈希校验；签名合并 `74c2a159`，文档 `712b79f9`；首次未签名预检 run 37877593108 因缺 `index.sig` 失败，原始失败日志保留为 `content-hub-before-signing-failure.log`）。App 侧对签名 feed 的拉取/安装路径实现完成；针对**真实签名 commit** 的 check→install→生效链路以可注入源对真实 `ContentUpdateCenter` 做定向集成验证（见下“App 端真实签名链路”），本轮不发布、不改生产默认 main 源。
- 完整 App：`xcodebuild -project FloeAgent/FloeAgent.xcodeproj -scheme FloeAgent -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/Library/Caches/CodexBuild/floe-content-upgrade/content-upgrade-app CODE_SIGNING_ALLOWED=NO -jobs 6 build` → **BUILD SUCCEEDED**。注意：此前“FloeAppTests 全量运行为绿”的说法不准确，已更正——`-only-testing:FloeAppTests` 运行中有 4 个环境相关用例失败（LinuxPortForwardCenter 沙盒端口探测、SourceControlRootIdentity 的 UserDefaults 顺序、OfficeBridge 渲染门时序、CapabilityExecutionRouter 全局配置）；它们未在干净基线重跑验证，因此**记为未决、不得断言为既有失败**，原始结果保留在本轮证据中。
- 未执行：Swift 6 object/SIL 级别的额外独立编译（App 构建已覆盖）、iPad 真机 UI 验收、真实供应商连通/模型调用验证。

## App 端真实签名链路 / App real signed feed path

- 生产默认 main 源与信任根均未改动；集成验证通过可注入源/测试配置指向公开可读的不可变 commit `8121c9d4d435178d46f07f0088aec7196977210f`，驱动真实 `ContentUpdateCenter` + 真实 `ContentUpdateStore` 完成：
  - check：从该 commit 取 commit/index/signature 并用编译进应用的 Ed25519 信任根验证通过，`floe.prompts.core` 1.2.0 决策为可更新；
  - install：下载真实签名 zip，经原子提交落盘，`installed` 记录 1.2.0 且 digest 非空；
  - 生效：评审缓存 `promptSections()` 来自签名包，且**运行时消费** `runtimePromptOverlay(runID:locale:)` 返回签名包内容（delivery/communication/method，中英文各自取本地化字节）——这证明运行时 overlay 被真实消费，**不等于**发起了真实模型请求；
  - 复检：再次 check 对同一不可变 feed 报告 `upToDate`（不重复安装）；
  - 篡改签名被编译信任根拒绝（负向用例）。
  - 未覆盖：provider catalog 切换与 rollback（该不可变 feed 只发布一个 prompts 版本，store 中无可回退的历史版本；rollback/原子失败路径由 `ContentUpdateStoreTests` 单元覆盖，本测试注释中已说明）。不引入平行更新实现、不发布。测试 `FloeAppTests/ContentUpdateRealSignedFeedTests.swift` 通过；结果与失败证据见本轮测试与 `Local/Private/evidence/content-upgrade-20261009/`。

## 设置/供应商 UI 复查 / Settings & provider UI review

2026-10-09 由主代理在 iPad Air 13 英寸（M4）iOS 27 模拟器 `37D8E931` 上对源码构建（至 `83bb4522` 及本轮本地化修正）完成：

- 设置 → 内部提示词为独立侧栏条目；此前强制检查弹出英文 GitHub 源错误弹窗的问题已消失；无签名包时离线显示内置段落，竖/横屏保持选择状态。
- 内置提示词版本独立于 App 营销版本展示；内置正文保持编译原文。复查发现中文界面两个内置章节标题仍为英文（“Delivering work / Communicating with the user”），本轮已改为**仅 UI 按 `section.id` 映射本地化标题**（en/zh-Hans），运行时冻结的英文标题与正文逐字不变，不把 UI 翻译混入模型内容。
- 供应商目录由入口“+”菜单打开为页尺寸、可搜索的预置目录；本地搜索可收窄结果；选择 DeepSeek 打开既有编辑器（Chat Completions、预期公开端点、凭据为空）。未做真实网络/模型鉴权。

## 剩余门槛 / Remaining gates

- ~~`content-hub/index.sig` 正式密钥签名发布~~：已完成（run 37877603979，见上），不再是门槛。
- App 端真实签名 check→install→生效：以可注入源完成定向集成验证；生产 main feed 的实际设备切换在用户后续选择发布时再做，本轮不发布。
- 4 个环境相关 FloeAppTests 失败保持未决，除非在干净基线复跑确认，否则不计为既有失败。
- 设置页与供应商目录搜索的 iPad **真机**交互验收仍留给用户（模拟器复查已完成）。
- 真实 models.dev 目录已固定为快照 SHA-256（`content-hub/providers/SOURCE.json`），上游 git revision 仅作参考；重新导入需 `--update-source` 显式重钉。
- 未在本轮新增：OAuth 供应商接入、任意请求转换脚本、远程表达式、第二套执行引擎。

## 关键路径 / Key paths

- `FloeAgent/Sources/FloeSkills/{SignedContentFeed,SignedContentArchive,ContentUpdateStore,ContentPackageCodec,OfficialSkillHub}.swift`
- `FloeAgent/Sources/FloeCore/AgentPromptOverlay.swift`
- `FloeAgent/Sources/FloeAgentRuntime/{AgentPromptComposer,ConversationRunService}.swift`
- `FloeAgent/FloeApp/Content/ContentUpdateCenter.swift`、`FloeAgent/FloeApp/Settings/{InternalPromptsSettingsView,ContentUpdatesSettingsView}.swift`
- `FloeAgent/FloeApp/Providers/{ProviderCatalogAddView,ProviderListView}.swift`
- `content-hub/`、`FloeAgent/FloeApp/Resources/ProviderCatalog.json`
