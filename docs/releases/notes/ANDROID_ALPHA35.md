# Android 0.1.0-alpha.35

反馈上传窗口增加“停止上传”，停止当前请求和自动重试，保留原报告及截图供手动重试。停止后的迟到响应不能覆盖当前状态；明确重试会替换仍在收尾的旧上传作业。报告专用连接使用 HTTP/1.1，作为四张大图上传超时的兼容性修复，实际效果仍待本候选实测。

Linux 文件管理器启动时明确打开当前项目的新窗口，避免只有后台进程、图形区域保持黑屏。三星已在同一会话中通过显式打开窗口显示工作区；本候选正常启动入口尚待复测。

Full/Play Kotlin 编译、6项上传定向测试及实际生成的 Linux 启动脚本回归通过。原生输入未改，复用已有生产对象与链接证据。没有新增模型、图片或视频调用。

## Known issues / 已知问题

这是 N01–N08 功能修复中间版，不保证全部功能可用。原四图上传超时记录保留，不能仅凭连接策略变化宣称已经解决。完整手机跨 App 流程、条件调度、项目图形会话复用与组件生命周期继续验收。超预算单条执行历史仍明确失败；完整任务导出保留。全局字号、控件密度、图标与材质精修后置。

Feedback submission now offers Stop upload. It cancels the active request and retry work while preserving the original report and screenshots for an explicit retry. Late responses cannot overwrite a stopped or replaced attempt. Explicit retry replaces a cancelled job that is still settling. The dedicated reporting connection uses HTTP/1.1 as a compatibility mitigation for the four-image timeout; this candidate still requires real upload verification.

The Linux file manager explicitly opens a new window in the current project directory. On Samsung, this produced a visible workspace in the existing graphical session after the default launch had left a background process and a black viewport. The normal launcher action in this candidate still requires device acceptance.

Targeted Full/Play compilation, six upload checks and the actual generated Linux launcher-script regression passed. Unchanged native production evidence is reused. No new model or media-generation call was made. This is an intermediate release; cross-App workflows, condition scheduling, project GUI reuse and component lifecycle remain under acceptance. Original failures remain recorded. Oversized individual history entries fail explicitly; complete task export remains available. Global visual refinement is deferred.
