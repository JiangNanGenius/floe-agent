## Floe Agent 1.5.1 (Build 132)

### 简体中文

本次先发布已经完成的工作流升级，方便真机测试。

- 修复长文本工具参数仍在传输时被误判超时的问题；文本文件创建、写入和补丁支持更大的单次内容。真正断流仍会结束等待。
- 长思考展开改为分块阅读，保留完整原文，支持全屏、回到开头和查看最新内容。
- 插件增加发现与已安装管理、卸载后重新安装和简洁的版本更新入口。
- 聊天长按后可选择多个，支持批量归档、删除与恢复；进入聊天定位到最新内容。
- 文件管理集中查看各工作区；PDF 可在右侧直接阅读并切换全屏。
- 改善 iPhone 画布导航、节点创建位置和横竖屏编辑；生成任务放在创建菜单首位，支持修改已有 SVG、HTML 等节点。
- 改善聊天、画布的状态刷新和工作区清理恢复；画中画显示阶段、耗时及活动信息。
- 修复 PDF 表单脚本加载与 Stata 清理命令，调整工具与技能发现说明。

Word、Excel、PowerPoint 的完整离线深度编辑引擎仍在验证，本版不宣称完成该能力。超长输入和 Markdown 正文性能、真实模型长文请求、画布横屏细节和真机长任务仍需测试。完整范围和操作截图见 [更新文档](WORKFLOW_UPGRADE.md)。

源码功能检查已通过完整 CI；发布构建、签名上传、Apple 处理和测试组可见性由本次发布流程分别核验。内部测试版尚未在此文档中标记为已可安装。

### English

This test release delivers the completed workflow improvements for device testing.

- Track continuing tool-argument transmission to avoid false stream timeouts; allow larger text-file creation, writes and patches while retaining finite silence detection.
- Read expanded long reasoning in bounded fragments with full source preservation, fullscreen mode and beginning/latest navigation.
- Add plugin discovery, installed-item management, persistent uninstall/reinstall and concise version updates.
- Long-press conversations to select multiple tasks for archive, delete or restore; open conversations at the latest content.
- Browse workspaces from file management and read PDFs inline with optional fullscreen.
- Improve iPhone canvas navigation, visible node placement and orientation handling; put generation first and refine existing SVG/HTML nodes.
- Improve conversation/canvas state refresh, recover workspace cleanup and expose stage, elapsed time and activity in Picture in Picture.
- Correct PDF form script loading and Stata clear behavior, and clarify tool/skill discovery.

The complete offline Word, Excel and PowerPoint editing engine remains under qualification and is not claimed as complete. Long composer/Markdown performance, live-provider long writes, landscape canvas polish and device lifecycle acceptance remain open. See the [upgrade scope and screenshots](WORKFLOW_UPGRADE.md).

Functional-source CI passed. This release separately verifies builds, signing/upload, Apple processing and internal tester visibility; this document does not yet claim installation availability.
