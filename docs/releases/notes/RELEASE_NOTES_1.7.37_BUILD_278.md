# Floe 1.7.37 (278) — PiP sound and Office ink placement

Internal beta candidate. Archive, signing, upload, Apple processing and group availability are recorded separately.

## 简体中文

- 后台运行提供增强后台、画中画和录屏反馈三个独立开关；开启反馈会开启画中画，关闭画中画也会关闭反馈。两者共用一个窗口，没有有效反馈时继续显示任务进度。
- 画中画下增加声音与播报子菜单，提供雨声、棕噪声、音量、任务播报、提示音和有界试听。偏好会保留，背景音初始开启且音量为零，音量调整作用于正在播放的声音。暂停、任务结束、关闭画中画和录音时协调音频。
- 改进 Office 实时笔迹及手记缩略图，修正 Word 提笔后的落点偏移，包括连续快速书写；保留原生矢量保存和文档原内容。

本地 Xcode 27 完整 App／测试宿主编译通过。后台与声音的 65 项生命周期／偏好检查、2 项真实音频解码／零音量播放检查及 2 项设置 UI 检查通过。新原生组件的五项完整 App 严格落点检查通过，包括 Word 普通、缩放后、连续三笔及 Excel／PPT 对照，未放宽 4 CSS 像素阈值。真实 UIKit 双指缩放测试仍失败，继续修复，不宣称画笔缩放已完成。真实 Pencil 压力、手掌防误触、手感和设备后台／锁屏效果尚待真机验收。

## English

- Background execution has separate Enhanced background, Picture in Picture and Screen feedback switches. Feedback enables PiP; disabling PiP disables feedback. Both content types share one window, showing task progress whenever valid feedback is unavailable.
- Sound and narration under PiP provides rain, brown noise, volume, task narration, cues and bounded preview. Preferences persist; ambient sound initially runs enabled at zero gain, with live volume changes. Playback coordinates pause, task completion, PiP closure and dictation.
- Improves live Office ink and Notes covers, correcting Word stroke placement after lifting the pen and during rapid consecutive contacts. Native vectors and original document content are preserved.

Local Xcode 27 full-App/test-host builds passed, together with 65 lifecycle/preference cases, two real decoder/zero-volume player checks and two settings UI checks. Five full-App strict placement cases passed for Word ordinary/zoomed/rapid contacts and Excel/PPT controls, retaining the 4 CSS pixel tolerance. Actual UIKit two-finger zoom still failed and remains under investigation; drawing-mode zoom is not declared complete. Physical Pencil pressure, palm rejection, feel and device background/lock acceptance remain outstanding.
