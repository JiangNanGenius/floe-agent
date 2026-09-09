# 内部提示词审查（本轮持续更新）

本审查属于完整升级的 H01–H06，尚未完成。只以实际组装与模型运行结果判断效率，不把缩短字数等同于效果提升。

## 第六轮：长目标的后续步骤

发现 Goal 注入按原始顺序只取前 12 步；当这些步骤已完成时，后续待办只能看到下一项标题，缺少该项行动细节。现改为从未完成步骤中取接下来 12 项，并显示完成、跳过、未完成、总计及当前展示数量，明确细节是摘要、未显示步骤仍属于目标。云端与本地组装都使用同一投影。35 项规划/目标/上下文回归通过，新场景覆盖前 20 步已完成、1 步跳过、仍有 15 步待执行，保证第 22 步开始的具体行动进入请求。

这不是完整 Goal 运行或模型效率验收；已接受计划的较长正文、实际模型执行、最终全部能力及指南仍须按 H01–H06 复核。Office 原生前端的编译进展也不改变现有模型编辑工具的参数能力，不把前端可操作内容写成模型工具已支持。

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

[验证摘要](evidence/workflow-upgrade-20260909/prompt-audit-tests-summary.txt)：107 项 Swift 测试通过，另有 4 项官方元数据构建测试。iPad 应用实际首次安装指南、读取并与注册工具交叉核对的单项测试通过（`/tmp/floe-prompt-guide-registry.xcresult`）；生成新指南后已在 `/tmp/floe-prompt-signed-registry.xcresult` 再验通过。

保留了 5 个真实请求组装路径的**合成输入**捕获：[普通](evidence/workflow-upgrade-20260909/prompt-snapshots/chat.json)、[计划](evidence/workflow-upgrade-20260909/prompt-snapshots/plan.json)、[Goal 模式](evidence/workflow-upgrade-20260909/prompt-snapshots/goal.json)、[模型无工具能力](evidence/workflow-upgrade-20260909/prompt-snapshots/model-without-tools.json)、[用户关闭工具](evidence/workflow-upgrade-20260909/prompt-snapshots/tools-disabled.json)。记录系统消息、工具名、字符数和 UTF-8 长度，不含凭据；未调用真实模型，字符数不能冒充实际 token 或缓存收益。Goal 样本只验证模式和工具层，不代表完整持久 Goal/恢复样本。

## 仍须完成的最终审查

- 本地系统层、当前输入和目录来源问题已按下面第四轮修复；仍须真机验证不同本地模型的实际容量、工具成功率和恢复旧检查点。非 Apple 路径保留严格 JSON tool_call 兼容回退，解析和能力边界已有回归，但没有真实模型完整效率对照。
- `ContextEngine`、`ConversationHistoryAssembler`、手动压缩、恢复/重试/最终校验插入层：当前已有连续性测试，仍需覆盖长任务实际最终请求与全部分支的重复指令。
- `ConversationCenter` 的图像转述、Goal 证据判断、标题生成；画布墨迹/视觉辅助/生成上下文；记忆整理/MemoryDream/SkillDream 辅助请求：已定位并阅读相关来源，仍需固定合成任务验证输出边界、长度、引用来源与持久化。
- 所有工具说明和 schema 必须以当前注册 executor 为准；Office 深层模型编辑、完整前端、PDF、文件转换等完成后再次逐项复核，不保留此次基础能力限制作为最终产品目标。
- 本次指南签名及应用安装检查已通过；最终功能版本的实际运行注入、真实模型对照指标和全部发布验收仍未齐全，H01–H06 保持未勾选。不要把“已扫过源文件”写成“全部提示词已验收”。

Office 1.2.1 的目录最低应用版本设为 1.5.4：旧版 1.5.3 的 inspect 没有返回工具级 sha256，不能给旧版推送依赖该返回值的新指南。当前分支仍未进行应用版本递增；正式发布版本须至少满足此门槛。

