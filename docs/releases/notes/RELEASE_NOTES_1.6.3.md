# Floe Agent 1.6.3

> 2026-09-11。本轮主线：按真实会话日志（floe-task-694DB10F）修复代理 harness 的摩擦点，并对标 OpenCode / Claude Code / Kimi Code 完成提示词与机制升级。
> English summary follows the Chinese section.

### 简体中文


## 任务清单生命周期（治"清单越用越乱"）

- **完成的清单自动完结**：全部步骤终态后，`task.readPlan` 明确提示清单已完结；下一次 `task.updatePlan` 提交全新 steps 即自动开启新清单，不再要求携带或取消旧步骤（历史完整保留在修订表）。
- **终态步骤可退役**：清单进行中时，更新只需携带未完成步骤 ID；已完成/已取消步骤可以省略，清单不再无限膨胀。
- **expectedRevision 改为可选**：省略即基于当前版本写入；显式提供且过期时才冲突，且报错自带当前版本号。校验报错逐条精确到步骤（哪个 inProgress 超编、哪步缺证据、哪些 ID 必须携带）。

## Harness 机制（对标三家成熟工具）

- **失败熔断器**：同一工具连续失败 3 次（即使参数不同）即拦截并注入强制纠错提示——要求重读 schema、按报错命名修正，而非继续猜测。
- **计划保鲜提醒**：新增 Reminder 服务（变体注册、按内容去重、冷却自控）：距上次成功更新清单 ≥8 次工具调用且仍有未完成步骤时提醒；清单完结时提示开新清单；长任务无清单时建议建立。注入为权威 `<system-reminder>`。
- **tools.search 标注**：已在上下文中的 schema 明示"无需重复加载"。
- **LLM 语义压缩**：云端模型压缩时由模型撰写语义续接摘要（保留目标/证据/未完成态），失败自动回落确定性摘要；本地模型保持确定性。设置项 `agent.semanticContextCompaction`，云端默认开。

## 提示词全面重写（参照 Kimi Code system.md 与 OpenCode）

- 新增 **Delivering work** 层：真实调用验证才许声称完成；未验证不得交付；遇卡点不得自行缩水；收尾前回读最新请求逐条核对。
- 新增 **沟通纪律** 层：匹配用户语言；工具间文本限一句状态；最终消息自包含。
- 新增 **Harness messages** 元协议：注入块为运行时权威指令，区别于用户输入与历史事实。
- 失败协议增补 **denial 纪律**：被拒绝不得原样重试或绕道。

## 子代理

- `delegate` 增加 `type`：`explore`（默认，纯本地只读）/ `research`（附加只读 web/network 证据）。
- 子代理系统提示词落地交接契约：父代理只见最终消息、最终总结自包含、不向终端用户提问。
- 子代理运行器无状态化：同批次多个 delegate 真正并行。

## 画中画（PiP）

- **真应用图标**替换手画占位块。
- **速度口径修复**：本地模型工具修复路径不再用"总耗时"（含 prompt 预填/回放工具输出）稀释速率，统一为 decode 段速率（按输出 token 加权）；字符/秒回退只计回答正文（不含推理流）；速率标注"模型"且仅在流式阶段显示。
- **状态详细化**：当前工具名、本 run 工具调用/失败计数、等待审批时显示待批工具名。

## 其他修复

- **jobs.submit 提交时校验**：目标工具参数在提交时即按 schema 校验，错误参数（如把 `script` 写成 `code`）当场报"missing required argument 'script'"，不再异步失败；全局 DecodingError 文案可读化，前台所有工具受益。
- **workspace.createFile** 增加 `overwrite` 参数；已存在错误指路 writeFile/overwrite=true。
- **exec.compatEvaluator** 描述明确变量绑定规则（`input` 仅在提供 inputJSON 时存在；变量不跨调用保留）。
- **工作区 root 漂移埋点**：同一会话解析出不同 root 时记录警告日志，为"文件写入后消失"类问题留证据。

## Python 预置二进制包

- **regex 2026.9.1x / PyYAML 6.0.3 / MarkupSafe 3.0.3** 完成产线闭环：CI 构建（iOS testbed 冒烟通过）→ 不可变 Release → install 脚本 SHA-256 pin。regex 为原生双 slice（XCFramework 化），另两包为纯 Python wheel。
- 探针清单扩展 zstandard/brotli/greenlet/frozenlist/multidict（候选构建进行中，下版本接入）。
- orjson/pydantic-core（Rust 链）仍为二期实验。

---

### English

## English Summary

Evidence-driven harness hardening from a real session log, benchmarked against OpenCode, Claude Code, and Kimi Code: task-checklist lifecycle (finished lists auto-close; terminal steps retire; optional CAS; precise per-step validation errors), a failure circuit breaker, a variant-based reminder service with plan-freshness nudges, LLM-written semantic compaction with deterministic fallback (cloud default on), a full system-prompt overhaul (delivery-verification contract, communication discipline, harness-message meta-protocol, denial discipline), typed parallel subagents with a self-contained handoff contract, PiP fixes (real app icon, decode-only speed metric, detailed tool/approval status), submit-time job argument validation with readable decoding errors, and the first three wheelhouse packages (regex/PyYAML/MarkupSafe) promoted through the full build→release→pin pipeline.
