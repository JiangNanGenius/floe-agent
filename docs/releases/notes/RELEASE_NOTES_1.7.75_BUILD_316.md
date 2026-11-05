# Floe 1.7.75 (316)

## 简体中文

- 修复背景音暂停后恢复时可能沿用旧音量的问题，零音量设置会在恢复前生效。
- 优化本机运行环境的栈访问与内存寻址，保留现有项目、文件和已安装内容。
- 3D 视觉检查支持等轴、顶视、正视等常用视角名称；参数错误时给出可操作的提示。

本构建用于 TestFlight。现有 315 正式版审核保持不变。

## English

- Fixed background sound sometimes resuming at its previous volume. Muted settings now apply before playback resumes.
- Improved stack access and address lookup in the local runtime while preserving existing projects, files and installed content.
- CAD observation accepts standard view names such as isometric, top and front, with actionable validation messages.

This build is for TestFlight. The existing Build 315 App Store review remains unchanged.