指南签名生成任务 [34280433826](https://github.com/JiangNanGenius/floe-agent/actions/runs/34280433826) 成功，最低应用版本调整后的再次签名 [34280703973](https://github.com/JiangNanGenius/floe-agent/actions/runs/34280703973) 也成功。生成后 26 项真实 ZIP/签名/包边界测试及 1 项应用注册测试通过，见 [签名后验收](evidence/workflow-upgrade-20260909/signed-guide-tests-summary.txt)。本地 Python 3.12 缺少 cryptography，未将该本地 build.py --check 失败计为通过；云端生成和 --check、Swift 加密验证分别有成功证据。

## 第三轮：介绍实际参与发现、完整目录与版本说明

发现此前 `skill.search` 只搜索 ID/名称及内置别名，没有使用各 SKILL.md 的 description，第三方指南因此可能无法按用途找到。现复用安装校验的元数据解析器，从持久安装内容取得介绍；列表和搜索返回介绍，按名称/介绍关键词检索并补齐 PPT 别名。精确读取仍使用任务固定版本的介绍，目录显示当前安装版本；两者不是同一个修订时不混用。

发现接口统一剥离正文与正文分页字段，不激活指南。列表按编码后的实际大小缩短页并返回游标；搜索结果超过预算时明确要求缩小查询，避免框架截断 JSON。未匹配搜索不再塞入整个无界安装目录，统一指向 skill.list。`skill.manage` 说明明确使用 currentDigest 或当前目录 digest，避免把运行时固定的旧 digest 用作修改基准。

[39 项 Skill 回归及 1 项应用安装/目录测试](evidence/workflow-upgrade-20260909/skill-description-tests-summary.txt)通过，包括第三方用途、多独立查询、大小写/重音、禁用状态、正文不泄漏、旧数据解码以及 100 项带大量 JSON 转义的分页完整性。这是关键词和数据合同验证；未证明任意自然语言语义召回率或真实模型效率，最终 H01–H06 仍待完整验收。

## 第四轮：本地模型实际请求链路

已确认旧本地适配器完全忽略系统消息，丢失运行模式、工作区、计划/Goal 状态、恢复控制、实时日期及辅助任务的输出格式要求。MLX 转录还会把当前用户消息裁剪到约 800 字符，保留首尾并省略中段；长输入中的修改要求和资料因此可能不可见。待处理工具回执与转录共用预算，长输入可能挤掉回执。工具目录和调用说明则放在伪用户消息中。

本轮实现：

- `AgentPromptComposer` 在源头为本地生成较短的通用规则和当前模式；运行上下文、现有计划/Goal 投影、指南及记忆等动态层继续传递。普通启动和已准备任务启动都选择该路径。大型计划本来存在的摘要/步骤投影仍是有界的，未宣称这里已实现所有历史全文注入。
- `LocalProviderAdapter` 保留传入的全部系统消息，工具目录留在系统区；当前用户输入完整保留。旧历史仍按预算裁剪，工具回执使用独立预算。MLX 底层已有包含真实模板/schema 的分词容量检查；过长请求会明确失败，不以省略当前输入规避容量检查。超长文档按文件处理和整体压缩/恢复仍需继续验收。
- JSON 等辅助输出格式不再被“必须自然语言”覆盖；计划和待办被明确区分于私有推理。工具修复重试保留原系统规则。执行记录只有在当前实际提供合适工具时才提示调用。

[98 项相关回归及模拟器应用构建](evidence/workflow-upgrade-20260909/local-context-tests-summary.txt)通过。新增覆盖中段修正、两种消息格式、长输入后仍有工具回执、用户伪造目录不进入系统层、辅助格式/后续系统控制，以及运行服务到本地适配器的普通/已准备启动链路。后者首次测试未明确要求读文件，按需发现没有加载读文件工具，预期断言失败；改为明确文件读取任务后通过，没有把该失败记为产品功能通过。

保留 [普通本地启动](evidence/workflow-upgrade-20260909/prompt-snapshots/local-normal.json) 与 [已准备启动](evidence/workflow-upgrade-20260909/prompt-snapshots/local-prepared.json) 的合成输入捕获，覆盖实际运行服务、适配器时钟刷新和组装函数；不加载模型权重、不执行工具。字符数不是实际 token。旧版本检查点、大量历史/计划、不同上下文容量、真机耗时与完成率尚未验证，H01–H06 不勾选。

## 第五轮：记忆与 Skill 后台提取的输入和引用

发现 `MemoryDreamService` / `SkillDreamService` 会先读取整段聊天，再取最后 12/16 条；截取后的每条正文仍无界。记忆提取的每个候选还会被统一挂到第一条用户消息上，不能证明该候选实际来自那条消息。

现改为读取有界近期窗口；后台上下文用 JSON 编码的消息 ID、角色和片段，最多 16 条、每条 1,024 个 Unicode scalar，长文明确标记为首尾片段，中间不拼接。这个限制只用于后台提取，不裁剪正在执行的用户任务。工具正文不进入该提取输入；SQL 近期窗口仍可能加载其消息 parts，尚未据此宣称全部数据库读取成本已消除。

记忆候选须返回逐项的消息 ID 和精确原文引用；应用只接受实际提供的用户片段中的非空引用，拒绝助手消息、虚构 ID、省略的中段、跨片段拼接及过长引用。既有记忆比较最多 60 项；比较不完整时不能按模型的 activate 意见直接激活，缺少有效处理意见也转待审。空结果或已提交的有效候选才消耗提取周期，错误引用和保存失败可在后续重试。

两类系统提示明确区分待分析数据与指令，禁止把小说、引用、一次性授权和未经验证的助手说法变为长期事实或工作流程。Skill 候选仍默认禁用。引用校验只证明原文来源，不证明模型正确理解了事实；语义准确率、完整冲突召回与真实模型效率仍需固定任务验收。

新增 6 项片段/引用回归，加上既有 5 项记忆审核管线回归，共 11 项通过；应用构建与 1 项实际组装测试通过，见[验证记录](evidence/workflow-upgrade-20260909/dream-prompt-tests-summary.txt)。既有记忆读取失败时直接延后重试，不把失败伪装成空目录。最终版本所有提示词/指南、真实提取到持久化的完整验证仍未完成，H01–H06 不勾选。
