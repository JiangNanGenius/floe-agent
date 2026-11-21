# Floe Agent 1.8.67（388）

## 简体中文

- Linux 启动时会为仍可核验的旧磁盘记录补齐稳定的卷标识。后台装包遇到无法核验的旧磁盘时，会显示保留数据的恢复操作。
- 补齐 App 内 Linux 离线安装的回归验证，核对安装结果、命令超时前的输出，以及超时后的子进程清理。
- 验证主任务与两个子任务可以在同一 Linux 环境中并行运行，各自保有独立的终端会话和输出。
- 更新模型提示词的回归检查，覆盖 Linux CPU 在线调整、共享运行保护，以及区分图形渲染、计算与视频编解码能力。
- 合并 Linux 虚拟盘和挂载工作区的部分读写。支持从 Linux 回收虚拟盘空闲块，跨盘准备镜像时保留稀疏区域。
- 长期记忆显示关联与遗忘状态。打开记忆详情可改写原有内容，确认的新事实可覆盖同一范围内的旧值。

## English

- On startup, Linux records stable volume identifiers for older disks whose identity can still be verified. Background installs show data-preserving recovery instructions when disk verification fails.
- Verify in-app offline Linux package installation, output retained by timed-out commands, and cleanup of their child processes.
- Verify that a main task and two delegated tasks can run concurrently in one Linux environment with separate terminal sessions and output.
- Update prompt regression checks for live Linux CPU changes, shared environment safeguards, and separate reporting of graphics, compute, and video codec capabilities.
- Batch Linux disk and mounted-workspace transfers. Reclaim free virtual-disk blocks from Linux and preserve sparse areas when preparing images across volumes.
- See which long-term memories are linked or fading. Edit an existing memory from its details and replace the previous value with a confirmed update in the same scope.
