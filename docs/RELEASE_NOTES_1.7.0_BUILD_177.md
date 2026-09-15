# Floe Agent 1.7.0 (177) — candidate

Build 177 is being qualified. It has **not** been uploaded or made installable in
TestFlight. Build 172 remains the latest confirmed internal delivery. This record
will be updated with the immutable source, upload and Apple availability evidence.

## 简体中文

- 保留前一候选版的运行环境、包管理、手记助手隔离与实时刷新修复。
- Soul 与用户画像更新后，正在运行的任务在下一次模型请求时读取已激活的新内容；草稿不自动进入上下文，重试保持原请求。
- 工作区增加 IDE 全屏编辑入口及并发保存冲突处理；网页编辑器与图纸查看器跟随 Floe 的语言选择。
- DXF/DWG 提供基础图元编辑、保存、撤销和冲突保护；STEP、IGES、BREP 提供只读网格预览。复杂图纸和各格式的限制见兼容说明。
- 文件管理器中的图纸可以直接发起 AI 审图，不要求预先选中聊天；只有用户填写问题并发送后才创建审图任务。输入包括实际视口截图和有界图纸信息。
- 修复 IDE 入口测试标识，统一界面测试语言；手记正文搜索通过打开真实匹配文档验证，而非依赖 iPad 隐藏键盘的过期坐标。

## English

- Retains the preceding runtime, package, dedicated Notes assistant and live document refresh fixes.
- Active Soul/profile changes are read at the next model request. Drafts stay out of context and retries retain the original request.
- Workspace files open in the full-screen IDE with conflict-aware saving. Embedded editors and drawing viewers follow Floe's language selection.
- Basic DXF/DWG entity editing, undo, durable saving and conflict protection; read-only STEP/IGES/BREP mesh previews. Format limitations remain documented.
- Drawing review can start directly from files without an existing selected chat. A task is created only when the user sends a question, using a real viewport image and bounded drawing metadata.
- UI qualification now identifies the actual IDE control and verifies body-search results by opening the matched document.

## Evidence and remaining work

Source `4eb99f620fe329b67cd2d89f9af51f639f4b2e74`, cloud run
[34976384189](https://github.com/JiangNanGenius/floe-agent/actions/runs/34976384189),
passed the accepted-SDK build, Linux compilation and full-App core regressions.
Its UI phase failed: CAD controls were in English while the test expected Chinese;
the IDE entry lacked the queried identifier; a hidden iPad keyboard retained stale
accessibility geometry despite the captured search result being visible. The
original logs, screenshots and recordings are retained. The fixes in this candidate
must pass fresh cloud checks; earlier results are not attributed to Build 177.

RDP native Apple archives compile and link. A separate Linux real-connection test
passes frame/input/cancellation checks. **RDP App integration is still incomplete**
and no RDP tools are advertised. See [RDP status](FLOE_RDP.md).

Native Office remains device-only; simulator Notes tests do not verify its engine.
Qwen iPad acceptance, the complete native npm/WASI/APT catalog, media-model acceptance
and log-service deployment are not automatically completed by this candidate.
See [repair execution record](FLOE_172_REPAIR_EXECUTION.md) and
[engineering viewer matrix](FLOE_ENGINEERING_VIEWERS.md).

Public Beta review is not submitted automatically. No paid provider key is included
in review materials. The existing real Agent demonstration is explicitly labelled
Build 175 and is not a recording of this candidate.
