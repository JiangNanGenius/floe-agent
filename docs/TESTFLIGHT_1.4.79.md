# Floe Agent 1.4.79 (Build 110) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

This candidate closes the remaining atomicity and lifecycle gaps in four-output reference-image generation and system Picture in Picture. Build 110 is available only after CI reports a non-zero verified test count, App Store Connect reports a valid processed build, and the internal Floe QA group can see it.

## Focus areas

- **One reference to four durable relationships:** one four-image request publishes four independent result nodes and four typed `generatedFrom` edges. The reference keeps its typed `source` edge into the task. Completion rebases onto the latest Canvas revision and atomically repairs missing, stale, or duplicate generation edges before saving.
- **All-or-nothing batches:** provider under-production and over-production fail before any partial result is published. The completed four-result set, result group, metadata, and repaired connection topology are published through one Canvas patch and one project-file save.
- **Reference context survives round trips:** only explicitly selected or connected `source` ancestry becomes provider context. Reference bytes, source IDs, saved prompt context, and all four result IDs survive save, reload, inspection, and later generation.
- **Explicit source replacement:** omitting `sourceNodeIDs` inherits the task's existing source relationships, providing an array replaces them exactly, and `[]` clears them. The registered tool schema and runtime resolver now use the same contract.
- **Safe retries and cancellation:** editing or retrying a task supersedes every result from the old attempt. Retry preserves prior generated assets but detaches their old task relationships. Cancellation updates the task and all four results with one revision and clears stale error details.
- **Durable generated-asset ownership:** generated files receive a database reservation before Canvas publication. Success consumes that reservation as the node reference; failure releases it exactly once. Concurrent identical outputs share the canonical asset safely, and confirmed cloud deletion cannot race a newly committed Canvas reference.
- **Deterministic layout:** new generation tasks and result nodes use a fixed grid and a readable source → task → aligned-results flow without moving existing user content.
- **No foreground lookalike or automatic card:** Picture in Picture and screen-share preferences retire any stale continued-processing Live Activity. Only an explicit user-started conversation run while the aggregate app scene is foreground-active may request continued processing. Cold-launch restoration, scheduled work, Goal continuation, queued input, and all image/video generation jobs cannot create or prolong the top-right card; media uses its durable refresh/processing/download recovery instead. The system request uses fail-instead-of-queue semantics so a stale card cannot appear later.
- **System PiP lifecycle:** AVKit preparation is kept alive across the inactive/background transition, late start callbacks are retracted on foreground return, and an early background transition is reported as not armed instead of claiming PiP is active. A preparation retry never starts PiP asynchronously after the user's tap.
- **Plan recovery stays planning:** every new run persists its immutable `chat` / `plan` / `goal` contract. A missing checkpoint cannot downgrade a known plan run into agent execution; conflicting or untrusted legacy evidence stops recovery before model or tool execution.
- **VNC prerequisite chain:** observation and input remain active-session-only and fail closed while disconnected. The connect tool has a dedicated connection action, and runtime guidance enforces status → connect → observe/input without passing credentials through model-visible arguments.
- **Harness terminal parsing:** long reasoning containing JSON, code fences, or symbolic tool-like text remains reasoning data and cannot be mistaken for a tool lifecycle or terminal state.
- **Stable Canvas Assistant timeline:** the final answer stays immediately above the localized terminal row, private post-answer verification reasoning stays hidden, stale animation tails cannot displace persisted terminal events, and raw `endTurn` is rendered as that localized terminal state.
- **Executed-test release gate:** CI and release workflows run the Canvas, Canvas-tool, PiP, and timeline suites and reject zero-test or partial-pass results.

## Physical-iPad acceptance boundary

Automated tests can prove the state and persistence contracts, but the iOS Simulator cannot prove that iPadOS presents and retains the real system PiP window. On a physical iPad, choose System Picture in Picture, wait until the task toolbar reports that PiP is ready, confirm Floe has no independent top-right card while foregrounded, then use Home or app switching and confirm the system PiP window appears and updates. Returning to Floe must retract it. Force-quitting Floe is not a supported PiP continuation path.

Also generate four images from one connected reference, save and reopen the Canvas, then confirm one `source` edge, four `generatedFrom` edges, four aligned independent result nodes, and usable reference context for the next explicit generation.

## 简体中文

本候选版收口“参考图生成四张”和系统画中画剩余的原子性与生命周期问题。只有 CI 确认实际执行了非零测试、App Store Connect 显示构建已有效处理，并且内部 Floe QA 测试组可见 Build 110 后，才算真正可用。

