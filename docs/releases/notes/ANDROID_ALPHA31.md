# Android 0.1.0-alpha.31 · code50

GitHub Full 中间预发布，保留 iOS Latest；本轮完整目标继续推进。

## 本次修复

- 修复部分 Android 13 设备下载更新后停在“等待系统确认”、没有打开安装窗口的问题，恢复 App 与已安装 Linux 运行组件的联合更新确认。
- 保留已校验下载、取消和重试入口。安装完成仍核对实际 App/运行组件版本、签名和摘要，不将下载完成或子包完成当成全部升级成功。
- 包含 Alpha30 的 Office 只读恢复、手机操作暂停/继续、条件调度、四图反馈压缩与进度、文字/附件分开发送及 Linux 准备诊断修复。相关代码已通过编译和定向检查，设备行为继续逐项核验。

## 已知问题

- 若旧 Alpha30 安装器已卡在等待确认，取消该次安装后，用系统文件管理器打开已下载的完整 APK；或从本页重新下载后覆盖安装。旧版首次过渡可能仍需到执行环境更新运行组件一次，请保留应用和项目数据。
- 本版仍为中间版本，手机暂停/继续、系统条件触发及厂商差异继续实测；四张大图反馈仍有测试网络超时记录。普通任务/工具/供应商异常不会自动上报。
- 整体字号、密度和控件比例将在功能接通后集中优化。TIFF 预览仍未实现；自动解锁需单独同意及配置，不保证所有锁屏方式均可无人介入。

---

Intermediate GitHub Full prerelease; iOS Latest is preserved and the complete goal remains active.

Fixes an Android 13 update failure where a verified download waited indefinitely for system confirmation. Owned main/runtime installation confirmations now reach the user; final success still requires installed package identity checks. Verified downloads, cancellation and retry remain available. Includes Alpha30's Office preview recovery, phone pause/resume, condition scheduling, compressed four-image feedback, separate text/attachment sending and Linux preparation diagnostics.

Known limits: an already affected Alpha30 installer may need a one-time full APK installation through the system file manager, followed by any requested runtime update. Preserve App/project data. Phone pause/resume, system conditions and vendor-specific behavior remain under device testing; large-image feedback has a recorded network timeout. Ordinary task/tool/provider failures are excluded from automatic reports. Global UI sizing/density work and TIFF preview remain pending. Automatic unlocking requires separate consent/configuration and supported device permissions.
