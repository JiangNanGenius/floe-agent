# Floe Agent 1.7.0 — Build 238

## 简体中文

本轮继续修复 Build237 真机反馈。

- Linux：清单未声明运行器版本时不再误报“过旧”；保存 Delta 使用有界复用缓冲区并校验短读，对明确暂时性错误有限重试。用户与模型提供共用租约保护的环境修复入口，保留隔离数据和原基础镜像。
- Office：重建原生宿主，修复消息转发的负长度、连接终止、重复启动及清理缺陷。新产物全部 4,780 个资源已核验。保留用户已确认正常的中文字体资源。
- 本地模型：精选搜索请求要求有效工具调用，错误 JSON 通过有限纠正流程处理，不直接执行正文中的代码样例。停止后的持久化状态不再被暂时活动状态覆盖；共用取消逻辑等待状态保存完成，云端工具范围不变。

验证：440 项执行模块 XCTest、6 项实际状态策略断言、20 项原生转发回归场景、8 项源码校验及 13 项产物固定检查通过。模型受控测试覆盖两次工具调用与回执、停止状态和云端正常完成；这些不是实际权重或 iPad 验收。

已知限制：PPT 编辑闪退仍缺匹配系统栈，修复已证实的转发缺陷不等于确认所有闪退已解决。本地模型真实权重搜索回答准确性仍待验收。Linux 下载、恢复和启动需真机复测；软重启仍未提供，旧环境不会自动替换基础镜像。Gitee 镜像资源同步及匿名下载验证独立进行，不将尚未验证的链接作为可用下载源。

请重点测试：Linux 首次下载及状态刷新、原环境修复、连续两轮联网搜索、停止后继续、PPT 从预览进入编辑并静置、修改保存重开。

## English

This internal beta addresses Build237 device feedback.

- Linux no longer treats a missing runner declaration as proof of an outdated image. Delta capture uses bounded reusable buffers, strict short-read checks and limited retries for typed transient errors. User and model repair entry points share lease protection and preserve quarantined data and the original base image.
- Office has a rebuilt native host addressing negative socket lengths, terminal events, duplicate forwarders and descriptor cleanup. All 4,780 resources were verified. Chinese font resources already reported working by the user are unchanged.
- Curated local search requests require a valid tool invocation, with bounded correction for malformed output; code samples in prose are not executed directly. Persisted stop state takes precedence over transient activity, and shared cancellation waits for terminal persistence. Cloud tool discovery remains unchanged.

Verification includes 440 execution-module XCTest cases, six compiled status-policy assertions, 20 native forwarding cases, eight source checks and thirteen artifact pin checks. Controlled model checks cover two tool calls with receipts, stopping and ordinary cloud completion; they are not real-weight or iPad acceptance.

Known limitations: the PPT edit crash still lacks a matching system stack. Fixing demonstrated forwarding defects does not prove that every termination is resolved. Real-weight local search-answer grounding remains unverified. Linux download, repair and boot need device retesting. Soft reboot remains unavailable and existing environments do not automatically replace their base image. Gitee asset synchronization and anonymous verification remain separate; unverified links are not advertised as working mirrors.

Please test first-time Linux download and status refresh, environment repair, two consecutive web searches, stop/resume, and PPT preview-to-edit followed by idle time, editing, save and reopen.
