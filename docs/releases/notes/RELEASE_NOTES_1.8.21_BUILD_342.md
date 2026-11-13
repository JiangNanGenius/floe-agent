# Floe 1.8.21 (342)

## 简体中文

- 完善中断的磁盘整理收尾：严格确认原盘未变后，仅清理该作业的临时副本，保留原资料、软件和恢复记录。
- 区分安全收尾与磁盘提交恢复，改善再次整理时的保护与诊断。

仅内部测试及现有GitHub／Feather渠道。实际回收量以设备完成结果为准；不承诺全部容量已经释放。

## English

- Improves recovery from interrupted storage cleanup: after strictly verifying the unchanged original disk, removes only the job's temporary copy while preserving files, installed software and recovery records.
- Separates safe cleanup from disk-commit recovery, with clearer protection and diagnostics when optimization resumes.

For internal testing and the existing GitHub/Feather channels. Reclaimed storage depends on completed work on the device; this does not promise that all capacity has been reclaimed.
