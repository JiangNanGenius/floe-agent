# Floe Agent 1.4.73 (Build 104) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

This candidate completes the canvas content → task → artifact workflow. Build 104 is considered available only after App Store Connect reports a valid processed build and the internal TestFlight group can see it.

## Focus areas

- **Node AI:** select a content or generation-task node and use the compact AI field below it. The update must apply in place, remain undoable, show bounded progress, and never open Canvas Assistant or start generation.
- **Explicit execution:** Save Configuration must return to a configured task card. Generation begins only after Start Generation is pressed. Running tasks expose Cancel; failure exposes Retry on the same task and artifact nodes.
- **Status:** task and artifact cards should agree across preparing, reference upload, queued, running, processing, download, ready, failed, cancelled, and expired states.
- **Touch:** pan empty space with one finger, move a node with one finger, pan and zoom with two fingers, draw with Pencil, and drag a 44-point connection target with preview, snapping, highlighting, haptics, and empty-space quick creation.
- **Canvas Assistant:** selected images should route through Canvas Vision when the primary model is text-only. Missing capability and deterministic failures must stop once; transient provider errors may retry once; an unchanged tool-result retry must end that route.
- **Compatibility:** open an older canvas with legacy generation metadata, configure and retry a failed artifact, switch canvases, relaunch, and confirm the selected canvas, undo, persistence, and sync behavior remain correct.

## 简体中文

本候选版补全画布“内容节点 → 任务节点 → 产物节点”链路。只有 App Store Connect 显示构建处理有效，并且内部 TestFlight 测试组可见 Build 104 后，才算真正可用。

- 节点下方 AI 必须原位修改当前节点，可撤销、显示有界进度，不打开右侧助手，也不自动生成。
- “保存配置”后任务卡显示“已配置”，只有点击“开始生成”才执行；运行中可取消，失败后在原任务和原产物节点重试。
- 单指拖空白平移、单指拖节点移动、双指平移缩放、Pencil 绘制；连线具有大触控区、曲线预览、磁吸、高亮、反馈和空白处快速新建。
- 文本主模型遇到选中图片时使用画布视觉模型生成有界描述；缺少能力和确定性错误不循环，瞬时网络错误至多重试一次。

反馈请注明 Build 104、设备和系统版本、模型与供应商、画布/任务 ID、准确操作与时间。不要上传 API Key、Token、密码、SSH 私钥、证书或描述文件。