- **一张参考图对应四条持久关系：**一次四图请求会发布四个独立结果节点和四条 `generatedFrom` 类型连线；参考图保留一条进入任务的 `source` 连线。完成时会基于画布最新 revision 原子补齐缺失关系并移除过期或重复关系。
- **整批成功或整批失败：**服务商少返或多返图片都会在发布部分结果前失败。完整的四个结果、结果分组、元数据与修复后的连接拓扑通过一次画布 patch 和一次项目文件保存共同生效。
- **参考上下文可往返恢复：**只有明确选择或通过 `source` 连接的上游节点进入供应商上下文。参考图数据、来源 ID、相关提示词和四个结果 ID 在保存、重开、检查及后续显式生成时都能恢复。
- **显式来源采用替换语义：**省略 `sourceNodeIDs` 才继承任务已有来源关系；传入数组会精确替换来源，传入 `[]` 会清空来源。工具注册 schema 与运行时解析器现在遵守同一合同。
- **安全重试与取消：**编辑或重试会让旧 attempt 的全部结果失效。旧产物仍保留，但旧任务关系会断开；取消会在一个 revision 中同步更新任务与四个结果，并清除旧错误详情。
- **生成素材先占位：**文件在发布到画布前先建立数据库引用占位；成功时占位转为节点引用，失败时精确释放一次。并发生成相同内容会安全复用 canonical 素材，Cloud 删除确认也不能抢先删掉刚提交到画布的文件。
- **固定整齐布局：**新任务与结果按固定网格形成“来源 → 任务 → 对齐结果”的清楚流程，不移动用户已有内容。
- **前台和自动任务不再出现伪画中画：**选择画中画或屏幕共享后会结束旧的 continued-processing Live Activity。只有应用整体处于前台、且用户显式发起的会话任务才可申请 continued processing；冷启动恢复、定时任务、Goal 续跑、排队输入以及全部图片/视频生成任务都不能创建或延长右上角卡片，媒体任务改用已有的持久 refresh/processing/download 恢复链。系统请求采用失败而非排队策略，避免卡片延迟弹出。
- **真实系统 PiP 生命周期：**AVKit 准备状态会跨过 inactive/background 切换；晚到的启动回调若已回到前台会立即收回；若离开 App 时尚未准备完成，会诚实显示未就绪，而不是伪称已启动。准备重试不会在用户点击结束很久后异步启动窗口。
- **计划恢复仍是计划：**每个新 run 都持久保存不可变的 `chat` / `plan` / `goal` 合同。计划任务即使 checkpoint 丢失也不会降级为 Agent 执行；旧数据证据缺失或冲突时，会在模型与工具执行前停止恢复。
- **VNC 前置链固定：**观察和输入只接受已连接会话，断连时关闭；连接工具使用独立建连动作，运行时固定遵守 status → connect → observe/input，密码等凭据不经过模型可见参数。
- **Harness 终态解析收紧：**长思考中的 JSON、代码块和类似工具调用的符号仍只按思考内容处理，不能误判为工具生命周期或任务终态。
- **画布助手时间线稳定：**最终答复固定在本地化终态行正上方，答复后的私有校验思考不显示，陈旧动画尾部不能覆盖持久终态，原始 `endTurn` 只显示为该本地化终态。
- **真实测试门禁：**CI 与发布流程覆盖画布、画布工具、PiP 与时间线测试，并拒绝零测试和部分通过结果。

## 实体 iPad 验收边界

自动化测试可以证明状态与持久化合同，但模拟器不能证明 iPadOS 确实显示并保持系统 PiP。请在实体 iPad 选择“系统画中画”，等待任务工具栏显示画中画已就绪，确认 Floe 在前台没有独立右上角卡片，再通过 Home 或切换 App 离开 Floe，确认系统 PiP 窗口出现并更新；返回 Floe 后它必须收回。强制结束 Floe 不属于 PiP 可继续运行的范围。

另请用一张已连接的参考图生成四张，保存并重开画布，确认一条 `source` 连线、四条 `generatedFrom` 连线、四个排列整齐的独立结果节点，以及可用于下一次显式生成的参考上下文。

反馈请注明 Build 110、设备和系统版本、模型与供应商、画布/任务 ID、准确操作与时间。不要上传 API Key、Token、密码、SSH 私钥、证书或描述文件。
