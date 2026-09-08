# 内部提示词审查（本轮持续更新）

本审查属于完整升级的 H01–H06，尚未完成。只以实际组装与模型运行结果判断效率，不把缩短字数等同于效果提升。

## 已定位的 Floe 来源

- `FloeAgent/Sources/FloeAgentRuntime/AgentPromptComposer.swift`：基础行为、权限、执行、重试、步骤结算、上下文连续性、模式及计划/Goal 状态。
- `ConversationRunService.buildContextMessage`：当前运行环境、工作流和发现路由。
- `ToolDiscovery.swift`：目录摘要、参数加载与常驻工具。
- 工具 schema、Skill 文档、模型/画布专用覆盖和压缩后的注入：仍需沿实际请求组装逐层核实。

已发现一处矛盾：基础操作协议禁止“asking tools what tools exist”，但应用提供 `tools.list` / `tools.search` 用于准确发现工具。现已改为允许专用发现入口，只禁止猜名和向业务工具探测目录；补充三种模式的静态回归，真实模型效率尚待测量。现有路由已经允许已知参数时直接执行，不应恢复“每个领域操作都必须 search→read”这一额外前置步骤。

## 参考来源与采用方向

以下为 2026-09-09 查阅的公开资料，分支内容会变化，后续引用具体实现应记录 commit。这里概括可迁移的机制，不复制第三方整段提示词。

