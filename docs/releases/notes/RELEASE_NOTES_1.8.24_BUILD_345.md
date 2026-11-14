# Floe Agent 1.8.24（345）

## 简体中文

修复换机后旧磁盘整理记录阻止再次整理的问题。恢复时完整核对文件内容，显示校验进度并支持取消；保留原资料、已装软件和恢复盘。实际回收量以整理完成后的结果和设备剩余空间为准。

清理 Linux 任务改为由助手通过终端检查和整理共享 Linux 内的缓存与垃圾；缓存检查工具不再是必须通过的前置步骤。没有可用模型时仍可使用安全清理脚本。

补齐语音云端配置等设置的 iCloud 同步与入站刷新，沿用现有凭据同步开关。优化字体打包并退役已被替代的旧组件，保留现有文档、字体内容和许可证。

优化图片工作台的工具、图层、导出与画布导航，修复同一编辑器连续更新原图的保存冲突。

本次用于内部测试；不提交公开 TestFlight 或正式 App Store 审核。GitHub 未签名安装包与 Feather 更新源按既有交付方式提供，需要自行签名。

## English

Fixes old storage-optimization records blocking a fresh optimization after device migration. Recovery verifies the complete file contents, reports progress and supports cancellation while preserving original data, installed software and recovery disks. Check completed results and device free space for actual reclamation.

Linux cleanup tasks now let the assistant inspect and clean caches and temporary junk inside the shared Linux system through its terminal. The cache-inspection tool is optional. A safe cleanup script remains available without a configured model.

Completes iCloud synchronization and incoming refresh for cloud voice configuration and other settings, using the existing credential-sync control. Deduplicates packaged fonts and retires replaced components while retaining documents, font contents and licenses.

Improves image-workbench tools, layers, export and canvas navigation, and fixes conflicts when updating the original image repeatedly in one editing session.

This build is for internal testing, with no public TestFlight or formal App Store submission. Unsigned GitHub packages and the Feather feed follow the existing delivery policy and require your own signing.
