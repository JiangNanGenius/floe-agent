# Floe 1.7.38 (279) — Meditation music and Office pinch zoom

Internal beta candidate. Signing, upload, Apple processing and installable group availability are separate delivery steps.

## 简体中文

- 画中画背景音替换为柔和的冥想钢琴氛围曲；以本地 60 秒循环播放，保留原有音量、开关、播报和提示音设置。旧雨声／棕噪声选择自动迁移。设置页保留音量与试听，音源授权可在许可证列表查看。
- 修复 Office 画笔模式下真实双指接触的缩放入口。连续书写、原生矢量保存与手记封面链路继续验收。

音乐改动在源码 1b92696e 的完整 App 编译和 45 项相关模拟器测试中通过（42 项服务／偏好、3 项真实 Apple 音频后端，0 跳过）。279 候选只增加版本元数据和内测说明。Office 的严格真实 UIKit 居中标题缩放及工具栏两项验收已在源码 07cbf3cc 通过；五项实时笔迹、落点与保存／封面检查另行通过。这些分开的测试不代表完整的“真实双指后接真实 Pencil 书写”设备验收。

仍需反馈：音乐听感、真实 Pencil 压力与手掌防误触、连续书写手感和长期后台／锁屏行为。零移动的点状笔迹尚未闭环；部分手记预览恢复提示仍在单独调查。本内测不宣称这些项目已全部修好。

## English

- Replaces synthesized PiP rain/brown noise with gentle meditation piano, bundled as a 60-second local loop. Existing volume, switches, narration and cues persist; retired choices migrate automatically. Volume and preview remain, with source credit in the license browser.
- Repairs the real two-finger entry into Office zoom while drawing mode stays enabled. Continuous writing, native-vector save and Notes cover behavior remain under focused acceptance.

The music change passed a full App build and 45 focused Simulator tests at source 1b92696e (42 service/preferences and three real Apple audio backend cases, zero skips). Candidate 279 adds only version metadata and beta notes. Two strict actual UIKit centered-title pinch/toolbar cases passed at 07cbf3cc; five live-ink/placement/save/cover cases passed separately. These independent tests do not prove a combined real-gesture-then-physical-Pencil sequence.

Device feedback remains needed for music tone, physical Pencil pressure, palm rejection, writing feel and long background/lock behavior. Stationary ink dots are unfinished, and some Notes preview recovery messages are being investigated separately. This beta does not claim those items are fully resolved.
