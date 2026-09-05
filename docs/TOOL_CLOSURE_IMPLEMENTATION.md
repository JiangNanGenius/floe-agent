# 工具闭环实施清单 / Tool closure implementation checklist

Accepted scope: VNC post-action evidence, complete Canvas interaction loop,
Skills → Connectors (GitHub, mail, MCP), and all capability gaps in the user's
screenshots. One internal release only after completion; no public Beta.

## Delivery gates

- [ ] VNC ordered input, bounded refreshed observation, OCR, reusable evidence,
  partial success, cancellation release, and provider image delivery.
- [ ] Canvas exclusive gestures, multi-select/undo, explicit reference graph,
  deterministic new-node layout and actionable post-operation results.
- [ ] Skills connector category; move GitHub and MCP without credential loss.
- [ ] Official Gmail/Microsoft OAuth and TLS IMAP/SMTP; real mail/attachment tests.
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

Official mail OAuth registrations and any provider verification require the
account owner's participation where the provider requests it. No dummy client
IDs, fake mail success, simulated BLE/device results, or blanket "complete" claims.
Keep the user-verified PiP implementation unchanged except proven regressions.

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
  credentials. Mail remains unimplemented, pending the full connector work.
  / GitHub 与 MCP 入口移入“技能 → 连接器”，凭据存储不变；邮件功能尚未完成。
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

- Complete SwiftPM run: 901 tests across 18 test products passed.
  / 完整 SwiftPM 测试：18 个测试产品，共 901 项通过。
- Final-source iPad Simulator regression: 85 tests in six suites passed,
  zero failures and zero skipped tests; result-bundle minimum-count checks passed.
  / 最终源码 iPad 模拟器回归：6 组共 85 项通过，无失败、无跳过，结果包最低执行数量检查通过。
- VNC wire tests use an actual loopback RFB peer and verify queued coordinates,
  frame evidence and cancellation button release. They are not physical-device
  or remote desktop acceptance.
  / VNC 线协议测试使用本机 RFB 对端验证坐标、画面证据和取消后的按键释放，不替代真机或远程桌面验收。

These counts do not prove full-plan completion, real iPad interaction, mail OAuth
or release readiness. Cloud SDK builds, physical QA and the unified internal
release gates remain pending. The existing PiP implementation was not modified.
/ 上述通过项不代表整体计划完成。邮件连接器、云端 SDK 构建、真机验收及统一内部发布门仍未完成；本轮未修改已修好的画中画实现。
