# Floe Agent 1.8.27（348）

## 简体中文

从数据管理打开 Linux 缓存清理时，终端和内置清理脚本会复用共享环境的清理目录。重复打开清理任务时也能使用同一个目录。

换机后的旧磁盘需要先核对上次中断的整理。现在可以在核对期间点一次「优化占用」，核对通过后接着整理。取消会同时取消这次请求。多条恢复记录处理完毕后，容量统计也会刷新。单个旧盘需要保留时，会继续检查其余符合条件的磁盘，并显示实际整理和保留的数量。

## English

Linux cache cleanup in Data Management reuses the shared environment’s cleanup folder for both the terminal and the built-in script, including when you open a cleanup task again.

When the app is checking a disk operation interrupted during migration, you can now tap Optimize Storage once to continue with optimization after verification. Cancel also cancels that request. Storage figures refresh after the app finishes recovering multiple interrupted operations. If one disk must be retained, the app continues checking independent eligible disks and reports how many it optimized and retained.
