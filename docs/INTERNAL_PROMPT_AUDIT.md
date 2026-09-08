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
