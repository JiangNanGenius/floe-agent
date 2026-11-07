# Android Alpha52 / Android Alpha52

- Linux 图形会话启动后直接打开所选软件；重开界面继续原会话，不重复启动软件。
- 后台保护增加按真实申请关联的本机诊断，便于定位启动限制、通知权限和确认超时；诊断不包含任务正文、文件路径、凭据或界面截图。
- 未配置审批模型的提示按当前界面语言显示。
- Linux graphical sessions open the selected application after connecting. Reopening the view preserves the existing session without launching another copy.
- Local foreground diagnostics associate service startup, notification permissions and confirmation timeouts with the actual acquisition. They exclude task content, file paths, credentials and screenshots.
- Missing approval-model messages follow the current interface language.

## 已知问题 / Known issues

这是持续迭代的中间版本。三星条件任务已在上一版完成真实触发、终端交付和成果重开，但缺少审批模型时仍需人工授权，且后台保护提示的具体原因尚在定位。本版增加诊断，不代表已修复所有后台运行限制。手机观察间歇失效、软件跨任务保留、专业编辑流程及全局界面密度继续推进。

This intermediate build does not represent full-app acceptance. The prior Samsung condition task triggered a real run and delivered a file that reopened successfully, but required approval without a configured reviewer. The foreground-protection warning is still under investigation; added diagnostics do not claim that every background limit is repaired. Intermittent phone observations, software retention across tasks, professional editing workflows and UI density remain under iteration.

## 更新 / Updating

完整 APK 支持跨版本升级；增量失败时可直接下载完整包。安装前请保存正在编辑的文件。

The full APK supports cross-version upgrades. Download the full package if a delta fails, and save open documents before installing.
