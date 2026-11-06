# Android 0.1.0-alpha.41

CAD／三维查看器显式使用填满父容器的原生布局，避免 WebView 按内容测量时将网页百分比高度压成0。保留真实画布、几何、帧与任务归属检查；视口失败详情增加有限数值尺寸，便于诊断。

## Known issues / 已知问题

这是 N01–N08 中间候选。前两份私有候选仍返回 emptyViewport，已确认原生1080×2107、网页窗口360×702，而网页body／画布容器高度为0。仅等待原生测量未解决，相关等待已移除；当前显式布局修复尚待本包编译与三星实测，不宣布 CAD 或离线预览已修复。手机多步、条件触发、跨项目隔离及其他既定场景继续推进。不重放付费图片／视频生成。

## English

CAD/3D WebViews explicitly fill their native parent instead of using content-based height, which can collapse percentage-height HTML. Real-canvas, geometry, frame and task ownership checks remain authoritative. Viewport failure details include bounded numeric geometry.

This is an intermediate N01–N08 candidate. The first two private candidates still failed with emptyViewport: native bounds1080×2107, page window360×702, but body/view height0. Waiting for native measurement did not fix it and that wait was removed. Explicit layout sizing still needs compilation and Samsung acceptance; CAD and offline preview are not claimed fixed. Phone multi-step automation, system conditions, project isolation and other agreed scenarios continue. No paid media generation is replayed.
