# Android 0.1.0-alpha.41

CAD 查看器等待原生视图挂载并获得实际尺寸后再打开本地网页，关闭或切换任务时撤销尺寸等待。继续保留现有真实帧、几何和文件校验。视口错误详情增加有限的原生尺寸，方便定位尚未解决的渲染问题。

## Known issues / 已知问题

这是 N01–N08 中间候选。Alpha40 三星合成 STL 首次预览返回 emptyViewport；本候选的原生尺寸等待尚待编译与三星实测，不能据此宣布 CAD 或离线预览修复。手机多步、条件触发、跨项目隔离及其他既定场景继续推进。不重放付费图片／视频生成。

## English

The CAD viewer waits for the native view to attach and acquire real bounds before opening its local page. Closing or changing tasks cancels pending layout admission. Existing real-frame, geometry, ownership and file checks remain authoritative. Viewport failure details include bounded native dimensions for diagnosis.

This is an intermediate N01–N08 candidate. Alpha40 failed its first Samsung synthetic STL preview with emptyViewport. This candidate still needs compilation and Samsung acceptance; CAD and offline preview are not claimed fixed. Phone multi-step automation, system conditions, project isolation and other agreed scenarios continue. No paid media generation is replayed.
