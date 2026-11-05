# Floe Agent 1.7.73（314）交付记录

日期：2026-11-05。不可变来源：`4b58205babf9f4ae415e7a9db9ed0e35a77996b5`，标签 `v1.7.73`。

## 简体中文

- 修复冷启动后，已有任务在环境注册表尚未加载时误判运行位置不可用、继而丢失执行工具的问题。恢复前先加载持久化记录，保留环境身份、文件和依赖；真正缺失、身份不匹配或需要重建的目标仍会被识别。
- 本地 Xcode 27.1（27A9275）Swift 6 完整 App 编译及 ARM64 设备归档通过。指定既有 iPad 模拟器上 8 项相关 App-host 检查通过；没有将这些结果记作物理设备多核性能证据。
- Apple 已处理为 `VALID`、未过期，现有 Floe QA 内部组为 `IN_BETA_TESTING`。`publictest1` 已提交一次，当前等待 Beta 审核，尚不能宣称公开链接可安装此构建。
- 正式 App Store 已从旧候选替换为 1.7.73（314），当前为“等待审核”，设置为审核通过后自动发布。提交编号：`4b8f56db-0a5d-4dfd-bd59-811ee0700a06`。原有物理 iPad 后台音频审核视频保留，说明其拍摄于 308，未冒充 314 新录制。
- [GitHub 稳定安装包](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.73)已核验不可变标签、来源、真实 arm64 iOS 可执行文件、远端字节摘要及 latest 指针；同一流程的 Feather 更新已等待完成并独立读回。
- 已通过 TestFlight 在物理 M4 iPad Air 13（iPadOS 27.2）更新到实际 314。终止并重新启动 App 后，同一任务直接调用 Linux 工具成功，运行目标身份保持不变，无需重新保存设置。
- 实际 ARM64 Linux 冷启动为 4 核／1024 MiB，用时 42.440 秒。4→1→4 核在线调整分别用时 164／143 毫秒；客体在线 CPU、进程 affinity 与 Python 查询一致，启动 ID 和启动代次均未改变，没有重启或重置环境。
- 完成 9 组交错顺序、固定总工作量的 Python 多进程测试，全部校验一致。相对单进程，中位吞吐为 2 进程 1.558×、4 进程 1.496×。此负载包含进程池开销，不等同 sysbench、原生硬件性能或与旧构建的同条件对比；不能据此承诺 4 倍加速，也没有将虚拟机全局配置限制为 2 核。
- 首次基准外层命令使用了未安装的 `/usr/bin/time` 和 POSIX Shell 不支持的 `PIPESTATUS`，未运行到基准脚本。保留原错误后，模型读取结果并改用 POSIX 包装完成测试，没有安装软件包或修改基准。原始完整输出、9 组结果、独立校验和界面证据已保存；未把显示用的短摘要当成完整工具返回。
- 本轮真实功能检查未发现阻断问题，因此保持 314 正式候选，不为未经测量的推测性优化另起 315。若排队期间出现实际问题，仍按授权用验证后的修复构建替换。
- 已整理到唯一 main 工作副本及本地、远端 main 分支。未完成工作、Git 恢复包和原始故障证据保留；Bridge 旧更新地址已迁移，兼容标签与发布标签未删除。已消费的私有 314 传输草稿已删除。

```text
Floe-Agent-1.7.73-build314-unsigned.ipa
bytes: 821388350
SHA-256: bd29740eebc3b3fa493ef7e3d545b363e7ae5db484cc17ec8323aef4f0da5128
```

## English

Build 314 fixes saved execution targets being rejected before the persistent environment registry is loaded at cold launch. Identity, files and dependencies remain intact; missing or incompatible targets still fail validation. The complete Swift 6 App build, device archive and eight focused App-host checks passed using Xcode 27.1 and the existing iPad Simulator.

Apple reports VALID, unexpired and available to Floe QA. External TestFlight is waiting for Beta review. Formal App Store submission now contains 1.7.73 (314), is waiting for review and is configured to release automatically after approval. The retained physical-device audio evidence is explicitly identified as footage from build 308.

The stable/latest unsigned GitHub package and awaited Feather publication have been independently verified. The actual TestFlight build also passed cold restoration on a physical M4 iPad. Linux ran with four CPUs and 1024 MiB; online 4→1→4 CPU adjustments took 164/143 ms with unchanged boot identity and generation. Nine counterbalanced fixed-work Python trials passed, with median speedups of 1.558× for two processes and 1.496× for four. This includes process-pool overhead and is neither native-hardware performance nor a paired comparison against an older build. An initial incompatible timing wrapper failed before the benchmark ran; the model read the retained error and completed the original benchmark with a POSIX wrapper, without installing dependencies or changing the test. No functional blocker was found, so build 314 remains the official candidate. The repository has one main worktree and only the main local/remote branch; unfinished work and recovery evidence are preserved.
