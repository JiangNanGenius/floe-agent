# Floe 1.7 截图留存

这些截图来自本轮专用 iOS 模拟器中的最小媒体工作台 App，素材为 FFmpeg 合成测试图与音频，不含用户私人媒体。截图证明当时的界面状态；功能测试与真机验收单独记录。

| 文件 | 用途 | 状态 |
|---|---|---|
| [当前工作台](native-media-workbench.png) | 双语使用指南、README 与产品介绍 | 可用于开发功能说明；已核对素材播放、控件布局和恢复的剪辑区间 |
| [布局修复前](native-media-workbench-before-layout-fix.png) | 保留复现与修复对照 | 仅作历史证据，不作为当前功能宣传图 |
| [编辑模型测试](native-media-editor-model.json) | 保存重开与真实导出证据 | 单独记录尺寸、帧率、剪辑/变速、可播放性和源文件保留 |

后续截图记录对应提交、设备/模拟器、素材来源及实际完成的验收范围。正式版说明只使用与分发构建一致、经过核对的截图，不把旧开发画面当作新版验收结果。

## Build 254 iPhone 手记封面截图

[iPhone 重启后手记封面](notes/build254-iphone-cover-relaunch.png)来自 `v1.7.13` 源码 `97b130b8245b04c5f88ca7e3f3813cb8bc7a6a31` 的 SDK 27 iPhone 模拟器完整 App 测试。素材均为合成文件，图中 Word 摘要和 DXF/DWG 实际几何图形在终止并重启 App 后仍可见。`testNotesLibraryCardsShowRealContentCovers` 通过；同一套件后续的工作区导入用例在 XCTest 点击已显示的菜单行时失败，见 [Build 254 候选记录](../../releases/testflight/TESTFLIGHT_1.7.13_CANDIDATE.md)。原始截图、录屏与日志保存在云端工件 `sdk27-notes-ui-1.7.13-build254`（ID `11307209604`）。此图只证明该模拟器当时的可见封面，不代表整个发布门禁或真机验收通过。

## Build 253 手记完整 App 模拟器截图

[iPad 重启后手记封面](notes/build253-ipad-cover-relaunch.png)来自 `v1.7.12` 源码 `68a69d868b4cf9134c84236f97476740d1890f16` 的本地 iOS 27 iPad Air 13-inch (M4) 完整 App UI 测试。Word、PDF、DXF、DWG、导图、手写页、PPT 和 Excel 均为合成验收素材；图中 DXF/DWG 显示实际几何图形。`testNotesLibraryCardsShowRealContentCovers` 在打开、返回、终止并重启 App 后通过（1 项、0 失败）。原始 xcresult、日志与附件保存在忽略的 `Local/Private/build253-local-evidence/`。这张图只证明该本地模拟器当时的画面；云端独立资格检查和真机体验另行核验。

## Build 248 手记完整 App 模拟器截图

[iPad 重启后手记封面](notes/build248-ipad-cover-relaunch.png)来自 `v1.7.7` 候选源码在 iOS 27 iPad Air 13-inch (M4) 模拟器的完整 App UI 测试。图中 Office、导图、手写页及 DXF/DWG 均为合成验收素材；对应 `testNotesLibraryCardsShowRealContentCovers` 在重命名、打开/返回、终止并重启 App 后通过（1 项、0 失败）。原始 xcresult、28 个附件及人工截屏保存在忽略的 `Local/Private/build248-local-cover*`。此图仅证明该模拟器当时的可见状态，云端独立资格检查与真机体验另行核验。

## Build 243 完整 App 模拟器截图

[CI run 37124262937](https://github.com/JiangNanGenius/floe-agent/actions/runs/37124262937) 使用 `v1.7.2` 的源码 `c5a1ffbc`，在 `ci-artifacts`（ID `11276063883`）中保留 106 张完整 App 截图：手记 iPad/iPhone 各 30 张，IDE iPad/iPhone 各 23 张。四组 UI 用例均通过；iPhone IDE 首次在用例启动前遇到 XCTest 测试进程崩溃，保留失败证据后一次受限重试通过五项用例。截图原始清单均未标记为失败关联；这些是模拟器证据，真机体验仍待验收。仓库本地的忽略目录 `Local/Private/release243/evidence/screenshots/ci-37124262937/` 保存原图、索引与逐文件 SHA-256 清单。

## 可视化编辑库接入

[native-visual-video-editor.png](native-visual-video-editor.png) 为固定 VideoEditorKit 源码在专用 iOS 27 模拟器中加载 6 秒合成素材后的界面。属于开发截图，未进行完整触控和真机验收。

[字幕对照帧和成片](video-editor-captions/) 来自 2 秒纯色测试视频；字幕显示前、中、后的像素检查已通过。

## General appearance and execution frames

[Native interface evidence](interface/README.md) retains day/night/automatic
appearance and expanded/folded tool-batch screenshots from passing UI tests.
These are synthetic component fixtures, not a full application or device run.

## 手记输出图的说明文档用途

中英文使用指南引用 `notes/ipad27-export-text-and-ink.png`，展示重新读取的 PDF 文字与笔迹产物。它是组件导出结果，不是完整应用页面。导图横屏裁切、空白页面等失败截图继续保留在 `notes/render-regressions-*`，不用于新版产品介绍。新版本完整页面截图需记录最终提交与双端设备后补入。

`notes/verified-455/ipad-landscape-pdf-map.png` 来自 `34742130370` / `4550b6d` 的 iPad SDK 27 原生 UI 测试。已检查可见的 PDF 页首与独立导图小窗，并加入双语使用指南。SDK 27/26 的 iPad/iPhone 四种组合各 10 项测试通过；这里只展示组件场景，不声称是完整 App 或真机画面。

`notes/verified-455/iphone-portrait-pdf-map.png` 是同次 SDK 27 iPhone 17 Pro 模拟器通过的 UI 测试截图，已人工查看并原样留存，双语指南说明其为组件场景。
