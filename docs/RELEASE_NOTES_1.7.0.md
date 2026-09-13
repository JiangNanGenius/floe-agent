# Floe 1.7 — 发布描述草稿 / Release description draft

状态：1.7.0（149），候选标签 v1.7.0-beta.6；待云端检查、签名与上传。下列描述对应当前实现范围，待固定提交的完整验证完成后用于新测试版本。既有版本说明保留其历史原文。

### 简体中文

Floe 将 AI 助手、手记和创意工作流放在同一个以 iPad 为优先的原生应用里。手记独立管理课件、手写批注、Office 文件和图文思维导图，并与 Floe 助手共享模型和经过授权的资料。

- 手记：独立入口、笔记本、最近打开、收藏与回收站，PDF/图片批注、Apple Pencil 书写、套索与选区提问、保存解释及来源。
- 动态导图：主题、附图、附件、关联线和分支编辑，自动排版，支持独立创建、文档关联和 PDF 小窗；Agent 按授权编辑，撤销独立。
- Office 与导出：手记内打开 Office 编辑器，保留保存恢复链路；`.floenote` 保留可编辑资料与关联导图，PDF 分享带批注页面，Markdown 导出大纲。Word 画笔、更多转换与 PPT 放映仍需完整运行验收；Excel 暂缓增强。
- 媒体与语音：图像工作台、单素材视频剪裁与字幕，Whisper 多语言模型按需下载，不能使用时回退 Apple；文件转录提供 SRT/VTT/JSON。
- 环境与界面：项目/会话容器和软件包管理、通用设置中的自动/浅色/深色外观、改进的思考与工具调用框、连续工具折叠。

### English

Floe brings its AI assistant, independent Notes workspace and creative workflows together in an iPad-first native app. Notes organizes annotated course materials, handwriting, Office files and illustrated mind maps, while sharing Floe models and explicitly authorized material with the assistant.

Notes includes notebooks, recents, favorites, Trash, Pencil-first writing, region questions and editable archives. Dynamic maps support illustrated topics, attachments, independent editing and linked PDF windows. Image and video workbenches share local files; on-demand multilingual Whisper powers speech and timed captions with Apple fallback. Project/session package controls and automatic light/dark appearance extend the application workspace.

This description is a beta preparation draft. Word ink, extended conversions, PPT presentation, complete media/model delivery and physical-device qualification are not yet claimed as accepted features.

## TestFlight “What to Test” — 待验收后随构建填写

1. iPad 优先：导入课件、书写、套索提问、保存回答、关闭重开；手指书写关闭时不能误写。
2. 导图：长标题与附图、展开折叠、拖动分支、Agent 编辑、PDF 小窗缩放与旋转、独立撤销、来源跳转。
3. 数据：`.floenote` 导出导入、Office 保存恢复、回收站恢复/永久删除；共享附件、其他文档及聊天资料不被误删。
4. 语音与媒体：中英混说、取消与失败回退、长文件字幕、剪裁/字幕导出重开及音画同步。
5. 双端与回归：iPad/iPhone，SDK 27 与 26 兼容；聊天、工具、中文 Office、工作区、Canvas 和 PiP。

## 发布门槛与填写项

- 固定 source SHA、版本与 build number、归档/上传运行、Apple 处理及可安装状态：待完成。
- 当前云端 53 项平台测试与双端合成 Whisper 推理是定向证据，不等于整版验收。
- 15 个候选软件包、33 个候选模型、15 类媒体能力以[资格矩阵](FLOE_1_7_QUALIFICATION_MATRIX.md)为准，不能因目录存在就标为可用。
- 完整当前记录：[继续实施状态](FLOE_1_7_CONTINUATION_STATUS.md)。恢复步骤：[迁移与恢复](FLOE_1_7_MIGRATION.md)。

截图沿用原始测试产物并注明提交、设备与场景。组件测试画面只能用于说明对应组件，不能作为完整新版本界面的交付证据。

## 真机检查交接

用户已指定由自己执行 iPad/iPhone 真机检查。自动化构建、测试和上传由本轮继续完成；真机结果由用户在 TestFlight 安装后确认，不把设备开发服务可用或模拟器通过写成真机验收。
