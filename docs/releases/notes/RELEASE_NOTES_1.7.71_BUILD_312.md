# Floe Agent 1.7.71 (312)

## 简体中文

- 改善打开 3D 模型和工作台时的稳定性，保留原有编辑、保存和撤销功能。
- 修复部分任务在下一次发送时被环境检查点阻断，以及启动后设置需要再次保存才生效的问题。
- 本机 ARM64 运行环境支持最多四核；调整在线核心数时保留运行中的任务，内存变更仍需先停止环境。
- 后台音频可独立服务运行中的环境，关闭画中画不会停止环境。
- 恢复任务文件的直接入口及右侧面板的收起按钮。

## English

- Improved stability when opening 3D models and the workbench while preserving editing, saving and undo.
- Fixed environment checkpoints blocking a task's next message and saved launch settings not taking effect until saved again.
- The shared ARM64 runtime supports up to four cores. Online CPU changes retain running tasks; memory changes still require stopping the runtime first.
- Background audio works independently for a running environment. Closing Picture in Picture no longer stops it.
- Restored direct access to task files and the right panel's collapse button.
