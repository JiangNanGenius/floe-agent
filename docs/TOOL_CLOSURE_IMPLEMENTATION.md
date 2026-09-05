# 工具闭环实施清单 / Tool closure implementation checklist

Accepted scope: VNC post-action evidence, complete Canvas interaction loop,
Skills → Connectors (GitHub, mail, MCP), and capability gaps in the user's
screenshots. Ship the internal package after automated gates so device acceptance
can proceed; no public Beta. Unimplemented platform expansion items stay open below.

## Delivery gates

- [ ] VNC ordered input, bounded refreshed observation, OCR, reusable evidence,
  partial success, cancellation release, and provider image delivery.
- [ ] Canvas exclusive gestures, multi-select/undo, explicit reference graph,
  deterministic new-node layout and actionable post-operation results.
- [x] Skills connector category; move GitHub and MCP without changing credential storage.
- [ ] Generic mail connector: SMTP sending, IMAP receiving/synchronization and
  POP3 receiving over verified TLS; real mail/attachment tests. Default to
  IMAP + SMTP, with POP3 as an alternative. Google/Microsoft OAuth is out of scope.
- [ ] Skill CRUD and safe credential management; automation/cloud-Git contract audit.
- [ ] SSH task cancellation and remote-session inventory/status.
- [ ] Browser tabs, downloads, site data controls and explicit preview lifecycle.
- [ ] File ranges/binary access, safe downloads and ZIP/TAR/GZIP archive operations.
- [ ] Device network diagnostics with honest protocol/target reporting.
- [ ] Camera, Shortcuts, audio/STT/TTS, media conversion, QR, clipboard,
  notifications and AlarmKit lifecycle.
- [ ] BLE GATT lifecycle and document/image editing including genuine PDF redaction.
- [ ] System-library cryptography and explicit local/remote execution boundaries.
- [ ] Automatic approval: refresh active policies after model selection, preserve
  role-checked user authority across continue, and avoid repeated text-edit prompts.
- [ ] Actual unit/integration tests, cloud SDK builds, secret scan, physical QA.
- [ ] Bilingual notes, immutable release, upload receipt, Apple VALID, Floe QA visibility.

## External acceptance dependencies

Mail acceptance requires a test mailbox whose provider permits SMTP/IMAP/POP3 password
or app-password authentication. Do not request Google/Microsoft app registration
or brand verification. No fake mail success, simulated BLE/device results, or
blanket "complete" claims.
Keep the user-verified PiP implementation unchanged except proven regressions.

## Mail scope revision / 邮件范围调整

The user cancelled Google and Microsoft dedicated mail sign-in. Keep only a
generic SMTP/IMAP/POP3 connector under Skills → Connectors; no OAuth buttons,
embedded provider client IDs or OAuth dependencies in this scope.
/ 用户取消 Google 和 Microsoft 专用邮件登录。本轮仅保留“技能 → 连接器”中的
通用邮箱方案：SMTP 发信、IMAP 收信及同步、POP3 收信。默认 IMAP + SMTP，
可切换 POP3；不加入 OAuth 入口、服务商客户端 ID 或 OAuth 依赖。

- Configure incoming/outgoing server, port, TLS mode, username and a Keychain
  credential reference. Never send passwords to the model, logs or sync payloads.
- Require verified TLS before authentication; reject unsupported authentication
  with an actionable error, not repeated password prompts or TLS downgrade.
- POP3 retrieval leaves messages on the server by default. Do not silently delete
  messages after retrieval or pretend POP3 provides IMAP folder synchronization.
- IMAP supports folder listing, incremental message retrieval, attachments and
  read/unread state synchronization. Message moves/deletion and outbound mail
  remain explicit, approval-controlled mutations; do not expunge implicitly.
- SMTP supports attachments and verified implicit TLS/STARTTLS. IMAP and POP3
  also support verified implicit TLS or their protocol-specific TLS upgrade;
  never fall back to unencrypted authentication if negotiation fails.
- Exchange-specific protocols (EAS/EWS), JMAP and calendar/contact protocols are
  not implied by this generic mail scope; no unimplemented capability is advertised.
- Authentication compatibility is provider-specific. Outlook.com requires
  OAuth2/Modern Auth and is not promised as supported by this password-only
  connector. Gmail app passwords are subject to account eligibility and settings.
- Existing user-created cloud registrations are not deleted or modified.
- SMTP/IMAP/POP3 are implemented with protocol, actual TCP loopback and app tests.
  Real-account and physical-device acceptance remain pending; these tests are
  not evidence of mail delivery. See [Mail connector](MAIL_CONNECTOR.md).

/ 默认保留服务器上的邮件，凭据仅存 Keychain，认证前必须建立通过证书验证的加密
连接。服务商若只允许 OAuth，应明确提示不支持，不能反复索要密码。已注册的云端
应用不作删除或修改。SMTP/IMAP/POP3 已实现并通过自动测试，真实邮箱及实体设备验收尚未完成。

