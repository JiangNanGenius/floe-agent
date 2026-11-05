# Floe Agent 1.7.73（314）交付记录

日期：2026-11-05。不可变来源：`4b58205babf9f4ae415e7a9db9ed0e35a77996b5`，标签 `v1.7.73`。

## 简体中文

- 修复冷启动后，已有任务在环境注册表尚未加载时误判运行位置不可用、继而丢失执行工具的问题。恢复前先加载持久化记录，保留环境身份、文件和依赖；真正缺失、身份不匹配或需要重建的目标仍会被识别。
- 本地 Xcode 27.1（27A9275）Swift 6 完整 App 编译及 ARM64 设备归档通过。指定既有 iPad 模拟器上 8 项相关 App-host 检查通过；没有将这些结果记作物理设备多核性能证据。
- Apple 已处理为 `VALID`、未过期，现有 Floe QA 内部组为 `IN_BETA_TESTING`。`publictest1` 已提交一次，当前等待 Beta 审核，尚不能宣称公开链接可安装此构建。
- 正式 App Store 已从旧候选替换为 1.7.73（314），当前为“等待审核”，设置为审核通过后自动发布。提交编号：`4b8f56db-0a5d-4dfd-bd59-811ee0700a06`。原有物理 iPad 后台音频审核视频保留，说明其拍摄于 308，未冒充 314 新录制。
- [GitHub 稳定安装包](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.73)已核验不可变标签、来源、真实 arm64 iOS 可执行文件、远端字节摘要及 latest 指针；同一流程的 Feather 更新已等待完成并独立读回。
- 物理 M4 iPad 的 314 虚拟机测试与基于实测的优化继续进行，不预先宣称完成或性能提升。若排队期间发现功能问题，仅以修复并验证后的新构建替换；没有问题则保持当前候选。
- 已整理到唯一 main 工作副本及本地、远端 main 分支。未完成工作、Git 恢复包和原始故障证据保留；Bridge 旧更新地址已迁移，兼容标签与发布标签未删除。已消费的私有 314 传输草稿已删除。

```text
Floe-Agent-1.7.73-build314-unsigned.ipa
bytes: 821388350
SHA-256: bd29740eebc3b3fa493ef7e3d545b363e7ae5db484cc17ec8323aef4f0da5128
```

## English

Build 314 fixes saved execution targets being rejected before the persistent environment registry is loaded at cold launch. Identity, files and dependencies remain intact; missing or incompatible targets still fail validation. The complete Swift 6 App build, device archive and eight focused App-host checks passed using Xcode 27.1 and the existing iPad Simulator.

Apple reports VALID, unexpired and available to Floe QA. External TestFlight is waiting for Beta review. Formal App Store submission now contains 1.7.73 (314), is waiting for review and is configured to release automatically after approval. The retained physical-device audio evidence is explicitly identified as footage from build 308.

The stable/latest unsigned GitHub package and awaited Feather publication have been independently verified. Physical M4 iPad VM testing and measured optimization remain in progress; no new physical performance claim is made. The repository now has one main worktree and only the main local/remote branch; unfinished work and recovery evidence are preserved.
