# Floe 1.7.78 (319)

## 简体中文

- 优化本机运行环境的多核效率，减少核心之间的相互干扰，并继续检查单核表现。
- 新增设备存储空间提醒，显示可用空间和处理方法；空间已满导致保存或下载失败时，释放空间后可重试。
- 修复终端启动时切换全屏导致连接取消的问题，保留主动结束和重新连接。
- 包含背景音音量恢复修复，保留项目、文件、设置和已安装内容。

本构建用于 TestFlight。性能收益因设备和负载而异；现有 315 正式版审核保持不变。

## English

- Improved multicore efficiency in the local runtime by reducing interference
  between cores, with single-core performance checked alongside parallel work.
- Added device storage warnings with available space and recovery guidance.
  Free up space and retry saves or downloads that failed because storage was full.
- Fixed terminal startup being cancelled when switching to full screen,
  while retaining explicit stop and reconnect controls.
- Includes the background sound volume restoration fix, preserving projects,
  files, settings and installed content.

This build is for TestFlight. Performance gains depend on the device and
workload. The existing Build 315 App Store review remains unchanged.
