# Floe 1.7 截图留存

这些截图来自本轮专用 iOS 模拟器中的最小媒体工作台 App，素材为 FFmpeg 合成测试图与音频，不含用户私人媒体。截图证明当时的界面状态；功能测试与真机验收单独记录。

| 文件 | 用途 | 状态 |
|---|---|---|
| [当前工作台](native-media-workbench.png) | 双语使用指南、README 与产品介绍 | 可用于开发功能说明；已核对素材播放、控件布局和恢复的剪辑区间 |
| [布局修复前](native-media-workbench-before-layout-fix.png) | 保留复现与修复对照 | 仅作历史证据，不作为当前功能宣传图 |
| [编辑模型测试](native-media-editor-model.json) | 保存重开与真实导出证据 | 单独记录尺寸、帧率、剪辑/变速、可播放性和源文件保留 |

后续截图记录对应提交、设备/模拟器、素材来源及实际完成的验收范围。正式版说明只使用与分发构建一致、经过核对的截图，不把旧开发画面当作新版验收结果。

## 可视化编辑库接入

[native-visual-video-editor.png](native-visual-video-editor.png) 为固定 VideoEditorKit 源码在专用 iOS 27 模拟器中加载 6 秒合成素材后的界面。属于开发截图，未进行完整触控和真机验收。

[字幕对照帧和成片](video-editor-captions/) 来自 2 秒纯色测试视频；字幕显示前、中、后的像素检查已通过。
