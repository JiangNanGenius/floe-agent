# 内容更新与供应商目录升级（2026-10-09）

Content updates, provider catalog and traditional skills — implementation record.

## 范围 / Scope

- 共用签名内容更新基础：`SignedContentFeed`（Ed25519、严格三段版本、不可变版本、依赖/能力校验）、`SignedContentArchive`（有界解包、原子安装事务）、`ContentUpdateStore`（actor，版本不可变目录 + 单一 `active.json` 原子提交 + ledger + run 快照）、`ContentPackageCodec`（域 schema）。
- `content-hub/`：`index.json` + 签名工具（`build.py --sign/--check/--fixture`）、五类内容包（prompts/help/templates/providers/models）；`skill-hub` 旧入口保持兼容，`OfficialSkillHub` 已改为复用共用基础。
- 设置与运行时接线：设置→内部提示词、设置→通用→内容更新管理、模型供应商可搜索目录；`ContentUpdateCenter` 负责每日检查、失败退避、WiFi 自动下载、内置基线接管与回退。
- 提示词消费链：`AgentPromptOverlay` 只允许 `method/communication/delivery` 三个稳定 section，替换对应内置段；权限审批、工具协议、路由、失败处理与模式层永远由代码固定。任务开始即冻结内容版本与内置字节。
- 传统 Skill：`SKILL.md` + 可选 `floe.json` + scripts/references/assets/agents；无 manifest 时由侧车（安装记录）提供合成 manifest，包内字节不变；Shell/Node/混合脚本复用现有 `exec.shell` 任务环境（本地 Linux guest 或远程主机），Python 纯脚本沿用 `python.local`。
- 运行时修复：DeepSeek `reasoning_effort` 映射（low/low，medium→high 兼容别名，max/max）、`ModelDiscovery` 不再虚构 8192 输出上限（仅信任正数 metadata，否则 unset，合并保留用户显式 limits）、本地安全截断改为本地化 `.notice`（与 `noFinalText`/provider `length` 区分，不误报失败）。
- 本地化：cherry-pick `6f968bff`（3939 键）并为本轮新增字符串继续补齐，catalog 校验通过（4050 键）。

## 验证 / Verification

- 工具链：Xcode 27（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`），Swift 6 语言模式。
- Swift 包定向测试（`swift test --package-path FloeAgent --scratch-path ~/Library/Caches/CodexBuild/floe-content-upgrade/content-upgrade -j 6`）：
  - `FloeSkills` 66、`FloeProviders` 62、`FloeCore.AgentPromptOverlay` 3、`FloeAgentRuntime`（overlay + run service）20，全部通过。
  - 覆盖：签名/篡改/未知键、严格版本、同版异构、降级/pin/依赖/能力、批量原子提交与故障回滚、ledger、rollback 兼容与依赖、内置字节冻结、run 快照释放、provider 目录严格校验与搜索排序、合并保留显式 limits、传统包与侧车 manifest。
- `content-hub`：`python3 content-hub/test_build.py` 9/9；`build.py --check --fixture Local/Private/content-update-fixtures/basic` 验证本地签名 fixture（coordinator 发布前需用 `FLOE_CONTENT_HUB_SIGNING_KEY` 生成 `content-hub/index.sig`）。
- 完整 App：`xcodebuild -project FloeAgent/FloeAgent.xcodeproj -scheme FloeAgent -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/Library/Caches/CodexBuild/floe-content-upgrade/content-upgrade-app CODE_SIGNING_ALLOWED=NO -jobs 6 build` → **BUILD SUCCEEDED**（本仓库 `19db9b20` + 本分支改动）。
- 未执行：真实官方 GitHub 目录发布读取（需 coordinator 先发布签名目录）、Swift 6 object/SIL 级别的额外编译（App 构建已覆盖）、iPad 真机 UI 验收、真实供应商连通/模型调用验证。

## 剩余门槛 / Remaining gates

- `content-hub/index.sig` 必须由 coordinator 使用正式密钥签名后在不可变 commit 发布；App 信任根固定，不接受网络更换。
- 设置页与供应商目录搜索的 iPad 真机/模拟器交互验收留给 coordinator（本分支仅完成可审查实现与 App 编译）。
- 真实 models.dev 目录已固定为快照 SHA-256（`content-hub/providers/SOURCE.json`），上游 git revision 仅作参考；重新导入需 `--update-source` 显式重钉。
- 未在本轮新增：OAuth 供应商接入、任意请求转换脚本、远程表达式、第二套执行引擎。

## 关键路径 / Key paths

- `FloeAgent/Sources/FloeSkills/{SignedContentFeed,SignedContentArchive,ContentUpdateStore,ContentPackageCodec,OfficialSkillHub}.swift`
- `FloeAgent/Sources/FloeCore/AgentPromptOverlay.swift`
- `FloeAgent/Sources/FloeAgentRuntime/{AgentPromptComposer,ConversationRunService}.swift`
- `FloeAgent/FloeApp/Content/ContentUpdateCenter.swift`、`FloeAgent/FloeApp/Settings/{InternalPromptsSettingsView,ContentUpdatesSettingsView}.swift`
- `FloeAgent/FloeApp/Providers/{ProviderCatalogAddView,ProviderListView}.swift`
- `content-hub/`、`FloeAgent/FloeApp/Resources/ProviderCatalog.json`
