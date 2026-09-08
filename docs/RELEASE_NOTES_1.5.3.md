## Floe Agent 1.5.3 (Build 134)

### 简体中文

**已在 Floe QA 内部 TestFlight 测试组开放：1.5.3（134）。** Apple 处理和测试组可见性已于 2026 年 9 月 9 日（悉尼时间）核实。

本次发布工作流升级和本地文档转换工具，方便真机测试。

- 新增 Markdown、Word DOCX、HTML、RTF 和文本文件互转，以及与 PDF 的转换。直接读取已有文件，不让模型重新抄写全文，减少 token 消耗。保留源文件并保存新副本；格式、扫描件和布局限制会明确报告。

- 更新火山 Seedance 2.5、Seedream 5.0 Pro/Lite 预设和实际调用参数；校正阿里 Wan 3.0 的 2–30 秒时长与分辨率，保留旧模型入口。
- 修复长文本工具参数仍在传输时被误判超时的问题；文本文件创建、写入和补丁支持更大的单次内容。真正断流仍会结束等待。
- 长思考展开改为分块阅读，保留完整原文，支持全屏、回到开头和查看最新内容。
- 修复插件更新目录的多语言说明格式，并在签名前校验，避免更新列表读取失败。
- 插件增加发现与已安装管理、卸载后重新安装和简洁的版本更新入口。
- 聊天长按后可选择多个，支持批量归档、删除与恢复；进入聊天定位到最新内容。
- 文件管理集中查看各工作区；PDF 可在右侧直接阅读并切换全屏。
- 改善 iPhone 画布导航、节点创建位置和横竖屏编辑；生成任务放在创建菜单首位，支持修改已有 SVG、HTML 等节点。
- 改善聊天、画布的状态刷新和工作区清理恢复；画中画显示阶段、耗时及活动信息。
- 修复 PDF 表单脚本加载与 Stata 清理命令，调整工具与技能发现说明。

Word、Excel、PowerPoint 的完整离线深度编辑引擎尚未接入；其原生构建因空间不足停止。PowerPoint 新建、完整图表/附件/深度排版仍未完成；现有幻灯片文字可检查和修改。超长输入和 Markdown 正文性能、真实模型长文请求、画布横屏细节和真机长任务仍需测试。完整范围和操作截图见 [更新文档](WORKFLOW_UPGRADE.md)。

本版已通过完整 CI（1,007 次 SwiftPM 测试、122 项应用回归）和两套 SDK 的发布回归（各 122/122 通过），并完成签名上传、Apple VALID 处理及内部测试组验证。转换测试覆盖 48,122 字、42 页的文本完整性检查。详细证据见[发布验证记录](RELEASE_VERIFICATION_1.5.3.md)。

### English

**Available to the existing Floe QA internal TestFlight group: 1.5.3 (134).** Apple VALID processing and internal group visibility were verified on September 9, 2026 (Australia/Sydney).

This test release delivers workflow improvements and offline document conversion for device testing.

- Convert existing Markdown, DOCX, HTML, RTF and text files, plus PDF input/output, without model rewriting. Preserve source files and save new copies; report format, scanned-page and layout limitations.

- Refresh Seedance 2.5 and Seedream 5.0 Pro/Lite presets and request parameters; correct Wan 3.0 duration/resolution options while retaining older presets.
- Track continuing tool-argument transmission to avoid false stream timeouts; allow larger text-file creation, writes and patches while retaining finite silence detection.
- Read expanded long reasoning in bounded fragments with full source preservation, fullscreen mode and beginning/latest navigation.
- Validate localized release notes before signing the plugin catalog, preventing update-list decoding failures.
- Add plugin discovery, installed-item management, persistent uninstall/reinstall and concise version updates.
- Long-press conversations to select multiple tasks for archive, delete or restore; open conversations at the latest content.
- Browse workspaces from file management and read PDFs inline with optional fullscreen.
- Improve iPhone canvas navigation, visible node placement and orientation handling; put generation first and refine existing SVG/HTML nodes.
- Improve conversation/canvas state refresh, recover workspace cleanup and expose stage, elapsed time and activity in Picture in Picture.
- Correct PDF form script loading and Stata clear behavior, and clarify tool/skill discovery.

The complete offline Word, Excel and PowerPoint editing engine remains unintegrated after its native qualification stopped at the disk reserve. PowerPoint creation, full charts/attachments and advanced layout remain unfinished; existing slide/note text fields can be inspected and updated. Long composer/Markdown performance, live-provider long writes, landscape canvas polish and device lifecycle acceptance remain open. See the [upgrade scope and screenshots](WORKFLOW_UPGRADE.md).

Full CI passed with 1,007 SwiftPM test executions and 122 app regressions. Release app regressions passed on both SDKs (122/122 each), followed by signed upload, Apple VALID processing and internal group visibility verification. Conversion coverage includes a 48,122-character, 42-page text-integrity fixture. See the [release verification record](RELEASE_VERIFICATION_1.5.3.md).
