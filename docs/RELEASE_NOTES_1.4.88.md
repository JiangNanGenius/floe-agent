## Floe Agent 1.4.88 (Build 119)

### 简体中文

- 工具按任务加载：先提供相关工具组，其余通过 `tools.search` 检索。完整 VNC 生命周期保持可发现，连接前置条件由执行器检查；删除旧 Canvas 工具别名。
- 工具描述、参数与执行入口以运行时注册表为准，避免静态目录中“有声明、没执行器”的工具进入模型请求。
- 新增通用辅助 LLM 设置，记忆整理、长期记忆提炼、用户画像、SOUL、技能和自动标题跟随该路由；视觉、图片、视频与审批仍独立。
- 新增所有 UTF-8 文本扩展名通用的追加和精确替换；保留完整文件、并发哈希检查与二进制拒绝。
- DNS/TCP 默认可从设备运行；真实 ICMP ping/traceroute 使用明确指定的 SSH 主机。内网诊断可按需访问 HTTP，公网明文、凭据 URL 和元数据端点仍受限制。
- 普通对话和画布的 PiP 来源改为根场景常驻视图，不再依赖工具栏条件显示。前台不创建独立预览浮窗。
- 限制超长流式输出的动画积压，采样重复后台日志；加入 MetricKit 系统诊断与进程退出标记。
- 模型实际发送请求时刷新时间、IANA 时区、UTC 偏移和区域设置。辅助模型页面显示实际路由与保存失败状态；记忆整理入口及 GitHub 登录/高级令牌入口更清晰。

仅内部 TestFlight。CI、签名上传、Apple `VALID` 和 Floe QA 可见性分别核验。实体 iPad 上的普通对话 PiP、VNC 点击坐标、四参考图连线及长跑稳定性仍是外部公测前独立验收门。未获得系统崩溃报告前，不宣称已确定历史闪退根因。

### English

- Load task-relevant tool groups first and discover others through `tools.search`. The complete VNC lifecycle remains discoverable with execution-time prerequisites. Removed legacy Canvas tool aliases.
- Use the executable registry as the authority for descriptions, schemas and runners, preventing static-only declarations from entering model requests.
- Add a general auxiliary LLM route for memory, personalization, SOUL, skills and automatic titles. Vision, images, video and approval remain independently routed.
- Add extension-independent UTF-8 append and exact replacement with complete-file preservation, hash conflict checks and binary rejection.
- Run DNS/TCP on the device by default; use an explicitly selected SSH host for real ICMP ping/traceroute. Opt-in LAN diagnostics support HTTP while retaining restrictions on public plaintext, credential URLs and metadata endpoints.
- Keep the shared ordinary-chat/Canvas PiP source attached to the root scene rather than conditional toolbar content. Do not create a standalone foreground preview tile.
- Bound streaming animation debt, sample repetitive background logs, and retain MetricKit reports plus process-exit markers.
- Refresh time, IANA time zone, UTC offset and locale at model dispatch. Clarify actual auxiliary routes, failed-save status, memory organization and GitHub sign-in/PAT settings.

Internal TestFlight only. CI, signed upload, Apple `VALID` and Floe QA visibility are verified separately. Physical-iPad PiP, VNC click coordinates, four-reference graph relationships and sustained stability remain external-beta acceptance gates. Historical crash causes remain unconfirmed without system crash evidence.
