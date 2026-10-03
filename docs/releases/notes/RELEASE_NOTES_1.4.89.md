## Floe Agent 1.4.89 (Build 120)

### 简体中文

- 新增“技能 → 连接器”，集中管理 GitHub、通用邮箱和 MCP；GitHub 与 MCP 现有凭据存储保持不变。
- 通用邮箱支持 IMAP/POP3 收信与 SMTP 发信，默认 IMAP + SMTP。支持分页、MIME 附件、IMAP 已读状态及附件保存；仅在证书验证通过的 TLS/STARTTLS 连接上认证。密码仅存本机 Keychain，不引入 Google/Microsoft OAuth 注册。
- SMTP 使用持久发送回执和请求 ID 防止重复发信。提交后的连接中断明确显示“投递状态未知”，不会自动重发；邮箱配置或凭据保存失败保留原配置并回滚新增凭据。
- VNC 点击、拖动、键盘及滚动操作直接返回可复用截图和 OCR 结果；区分输入排队与实际视觉结果，避免模型无意义地重复观察。凭据输入不自动截屏。
- 画布修改返回准确的节点/连线增量及 revision，扩大端口拖线范围并清理中断手势；已验证正常的 PiP 实现不作重构。
- 修复自动审批中的活动模型路由刷新、继续任务后用户授权上下文丢失及文本编辑重复确认；敏感操作和手动审批模式仍保留原有安全边界。
- 补齐技能查询、指令更新、启停及可恢复删除。哈希校验拒绝覆盖旧版本；更新保留脚本、清单及权限，数据库保存失败会回滚安装包。
- 新增 SSH 持久任务取消。远端任务自身处理取消请求，避免误杀复用 PID；已完成结果不被覆盖，“已请求取消”与“已确认取消”分开报告。远端助手更新为 1.4.3。
- 补齐浏览器标签页操作、任务隔离的 TCP 会话清单，修复浏览器结构化结果被截断的问题；新增协议、存储冲突、真实子进程取消及 iPad 应用回归测试。

这是内部测试版本，不开放外部公开 Beta。先完成自动测试、CI、签名上传，再分别核验 Apple VALID 与 Floe QA 可见性；真实邮箱收发、实体 iPad 上的 VNC/画布交互及长跑稳定性在安装此包后验收。自动测试不代表真实邮件已投递或远端点击已生效。仅允许 OAuth 的邮箱不受当前密码/应用专用密码连接器支持。

### English

- Add Skills → Connectors for GitHub, generic mail and MCP, preserving existing GitHub/MCP credential storage.
- Support IMAP/POP3 receiving and SMTP sending, defaulting to IMAP + SMTP. Include pagination, MIME attachments, IMAP read-state updates and attachment downloads. Authenticate only over certificate-validated TLS/STARTTLS. Credentials stay in device-local Keychain; no Google/Microsoft OAuth registration is included.
- Use durable SMTP receipts and request IDs to prevent duplicate sends. Connection loss after submission is reported as delivery unknown, never automatically retried. Failed configuration or credential writes preserve the previous account and roll back newly stored credentials.
- Return reusable screenshots and OCR from VNC pointer, keyboard and scroll actions. Distinguish queued input from visual evidence and avoid unnecessary observe calls. Credential entry deliberately omits automatic screenshots.
- Return exact Canvas node/edge deltas and revisions; expand connection-port drag targeting and clean up interrupted gestures. Keep the user-verified PiP implementation unchanged.
- Fix active approval-model refresh, preservation of user authority on continuation, and repeated UTF-8 editing confirmations. Sensitive actions and explicit human-approval mode retain their safeguards.
- Add skill listing/detail, instruction updates, enable/disable and recoverable removal. Digest checks reject stale edits; updates preserve scripts, manifests and grants, with package rollback on persistence failure.
- Add durable SSH task cancellation handled by the owning runner rather than persisted PIDs. Preserve completed results and distinguish cancellation requested from confirmed termination. Update the remote helper to 1.4.3.
- Complete browser tab actions and run-scoped TCP session inventory; preserve valid structured browser responses. Add protocol, storage-conflict, real subprocess cancellation and iPad app regression tests.

Internal testing only; no public beta distribution. Automated tests and CI precede signed upload, followed by separate Apple VALID and Floe QA visibility checks. Real mailbox delivery, physical-iPad VNC/Canvas interaction and sustained stability are verified after installing this build. Automated results are not proof of real delivery or remote input effects. OAuth-only mail providers are not supported by this password/app-password connector.
