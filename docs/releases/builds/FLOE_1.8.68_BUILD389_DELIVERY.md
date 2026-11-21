# Floe Agent 1.8.68（389）

冻结源为 `56b8e3303c65d00619b698ad14144776d50cdf03`，标记为 `v1.8.68`。Xcode 27.2（27B52）本地设备 Release 编译通过。App 与四个扩展的版本一致，19 份调试符号与二进制匹配。

- **内部 TestFlight**　Apple GET 确认 `VALID`、未过期、`APP_STORE_ELIGIBLE`，Floe QA 为 `IN_BETA_TESTING`，构建可安装。本次交付的范围为内部测试。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/44932596637)
- **GitHub 与 Feather**　GitHub 将 `v1.8.68` 标为最新版。无签名 IPA 为 721,781,307 字节，SHA-256 为 `3f7932243726eedb334899509010b2aafebc4559849cd2ae7c8bf454544e47e2`。公开下载与 Feather 首项的构建号、地址、文件大小和摘要均已回读。 [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.68) · [发布与更新源验证](https://github.com/JiangNanGenius/floe-agent/actions/runs/44935490382)

## 运行验证

- 在固定 iPad 模拟器中用实际 Linux 客机验证了旧盘保留、离线 wheel 安装、超时后的子进程退出和输出完整性。脚本化模型驱动的主任务与两个子任务共用一个客机，并占用独立终端，实测约有 7.9 秒重叠执行。
- 长期记忆显示仍有关联、遗忘中或来源已删除。同范围的新确认事实可以替换旧事实。iPad 模拟器核对了列表、详情编辑、保存和重新打开，48 项定向记忆测试通过。设备构建回读了九种本地化资源。
- M5 Pro 上以相同四 vCPU Debian 镜像，对冻结候选和 387 做 108 项小文件校验。单进程挂载读中位数从 2.870 秒降至 2.152 秒，同步写从 2.816 秒降至 2.058 秒。四进程挂载读和虚拟盘同步写出现回退。挂载文件的读写、重命名继续使用原宿主文件，实测保留文件 inode。两次虚拟盘 discard 各回收 131.65 MiB APFS 分配块。 [工况与原始指标](../../ARM64_RUNTIME_PERFORMANCE.md)

真机 iPad 的性能与多进程尾延时仍需实测。桌面宿主、iPad 模拟器的运行证据和 Apple 分发状态分别核对。
