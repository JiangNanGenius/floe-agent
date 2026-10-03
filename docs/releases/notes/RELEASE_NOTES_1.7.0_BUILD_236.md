# Floe Agent 1.7.0 — Build 236

## 简体中文

本轮为内测修复版本：

- Office：修复原生文档通信在停止、关闭及切换期间继续回调的竞态，保持消息顺序并采用有界分块传输；新宿主已在云端编译并核验全部 4,780 个资源。
- Linux：并发首次使用共享一次存储恢复；取消等待及时返回，旧状态查询不再覆盖新状态，并显示实际恢复阶段。缺失镜像仍通过现有共享下载服务自动准备。
- 本地模型：精选联网搜索与只读文件查找工具，搜索请求优先保留搜索工具；无法提供搜索时不再强迫调用无关文件工具。云端模型保留原工具范围。
- 修复云端工作区 Git 工具参数正则被服务商拒绝的问题，并减少重复无效 Linux 指标日志。

已知限制：PPT 编辑模式闪退尚缺匹配系统崩溃栈，新通信修复不代表真机闪退已解决；Office 字体方框仍待真机确认。本地模型真实权重的搜索回答准确性仍未通过验收。Linux 下载、恢复耗时及启动需在设备复测。软重启尚未提供，既有环境不会自动更换基础镜像。

验证：14 项模拟 WK 原生通信场景、Linux 模块 430 项 XCTest 与 227 项 Swift Testing、15 项本地工具策略/运行时定向测试通过。扩大模型检查仍有在基线复现的上下文压缩、长会话分页、回执长度及取消测试失败；不宣称全套测试通过。组件、脚本模型及 macOS 结果均不是 iPad 验收。完整 App 编译、上传和 TestFlight 可安装状态分别核验。

## English

This internal beta includes:

- Office native transport lifecycle fixes for late callbacks during stop/close transitions, ordered writes and bounded data chunks. The rebuilt host and all 4,780 resources were verified in cloud CI.
- Linux first-use storage recovery is shared across concurrent callers. Cancelled waiters return promptly, stale status queries cannot overwrite newer state, and recovery stages are visible. Missing images continue through the existing shared automatic preparation service.
- Local models receive curated web search and read-only file tools, with search prioritized for search requests. Unavailable search no longer forces an unrelated file call. Cloud model tool discovery keeps its existing scope.
- Portable cloud-workspace Git argument regexes and reduced duplicate invalid Linux metric logs.

Known limitations: the PPT edit-mode crash still lacks a matching system stack; the transport fix is not proof of a device crash fix. Office square glyphs remain unverified on device. Real-weight local search-answer grounding has not passed acceptance. Linux download, recovery latency and boot require device retesting. Soft reboot remains unavailable; existing environments do not automatically replace their base image.

Validation: 14 mock-WK native transport cases, 430 Linux XCTest plus 227 Swift Testing tests, and 15 focused local-tool/runtime cases passed. Broader model checks retain baseline-reproducible context compaction, conversation paging, receipt-length and cancellation failures; the full suite is not green. Component, scripted-model and macOS evidence is not iPad acceptance. Full App compilation, upload and TestFlight installability are separate delivery checks.
