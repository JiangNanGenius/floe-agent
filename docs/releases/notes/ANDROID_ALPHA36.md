# Android 0.1.0-alpha.36

Linux 文件管理器启动时使用任务 Shell 的绝对项目路径。上一版的相对路径虽然返回启动回执，三星仍显示黑屏；同一会话使用绝对项目路径后已实际显示工作区。本候选将补正接入正常启动按钮，安装后继续实测。

反馈上传保留停止、明确重试和迟到回调隔离；撤掉未奏效的 HTTP/1.1 限制，使用默认连接协商。支持慢速上行的有限等待：读写空闲上限120秒，整次请求上限180秒。达到100%不代表服务器已接收，仍以真实回执为准。相关 Full/Play 编译、6项上传回归及实际生成的 Linux 启动脚本回归通过；未改原生组件复用生产证据。

## Known issues / 已知问题

这是 N01–N08 功能修复中间版。四图反馈在上一版仍超时，本版等待调整尚需三星真实回执验证；默认图形启动也需复测。完整跨 App 操作、条件调度、项目会话复用、组件生命周期和超预算单条历史续读继续推进。全局 UI 精修后置，不保证中间版全部功能可用。

## English

The Linux file manager now receives the resolved task shell's absolute project path. On Samsung the previous relative path produced a process receipt but a black viewport; an absolute path in the same session displayed the workspace. This candidate wires that correction into the normal launcher, pending device verification.

Feedback uploads retain Stop, explicit retry and stale-response isolation. The ineffective HTTP/1.1 restriction is removed. Read/write inactivity is bounded at120 seconds and the complete call at180 seconds to allow a slow uplink to drain. Reaching100% is not a server receipt. Targeted Full/Play compilation, six upload checks and the actual generated launcher-script regression passed; unchanged native production evidence is reused. No new model or media-generation call was made.

This is an intermediate N01–N08 release. Four-image receipt and normal graphical launch still require Samsung acceptance. Cross-App workflows, condition scheduling, project-session reuse, component lifecycle and oversized individual history continuation remain in progress. Global UI refinement is deferred.
