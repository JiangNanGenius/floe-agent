# Floe 1.7.35 (276) — Office handwriting, presentation charts, iPad text entry and attachment navigation

Beta candidate. This document describes the changes in this build only; signing, upload, Apple processing and test-group availability are recorded separately and are not claimed here.

这是新测试版候选（1.7.35 / 276）的更新说明，仅描述本构建的改动；签名、上传、Apple 处理与测试组可用状态另行记录，本文不作声明。

## 简体中文

- **Office 手写**：在 Word、Excel 和 PowerPoint 中可用不同颜色与线宽添加笔迹，保存并重新打开后笔迹仍保留；三种文档格式均保存为矢量笔迹。Apple Pencil 的压力手感与手掌防误触仍需在真机上确认。
- **演示文稿图表**：可修改图表的分类名称、数值和中文标签，增删数据系列后保存并重新打开。图表内嵌工作簿的数据、类型和公式保持不变；现有引擎可能规范化部分图表样式、默认字体或未使用的样式条目，不承诺逐字节或完整样式一致。
- **iPad 输入**：长消息在输入框中自动换行，展开输入框不遮挡内容；发送后已发送文字保持清空，前往手记再返回时新输入但未发送的草稿仍保留。
- **附件与预览**：从对话打开附件编辑后返回原对话，内容与任务归属不变；HTML 文件可在 IDE 中启动和停止本地预览，停止预览不会取消对话。
- **本地任务**：配置自己的 AI 服务后，可让助手执行简短本地任务并生成文档或图片，再打开结果。首次启动本地环境可能需要下载，任务代码在已解析的 Linux 环境中执行，不使用宿主解释器。
- **基础改进**：保留上一版的隐私清单覆盖、语言与区域解析、反馈截图字段和存储卷判定修复。

验证边界：本轮以本地 Xcode 27 Release 配置构建 iOS 设备 App，并在模拟器中使用真实配置的模型与真实的 Office 文档完成图表数据/中文分类/增删系列、保存重开以及 Word/Excel/PowerPoint 三格式手写验收。未重新执行完整付费模型业务矩阵，也未进行真机验收；组件与模拟器结果不代替真实 iPad 上的 Apple Pencil 手感、手掌防误触与性能表现。

## English

- **Office handwriting**: add ink with different colors and widths in Word, Excel and PowerPoint; strokes remain after saving and reopening, and all three document formats keep vector ink. Apple Pencil pressure feel and palm rejection still need physical-device confirmation.
- **Presentation charts**: edit chart category names, values and Chinese labels, then add or remove data series, save and reopen. The embedded workbook data, types and formulas are preserved; the existing engine may normalize some chart styling, default fonts or unused style entries, so byte-for-byte or complete style fidelity is not claimed.
- **iPad text entry**: long messages wrap in the composer and the expanded field stays usable; sending clears the sent text, and after visiting Notes and returning, newly typed but unsent text remains as a draft.
- **Attachments and previews**: open an attachment from a conversation, edit it and return to the same conversation with its content and task ownership intact. An HTML file can start and stop a local IDE preview; stopping the preview does not cancel the conversation.
- **Local tasks**: with your own AI service configured, ask for a short local task and open the resulting document or image. The first local environment launch may download content; task code runs in the resolved Linux environment, not through a host interpreter.
- **Base improvements**: the previous build's privacy-manifest coverage, language/region resolution, feedback screenshot field and storage-volume checks remain in place.

Qualification limits: this round built the iOS device App with local Xcode 27 in Release configuration, and used the Simulator with a real configured model and real Office documents to accept chart data, Chinese categories, adding/removing series, save/reopen, and handwriting in Word, Excel and PowerPoint. The full paid-model business matrix was not rerun and no physical-device acceptance was performed; component and Simulator results do not replace real-iPad Apple Pencil feel, palm rejection or performance.
