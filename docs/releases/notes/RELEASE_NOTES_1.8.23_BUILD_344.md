# Floe Agent 1.8.23（344）

## 简体中文

修复换机或更新后，旧磁盘整理作业因文件元数据变化而无法继续的问题。恢复会完整核对原盘内容，并在文件身份、引用和持锁检查持续有效时安全结束旧作业，再允许重新整理。原文件、已装软件及恢复盘保留。

为恢复期间的完整校验接入进度与取消，避免长时间只显示等待。取消发生在删除暂存副本之前；已经开始的短收尾会安全完成。

本次为内部容量修复版本。请在“设置 → 数据管理”运行“优化占用”，核对作业结果及设备剩余空间。实际回收量须由新版设备实测确认；不重复计算338的既有收益。

不提交公开TestFlight或正式App Store审核。GitHub未签名安装包与Feather更新源按既有内部交付渠道处理，需要自行签名。

## English

Fixes interrupted storage optimization that could remain blocked after file metadata changes during a migration or update. Recovery verifies the complete original contents and retains file identity, reference and lock checks before closing old work and admitting a fresh optimization. Original files, installed software and recovery disks are preserved.

Adds progress and cancellation to recovery verification. Cancellation stops before removing an internal staging copy; an already-started short finalization finishes safely.

This is an internal storage-repair build. Run Optimize Storage in Settings → Data Management, then check completed results and device free space. Actual reclamation requires device verification; earlier338 savings are not counted again.

No public TestFlight or formal App Store submission. Unsigned GitHub packages and the Feather feed follow the existing internal delivery policy and require your own signing.
