# Android 0.1.0-alpha.38

设置菜单采用更紧凑的字号、行距和分组间距，手机弹层增加可用高度；开关缩小视觉尺寸并保留点击范围。聊天、文档和终端的阅读字号独立保留，系统字体缩放仍生效。

手机授权页把当前任务控制和应用选择前移。目标应用通过独立窗口按名称或包名搜索，筛选不会移除其他已选应用；权限仍由用户选择，不自动授权全部应用。

手机状态工具补充无障碍连接、目标应用选择和停止状态。缺少手机工具时，任务指引优先检查真实配置，明确手机屏幕与远程／Linux VNC 的区别。发行说明模板也修正了过时的“仅支持手动安装”表述。

## Known issues / 已知问题

这是 N01–N08 中间版，整轮工作仍在推进。Linux 图形首次启动仍可能黑屏；已有窗口实际已绘制，仅重开视口可显示，尚未确认根因。完整跨 App、条件触发、跨项目图形隔离、专业编辑保存及组件生命周期继续验收。单条历史显示上限4MiB，超过时保留完整导出。没有重试付费图片／视频生成。

## English

Settings use denser typography, row spacing and grouping, with more usable height on phones and a smaller switch visual inside retained touch targets. Chat, documents and terminal reading sizes remain independent; system font scaling still applies.

Phone settings move task controls and app selection forward. A separate searchable chooser matches app names and package IDs without clearing selections hidden by the query. It never grants all apps automatically.

The status tool reports accessibility, selected-app scope and stop state. Discovery guidance distinguishes Android phone UI from remote/Linux VNC and points missing phone tools to real configuration. Generated release copy no longer incorrectly states that only manual installation is supported.

This is an intermediate N01–N08 build. First graphical launch may remain black despite a painted X11 window; reopening the viewport displays it, but the cause remains unconfirmed. Cross-App, condition, isolation, professional save and component-lifecycle acceptance continue. Individual history display remains bounded at4MiB with complete export retained. No paid image/video generation was retried.
