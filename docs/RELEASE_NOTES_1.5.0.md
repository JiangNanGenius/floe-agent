## Floe Agent 1.5.0 (Build 131)

### 简体中文

- 新增原生 `skill.search`，支持中英文领域关键词，明确区分查找工作流与加载工具定义。工具描述匹配只返回相关工具，不再因为一个词命中而载入整个无关工具组。
- 移除整项任务累计流事件数的硬截断。内存保护按单次模型响应计算；仍保留无进展循环检测、用户预算、取消和恢复边界。
- 补齐 DeepSeek 历史消息与检查点中的推理协议字段。旧版本未保存的推理不伪造，旧助手文本明确作为非授权的历史参考传入。
- `/compact` 在任务空闲时立即执行，显示处理结果并持久化摘要，不删除原始会话和工具记录。压缩后明确通知模型上下文已压缩、沿用最新用户更正、继续未完成任务，不重复已完成操作。
- Goal 使用实际模型请求事件计数；工具和技能搜索不作为任务完成证据，取得新证据后重置重复阻塞计数。
- 优化审批对“例如、等”等非穷举测试范围的理解；不放开无关目标、破坏性操作、秘密访问、付款或发布权限。
- 增加完整任务 JSONL 导出，包含持久化消息、消息分段、工具调用/结果事件、用量、错误和事件水位。敏感字段脱敏；原先未保存或已截断的原始输出无法补造，产物以引用表示。
- 侧边栏和任务列表增加失败、挂起、等待审批、无进展及预算暂停提示。压缩和续跑状态增加轻量过渡，并遵循“减少动态效果”。
- 发布流程可复用同一提交已成功的可信 CI 回归证据，保留稳定 App Store SDK、实际二进制和签名上传检查。

内部 TestFlight 已发布：2026-09-08 确认 Apple `VALID`，且仅 Floe QA 内部组可见，无公开链接或外部测试组。保留已经真机确认的 VNC 与 PiP 实现；本版本的实体 iPad 长任务、搜索、压缩、状态提示和导出体验仍待验收，不开放外部 Beta。

- [CI 全部通过](https://github.com/JiangNanGenius/floe-agent/actions/runs/34160050948)；[签名上传成功](https://github.com/JiangNanGenius/floe-agent/actions/runs/34187111578)。
- [Apple VALID 与内部组验证](https://github.com/JiangNanGenius/floe-agent/actions/runs/34193665453)：1.5.0 / 131，仅 1 个 Floe QA 内部组。
- GitHub 附带的 IPA 是未签名审计产物，不能直接安装；请通过 TestFlight 安装。

### English

- Added native `skill.search` with bilingual domain matching and explicit workflow-versus-tool discovery. Description-only matches return relevant tools rather than entire unrelated groups.
- Removed the cumulative per-task stream-event cutoff. Memory protection applies per model response; no-progress detection, user budgets, cancellation and recovery boundaries remain.
- Preserve DeepSeek reasoning protocol fields in assistant history and checkpoints. Missing legacy reasoning is never invented; legacy assistant text is explicitly non-authoritative historical context.
- `/compact` executes immediately while idle, reports its outcome and persists the summary without deleting original conversation or tool records. The model receives an explicit compaction notice, latest-correction precedence and instructions to continue without replaying completed work.
- Goal accounting uses actual model-request events. Tool/skill discovery is not completion evidence, and new evidence resets repeated-blocker tracking.
- Approval guidance recognizes non-exhaustive examples within the requested testing scope without authorizing unrelated targets, destructive operations, secrets, payments or publication.
- Added task JSONL export with persisted messages/parts, tool call/result events, usage, errors and event watermarks. Sensitive fields are redacted; missing or previously truncated raw output cannot be reconstructed and artifacts remain references.
- Sidebar and task-list indicators distinguish failure, interruption, approval waiting, no progress and budget pauses. Compaction and continuation use lightweight transitions respecting Reduce Motion.
- Releases can reuse successful trusted CI evidence for the exact same commit, retaining stable App Store SDK, binary, signing and upload gates.

Internal TestFlight delivery verified on 2026-09-08: Apple `VALID`, visible only to the internal Floe QA group, with no public link or external test group. Existing device-validated VNC and PiP implementations are preserved. Physical-iPad acceptance of this version's long runs, discovery, compaction, attention indicators and export UX remains open; external Beta is not enabled.

- [All CI gates passed](https://github.com/JiangNanGenius/floe-agent/actions/runs/34160050948); [signed upload succeeded](https://github.com/JiangNanGenius/floe-agent/actions/runs/34187111578).
- [Apple VALID and internal-group verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/34193665453): 1.5.0 / 131, exactly one internal Floe QA group.
- The IPA attached to GitHub is an unsigned audit artifact and cannot be installed directly. Install through TestFlight.
