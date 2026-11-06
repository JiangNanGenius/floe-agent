# Android Alpha28 — 中间预发布 / Intermediate prerelease

版本 / Version: `0.1.0-alpha.28` (`47`).

## 更新内容

- 轻量文本和代码编辑留在 App 内；外部编辑直接调用 Android 默认应用，保留保存回传和冲突恢复。Linux 桌面软件作为专业能力的可选入口，不再默认安装或启动文本编辑器。
- 更新弹窗和设置提供直接下载完整安装包，可跨多个版本升级；增量中断后保留完整目标，App 重启后仍可继续选择完整包。
- 内置编辑器重新打开干净标签时刷新外部保存的内容，真正的未保存草稿继续保留。
- 修复 Linux 图形会话停止时清理临时连接凭据漏传所有者的问题，补充不含文件内容和凭据的阶段错误码。

## 已知问题

- 这是快速迭代中间版本。新增原生应用跳转、Linux 停止修复及跨版本完整包安装仍需实际设备确认；编译通过不代表这些行为全部通过。
- Linux 专业软件的安装、输入和文件保存回传继续迭代；已保存文件和恢复副本保留，不以窗口显示成功代替保存完成。
- 自动解锁尚未在本轮三星启用；跨 App、定时和厂商后台限制仍有待逐项实测。

## Changes

- Keep lightweight text/code editing in Floe. External editing opens the Android default app directly, retaining save-back and conflict recovery. Linux desktop applications remain an optional professional capability, without installing or launching a text editor by default.
- Offer direct full-installer downloads in update dialogs and settings, including upgrades across multiple versions. Preserve the full target after an interrupted delta so the choice survives an App restart.
- Refresh externally saved contents when reopening clean editor tabs; retain real unsaved drafts.
- Include the required owner when removing temporary Linux display credentials during shutdown. Add bounded stage diagnostics without file contents or credentials.

## Known issues

- This is an intermediate iteration. New Android app launching, Linux shutdown repairs and cross-version full installation still require device confirmation; compilation alone does not establish those results.
- Linux professional software installation, input and save-back remain in iteration. Retain saved files and recovery copies; a visible window does not establish a completed save.
- Automatic unlock was not enabled in this Samsung round. Cross-app execution, scheduling and vendor background limits still need focused use.