- [Kimi Code agent 定义](https://github.com/MoonshotAI/kimi-cli/blob/main/docs/en/customization/agents.md)：提示词模板和工具配置一起定义，环境变量按运行时注入。用于核对 Floe 提示词宣称的工具与实际注册集合是否一致。
- [DeepSeek Harness system-prompt](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/system-prompt/README.md)：可追溯的分层注册、确定顺序、作用域与工具参数统一组装；静态前缀稳定有利于缓存。用于设计 Floe 分层清单与重复/冲突检查。
- [Claude Code 官方实践](https://code.claude.com/docs/en/best-practices)：给任务可执行的验收条件，保留上下文关键证据并控制探索范围。用于验收和压缩恢复对照任务。
- [Codex 公开 GPT-5.2 模板](https://github.com/openai/codex/blob/main/codex-rs/core/gpt-5.2-codex_prompt.md)：通过 GitHub API 核实文件（blob `8e3f08fb514a6fe82376817aa0a0c960cfbc4656`），简单任务省略计划，多步任务执行后更新计划，并保留用户已有修改。这是仓库中的指定模型模板，不代表本次 Codex 会话或所有模型的当前内部提示词。用于对照 Floe 待办触发和持续维护规则。
- Claude Code 的公开第三方提示词整理库已检索到，但版本与完整性未核实，不能当作官方当前内部提示词。

## 对照结果待补

需要脱敏的最终请求快照、各层长度及实际 token、普通/Goal/画布/恢复各模式样本、重复读 Skill 次数、无效工具调用数和固定任务完成率。静态断言只证明规则存在及相容，不能证明模型更高效。现阶段没有此类效率提升声明。


## 2026-09-09 第二轮：实际调用边界与指南交叉核对

已审查全部 3 份官方源 `SKILL.md` 及 7 份 Swift 内置指南的正文/介绍；这表示已读并核对来源，不代表其全部工具语义、最终新功能或真实模型效果已经验收。官方源通过签名生成 `OfficialBundledSkills.generated.swift`，不能只改生成文件或覆盖旧版本 ZIP。

| 来源与注入时机 | 本轮发现/处理 | 验证边界 |
| --- | --- | --- |
| `AgentPromptComposer` → `ConversationRunService.buildContextMessage`，运行开始/恢复 | 工具关闭时仍出现发现工具和原生计划提交指令；按工具开关生成可执行层，关闭时省略指南 | 普通/计划/Goal 静态组装及工具关闭最终请求回归 |
| `AgentRuntime` 每次 provider dispatch | 无工具请求仍追加目录；计划模式目录要求调用被权限层过滤的待办更新工具 | 两种 provider 消息格式的实际捕获；目录按当前有效集合生成，追加/修改待办说明仅在工具可用时出现 |
| `ToolWorkflowGuidance` 与运行上下文 | 浏览器/VNC 重复注入，VNC 文案要求重复 status/connect，与已连接状态可复用的执行规则不一致 | 合并流程说明，保留连接/新证据/单次输入/不得重放约束；真实远程操作需独立验收 |
| `SkillsCenter.runtimeSelection` / `readSkills` | 每个指南重复要求 read；Python 创建和 Apple 设置提示中有旧的点号 ID | 介绍只列一次元数据；修复为真实连字符 ID；运行快照、脚本审核和当前构建 probe 仍按原路径注入 |
| `SkillSearchTool` / `SkillCreateTool` | 搜索说明强制行动前读指南，与已知工具直接调用冲突；Python 指南 ID 错误 | 说明多查询与完整目录入口；指南按需读取；脚本创建仍需了解当前审核合同 |
| 官方 Office 指南与工具 schema/result | 未提 PPT；基础文本接口暗示更广编辑能力；inspect 声称可供 expectedSHA256 却未返回摘要 | 补充实际 PPT 工具及基础边界；检查和更新都返回真实摘要；使用公开返回值的编辑/旧版本拒绝覆盖回归通过 |
| 官方 Network 指南与 TCP 描述 | 指南宣称默认本机 ping/traceroute，与实现明确不支持矛盾；TCP 描述暗示先 ping | 明确本机 DNS/TCP、远端 ICMP/路由及执行来源，不把 TCP 当 ICMP。本机 ICMP 实现仍属 N01 未完工作 |
| 官方 PDF 源元数据与生成介绍 | SKILL.md 与 release.json 的 description 不同 | 新增签名前一致性检查，统一介绍并增加版本；正文能力仍需随最终 PDF 验收复核 |
| `SkillsCenter.rewriteForCurrentDevice` 辅助无工具请求 | 第二次修复要求“此前 schema”，但请求不携带上一轮；把不能安装 JS 运行时写成所有本地 JS 不可用 | 修复请求携带原候选/schema/权限边界；区分安装脚本与编译基座；外部候选及失败输出标记为待转换数据 |
| 画布 `CanvasNodeRefinementService` | 节点正文、配置、引用与用户编辑指令放在同一消息 | 明确前者是待编辑数据，只按用户编辑指令改；完整图形行为仍待 C01 验收 |
| `SubagentRunner` | 提供的上下文未显式标记为参考数据 | 保持只读/不可再次委派限制，补充上下文不能提高授权 |

[验证摘要](evidence/workflow-upgrade-20260909/prompt-audit-tests-summary.txt)：107 项 Swift 测试通过，另有 4 项官方元数据构建测试。iPad 应用实际首次安装指南、读取并与注册工具交叉核对的单项测试通过（`/tmp/floe-prompt-guide-registry.xcresult`）；此次应用测试在新签名指南生成之前完成，生成后需再验。

保留了 5 个真实请求组装路径的**合成输入**捕获：[普通](evidence/workflow-upgrade-20260909/prompt-snapshots/chat.json)、[计划](evidence/workflow-upgrade-20260909/prompt-snapshots/plan.json)、[Goal 模式](evidence/workflow-upgrade-20260909/prompt-snapshots/goal.json)、[模型无工具能力](evidence/workflow-upgrade-20260909/prompt-snapshots/model-without-tools.json)、[用户关闭工具](evidence/workflow-upgrade-20260909/prompt-snapshots/tools-disabled.json)。记录系统消息、工具名、字符数和 UTF-8 长度，不含凭据；未调用真实模型，字符数不能冒充实际 token 或缓存收益。Goal 样本只验证模式和工具层，不代表完整持久 Goal/恢复样本。

## 仍须完成的最终审查

- 本地模型的 `LocalProviderAdapter.promptBuild` 会另行生成短提示词，并丢弃大部分运行系统层；非 Apple 路径仍描述 JSON tool_call 兼容回退。须对照实际解析/权限边界验证，确保最新用户修正、计划/Goal/恢复关键状态不会丢失，不能据云端回归认定本地模型通过。
- `ContextEngine`、`ConversationHistoryAssembler`、手动压缩、恢复/重试/最终校验插入层：当前已有连续性测试，仍需覆盖长任务实际最终请求与全部分支的重复指令。
- `ConversationCenter` 的图像转述、Goal 证据判断、标题生成；画布墨迹/视觉辅助/生成上下文；记忆整理/MemoryDream/SkillDream 辅助请求：已定位并阅读相关来源，仍需固定合成任务验证输出边界、长度、引用来源与持久化。
- 所有工具说明和 schema 必须以当前注册 executor 为准；Office 深层模型编辑、完整前端、PDF、文件转换等完成后再次逐项复核，不保留此次基础能力限制作为最终产品目标。
- 最终签名指南、实际运行注入、真实模型对照指标和全部发布验收未齐全，H01–H06 保持未勾选。不要把“已扫过源文件”写成“全部提示词已验收”。

Office 1.2.1 的目录最低应用版本设为 1.5.4：旧版 1.5.3 的 inspect 没有返回工具级 sha256，不能给旧版推送依赖该返回值的新指南。当前分支仍未进行应用版本递增；正式发布版本须至少满足此门槛。