Provider references:
[Outlook.com authentication](https://support.microsoft.com/en-US/Outlook/pop-imap-and-smtp-settings-for-outlook-com),
[Google app passwords](https://support.google.com/mail/answer/185833).

## Audit facts (baseline 8c0a4fc)

- VNC actions already attach JPEG artifacts, but only observe refreshes OCR.
- VNC input methods call RoyalVNCKit without a transport receipt; dispatch is
  not server acknowledgement or visual success.
- Runtime can attach VNC artifacts to vision-capable provider requests.
- cloudWorkspace.gitBranch already creates/switches branches.
- apple.automation.update already creates/updates/deletes schedules.
- Browser command protocol already supports tab create/list/activate/close.
- Mail OAuth/IMAP/SMTP implementation is absent at baseline.

Items above remain unchecked until implementation AND corresponding verification.
The screenshot-derived platform expansion list is not a claim that every capability
ships in this internal build; only implemented items in the checkpoint/release notes
are advertised. Real mailbox/device tests happen after internal distribution.

## Internal release order correction / 内测发布顺序更正

User confirmation: ship internal TestFlight so physical acceptance is possible.
Automated tests → CI → signed upload → Apple VALID → Floe QA internal visibility
→ real mailbox and physical-iPad acceptance. The last step gates public Beta,
not the internal upload. / 用户确认：先交付内部 TestFlight 才能进行真机验收。
真实邮箱及设备测试不再阻挡内测上传，仍然阻挡外部公开 Beta。

- Skill list/detail, digest-protected instruction updates, enable/disable and
  recoverable removal are implemented; executable scripts/capabilities are not broadened.
  / 补齐技能查询、哈希保护的指令更新、启停及可恢复删除，不扩大脚本和权限。
- SSH cancellation uses runner-owned requests instead of persisted PID signalling;
  pending cancellation is distinct from confirmed termination and terminal results
  are preserved. / SSH 取消由任务自身处理，不按磁盘 PID 杀进程，不覆盖已有终态。

## Implementation checkpoint / 实施进度

- VNC click/drag/key/text/scroll now return reusable screenshot and OCR evidence;
  queued input is distinct from server acknowledgement and task success.
  Credential entry deliberately suppresses screenshots to prevent secret exposure.
  / VNC 操作直接返回可复用的截图与文字定位，区分输入排队、服务端确认和任务成功；凭据输入不自动截图。
- OCR is off the cooperative executor with a two-second deadline and a single
  in-flight worker; timeout does not discard a valid screenshot or queue more OCR.
  / 文字识别移出协作执行线程，限制两秒等待与单个在途任务，超时仍保留截图。
- Canvas mutations return an exact committed delta and revision; port gestures
  attach to the full target and clean up when interrupted.
  / 画布修改回传同一提交的节点、连线增量与版本；扩大端口拖线范围并清理中断状态。
- GitHub and MCP navigation moved under Skills → Connectors without migrating
  credentials. Generic mail has its own server/TLS settings and device-local
  Keychain storage; no provider OAuth registrations are included.
  / GitHub 与 MCP 入口移入“技能 → 连接器”，凭据存储不变；通用邮箱独立配置服务器和 TLS，凭据仅存本机 Keychain，不加入服务商 OAuth 注册。
- Mail exposes five paired executable tools through deferred group discovery.
  IMAP/POP3 pagination, MIME attachment integrity, IMAP flag readback and durable
  SMTP deduplication are covered by tests. Credential-write failure preserves the
  previous configuration and rolls back newly stored secrets.
  / 邮箱通过按需工具发现暴露五个声明/执行器成对工具；覆盖分页、MIME 附件、IMAP 状态读回及 SMTP 持久去重，凭据保存失败回滚并保留旧配置。
- Browser tab management and run-scoped TCP connection inventory have executable
  registrations. Browser replies are no longer truncated into invalid JSON.
  / 补齐浏览器标签页与任务隔离的 TCP 会话查询工具，浏览器回执不再被截断为无效 JSON。
- Approval fixes passed regression tests: active model-route refresh, role-checked user
  requests outside the tool transcript budget, and consistent UTF-8 edit policy.
  Read-only session metadata does not require repeated approval; sensitive actions
  and explicit human-approval mode retain their existing boundaries.
  / 自动审批修复已通过回归：刷新运行任务的模型路由、独立保留真实用户请求、统一文本编辑审批规则。
  只读会话元数据不再重复请求审批；敏感操作和手动审批模式保留原有边界。

## Validation checkpoint / 验证进度

- Complete SwiftPM run including mail: 924 tests across 18 test products passed.
  / 包含邮箱的完整 SwiftPM 测试：18 个测试产品，共 924 项通过。
- Final-source iPad Simulator regression: 90 tests in seven suites passed,
  zero failures and zero skipped tests; result-bundle minimum-count checks passed.
  / 最终源码 iPad 模拟器回归：7 组共 90 项通过，无失败、无跳过，结果包最低执行数量检查通过。
- Mail app credential rollback tests use an injected store. The unsigned simulator
  host returned Keychain entitlement error -34018; this is not recorded as a
  successful real Keychain test. Actual device Keychain acceptance remains open.
  / 邮箱应用凭据回滚测试使用注入存储；未签名模拟器的真实 Keychain 返回 -34018 权限错误，不将其算作真实 Keychain 验收通过。
- VNC wire tests use an actual loopback RFB peer and verify queued coordinates,
  frame evidence and cancellation button release. They are not physical-device
  or remote desktop acceptance.
  / VNC 线协议测试使用本机 RFB 对端验证坐标、画面证据和取消后的按键释放，不替代真机或远程桌面验收。

These counts do not prove full-plan completion, real iPad interaction, SMTP/IMAP/POP3 mail
or release readiness. Cloud SDK builds, physical QA and the unified internal
release gates remain pending. The existing PiP implementation was not modified.
/ 上述通过项不代表整体计划完成。真实邮箱、云端 SDK 构建、真机验收及统一内部发布门仍未完成；本轮未修改已修好的画中画实现。
