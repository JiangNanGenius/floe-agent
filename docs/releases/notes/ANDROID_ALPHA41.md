# Android 0.1.0-alpha.41

CAD／三维查看器显式使用填满父容器的原生布局，避免 WebView 按内容测量时将网页百分比高度压成0。关闭预览立即释放活动会话，原生视图按请求绑定；缺少视图时也有有界失败。保留真实画布、几何、帧与任务归属检查；视口失败详情增加有限数值尺寸，便于诊断。

## Known issues / 已知问题

这是 N01–N08 中间候选。第三份私有候选已在三星首次显示4面STL，确认显式布局修复了0高度；离线重开仍卡在渲染中。当前补关闭、请求归属和缺失视图超时，尚待本包编译与三星重开实测；不扩大为全部格式或离线预览已通过。手机多步、条件触发、跨项目隔离及其他既定场景继续推进。不重放付费图片／视频生成。

## English

CAD/3D WebViews explicitly fill their native parent instead of using content-based height, which can collapse percentage-height HTML. Closing clears the active session, surfaces bind to their exact request, and a missing surface also fails within a bound. Real-canvas, geometry, frame and task ownership checks remain authoritative. Viewport failure details include bounded numeric geometry.

This is an intermediate N01–N08 candidate. The third private candidate displayed the four-triangle STL on Samsung, confirming the height fix. Offline reopening still stayed in Rendering. Close/request ownership and missing-surface timeout repairs now require compilation and Samsung reopening acceptance; other formats and offline preview are not claimed passed. Phone multi-step automation, system conditions, project isolation and other agreed scenarios continue. No paid media generation is replayed.
