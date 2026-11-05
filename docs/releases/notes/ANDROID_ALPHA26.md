# Android Alpha26 — 中间预发布 / Intermediate prerelease

版本 / Version: `0.1.0-alpha.26` (`45`).

## 更新内容

- 文件编辑优先使用 Android 应用；没有合适应用时可转入 Linux 编辑器。保存后的修改使用原有文件归属和冲突恢复流程回传。
- 新增按项目复用的 Linux 图形会话、手机单应用／平板桌面显示，以及常用软件安装、卸载、缓存和会话管理入口。
- 手机操作支持用户占用时让路、持久提问等待、通知及可选悬浮控制；自动解锁需要单独同意和本机配置。
- 增加充电／联网条件触发；Office 和 CAD 预览组件按需安装，已安装内容可离线使用。
- 增加可查看回执的诊断上报。自动上报仅覆盖明确同意后的 App 崩溃和应用自身故障；普通任务异常不自动上传，截图仅由用户手动选择。
- GitHub 更新页和安装前展示中间版本的已知问题。

## 已知问题

- 这是允许功能尚不完善的中间版本。新增图形编辑、跨 App 自动化和按需组件仍需持续实机修复；代码接通或编译通过不代表所有设备流程已经通过。
- Linux 图形软件首次准备会下载依赖并占用较多空间。停止会话前请先在编辑器内保存；发生冲突时保留恢复版本，确认后再覆盖原件。
- Office 组件安装需要系统确认，部分系统会重启 App；完整包升级后可能需要重新安装组件。原文件和恢复记录继续保留。
- 条件任务由 Android 调度，可能延后；进程不存活期间的短暂断开／重连不能保证逐次捕获。
- 手机控制需要对应权限。安全锁屏、后台界面启动和厂商限制可能需要本人操作；授权尚未完成时不能承诺无人值守执行。

## Changes

- Prefer Android editing apps, with a Linux-editor path when no suitable handler is installed. Saved changes return through existing ownership, conflict and recovery services.
- Add project-scoped Linux graphical sessions, phone single-app/tablet desktop presentation, common software installation/removal, cache and session controls.
- Add durable human waiting when phone use conflicts, notifications and optional floating controls. Automatic unlock requires separate consent and local setup.
- Add charging/network conditions and on-demand Office/CAD preview components with offline reuse after installation.
- Add diagnostic submission and real receipt display. Automatic reports cover consented App crashes/internal faults, never ordinary task errors; screenshots require manual selection.
- Show intermediate-version known issues in GitHub update and installation flows.

## Known issues

- This intermediate version allows incomplete features. New graphical editing, cross-app automation and optional components still require device iteration; source wiring and compilation are separate from working device flows.
- Initial Linux setup downloads dependencies and needs storage. Save inside the editor before stopping; retain recovery versions and resolve conflicts before replacing originals.
- Office component installation needs system confirmation and may restart the App. A full-package update may require component reinstallation; documents and recovery records remain retained.
- Android may defer condition tasks; brief disconnect/reconnect transitions while the process is absent cannot be guaranteed individually.
- Phone control requires its permissions. Secure keyguard, background activity and vendor limits may require human intervention; incomplete authorization does not imply unattended operation.
