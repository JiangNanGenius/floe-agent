# Floe Agent 1.4.74 (Build 105) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

This candidate completes the canvas content → task → artifact workflow and adds background and tool-chain reliability fixes. Build 105 is considered available only after App Store Connect reports a valid processed build and the internal TestFlight group can see it.

## Focus areas

- **Canvas workflow:** node AI updates the selected node in place; configuration never starts generation; Start, Cancel, Retry, and Generate Again reuse the task and artifact chain with synchronized status.
- **Touch:** verify direct empty-space panning, node dragging, simultaneous two-finger pan/zoom, Pencil drawing, double-tap actions, and connection-port preview, snapping, haptics, and quick creation.
- **Canvas Assistant:** text-only models use the configured Canvas Vision fallback once; deterministic errors and unchanged tool results stop instead of looping.
- **Picture in Picture:** manually closing PiP keeps it closed for the current task batch across later foreground/background transitions. A new Run resets the choice; background execution can continue without PiP.
- **Tool chaining:** long tool output must retain stable IDs and artifact paths. Verify SSH task continuation, saved connection sessions, remote hosting share lookup, and cloud-workspace catalog → file/Git actions without invented IDs or repeated mutations.
- **Compatibility:** open older canvas generation metadata and existing host/workspace settings, then confirm undo, persistence, sync, retry, and recovery remain intact.

## 简体中文

本候选版补全画布“内容节点 → 任务节点 → 产物节点”链路，并加强后台与工具执行链稳定性。只有 App Store Connect 显示构建处理有效，并且内部 TestFlight 测试组可见 Build 105 后，才算真正可用。

- 节点 AI 原位修改；保存配置不生成；开始、取消、重试和再次生成沿用同一任务与产物节点并同步状态。
- 验证空白单指平移、节点拖动、双指平移缩放、Pencil、双击，以及连线预览、磁吸、反馈和快速新建。
- 文本模型只调用一次画布视觉回退；确定性错误和重复工具结果立即停止，不能死循环。
- 手动关闭画中画后，同一任务批次后续切换前后台不再自动弹出；后台任务仍可继续，新 Run 才重置选择。
- 长工具结果必须保留稳定 ID 和产物路径；重点验证 SSH 任务续查、会话 ID、远程分享 ID，以及远程工作区目录到文件/Git 操作的连续链路。

反馈请注明 Build 105、设备和系统版本、模型与供应商、画布/任务 ID、准确操作与时间。不要上传 API Key、Token、密码、SSH 私钥、证书或描述文件。
