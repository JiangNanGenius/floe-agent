# v1.4.88 stability candidate / 稳定性候选版

## Scope / 范围

- Executable runner registry is authoritative; deferred `tools.search` loads relevant groups, including the complete VNC lifecycle. No legacy Canvas aliases remain.
- 工具以可执行注册表为准，按任务检索并加载完整工具组；不保留旧 Canvas 工具别名。
- General auxiliary LLM routes text-only background work independently of vision, image, video and approval models. Preference changes validate only changed routes.
- 通用辅助 LLM 专用于文本辅助任务；视觉、图片、视频和审批独立。保存设置只校验改动的路由。
- UTF-8 append/exact replacement, device DNS/TCP, explicit remote ICMP/traceroute, and opt-in LAN HTTP retain conflict and network-target checks.
- 增加 UTF-8 追加/精确替换、本机 DNS/TCP、明确的远端 ping/traceroute、按需内网 HTTP，保留冲突与网络目标校验。
- PiP source is attached to the root scene rather than transient toolbar content; MetricKit reports and process markers complement bounded streaming/logging.
- PiP 来源常驻根场景，不再依赖工具栏的条件渲染；增加系统诊断证据和流式显示/日志限流。

## Existing behavior retained and regression-gated / 保留并回归验证

Explicit Canvas input/output edges, model reference caps, revision snapshots, deterministic layout, connector gestures, timeline ordering, plan-mode read-only boundaries, VNC recovery fingerprints, checkpoint pairing and no side-effect replay remain covered by existing tests. Their presence in source is not physical-device acceptance.

现有显式输入输出连线、模型参考图上限、revision 快照、布局、端口手势、时间线、计划只读边界、VNC 失败指纹、检查点配对与副作用防重放继续走回归测试。源码实现不等于真机通过。

## Evidence / 证据

- Local SwiftPM passed 862 tests plus 12 isolated JavaScript engine and 12 isolated JavaScript tool tests (886 total). Coverage includes deferred discovery-to-execution, file edits/conflicts, provider time context, model persistence/sync, VNC protocol/contracts, HTTP and Harness recovery.
- 本地 SwiftPM 通过 862 项主回归、12 项独立 JavaScript 引擎测试和 12 项独立 JavaScript 工具测试（共 886 项），覆盖工具发现到执行、文本编辑与冲突、时间上下文、模型持久化/同步、VNC 协议契约、HTTP 和 Harness 恢复。
- Cloud CI and release gates remain pending for the final release commit; the earlier candidate passed iPhone/iPad builds and focused app regressions. This is not a final-release or physical-device acceptance claim.
- 最终发布提交仍需云端 CI 与发布回执；此前候选提交已通过 iPhone/iPad 编译和应用定向回归，但不代表最终版本或实体设备已经验收。
- GitHub OAuth app logo uploaded and GitHub confirmed it was updated; Device Flow remains enabled.
- GitHub OAuth 应用图标已上传且收到保存确认；Device Flow 保持启用。

## Release boundary / 发布边界

Internal TestFlight only. Require passing CI, immutable tag, signed upload receipt, Apple `VALID` processing, and Floe QA group visibility separately. Ordinary-chat PiP, VNC screenshot/click coordinates, four-reference Canvas relations and long-run crash stability require a physical iPad. No external beta before that acceptance.

仅内部 TestFlight。CI、不可变标签、签名上传回执、Apple `VALID` 和 Floe QA 可见性分别核验。普通对话 PiP、VNC 点击坐标、四参考图关系及长跑稳定性必须真机验收；之前不开外部 Beta。

## Reference decisions / 官方依据

- [Apple custom PiP lifecycle](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)
- [Apple MetricKit subscriber](https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber)
- [Codex tool-search implementation](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/tool_search_spec.rs)
- [Anthropic deferred tool discovery](https://www.anthropic.com/engineering/advanced-tool-use)
