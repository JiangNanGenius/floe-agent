# Floe Agent 1.8.30（351）

## 简体中文

更新或重新下载 Linux 环境后，Floe 会整理已替换的安装镜像和旧版 RISC-V 运行文件。现有 ARM64 工作盘继续保存已安装的软件和系统配置。再次打开「优化占用」时，已经核验且没有变化的磁盘可以跳过内容扫描。

数据管理改进了共享磁盘文件的空间估算。当设备只能提供部分文件的实际占用时，空间概览会说明估算范围。

从数据管理启动 Linux 清理时，助手会检查系统和已安装工具的缓存，按实际占用清理可再生文件。内置脚本仍可在没有模型时清理 apt、pip 和 npm，并显示 Linux 系统盘的可用空间。

共享 Linux 在图形加速初始化失败时会用 CPU 继续启动。运行中的环境提供可用图形设备时，设置里才会显示显存选项。

## English

Floe cleans up replaced Linux installation images and retired RISC-V runtime files after an environment update or download. The existing ARM64 working disk keeps installed software and system settings. Optimize Storage can skip reading disks whose contents were already checked and have stayed the same.

Data Management improves storage estimates for shared disk files. The overview indicates when the device can measure only part of the storage.

Linux cleanup in Data Management now lets the assistant find caches for the tools you have installed and remove regenerable files based on their actual size. Without a model, the built-in script cleans apt, pip and npm caches and reports free space on the Linux system disk.

Shared Linux can start on the CPU if graphics acceleration fails to initialize. The graphics memory setting appears when the running environment has an available GPU.
