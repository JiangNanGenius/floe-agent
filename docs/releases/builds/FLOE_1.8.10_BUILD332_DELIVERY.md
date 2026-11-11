# Floe 1.8.10（332）中间版交付记录

日期：2026-11-12（Sydney）。源码固定为 `22f8c31e7cbe86febe150c24284d9fd2fdf50ee8`，不可变标签 `v1.8.10`，annotated tag object `9510c947b92534a3ad1e53bac1d9e3d8b49f6ab0`。

| 渠道 | 实际状态 |
| --- | --- |
| 内部 TestFlight / Floe QA | Apple `VALID`、未过期、`IN_BETA_TESTING`，独立 GET 已确认可安装 |
| [GitHub 1.8.10](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.10) | stable/latest，实际 arm64 iOS 无签名 IPA 与 SHA-256 配对、源码标签和远端字节严格读回通过 |
| [Feather 更新源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json) | 同一次发行中 awaited workflow 完成；版本、源码、实际下载 URL 与 SHA-256 已读回 |
| [公开 TestFlight / publictest1](https://testflight.apple.com/join/nz6qeT2J) | 已提交一次，`pending_review` / `WAITING_FOR_BETA_REVIEW`；不代表已可公开安装 |

正式 App Store Build315 的原安排未调整；没有重新提交已撤回公测的331。各渠道状态独立，不以签名、上传或送审代替可安装状态。

## 本次内容与验证

本次修复编辑器助手与普通聊天的归属及独立历史、失败工具卡片的手动收起、回复操作栏、任务状态与流结束、会议录音和说话人链路、工具箱显示与操作，并纳入就绪的图片编辑器更新。独立二维 CAD 隐藏不适用的三维／加工／仿真入口；三维草图锁定平面视角，支持 DXF/DWG 及本 App 二维项目草图导入。

实际 Xcode 27.2（27B52）App 编译、严格开发包封闭性检查与设备 Release 归档通过。27项定向 App 行为测试实际通过、0跳过；该逻辑证据来自SDK07，随后仅移除回复按钮、调整导入确认位置，测试源码和相关逻辑保持不变，SDK08／09均重新实际编译。没有把复用证据说成重新执行。

完整 App 已操作验证：二维入口与导入菜单、原生矩形、导入当前三维草图、一次撤销／重做、退出恢复三维相机；在已有实体顶面建立草图、绘制并保存重开，确认图形仍在该面。新回复栏移除“复制”右侧的“保存到手记”。已有基准面的支撑链经代码核对，新增专项用例未执行。没有宣称实体面动态关联、物理设备语音准确度或完整页面矩阵已验收。

安装包与全部19份原始调试符号在归档后立即保全；后续签名、上传、GitHub／Feather均复用同源产物，没有为分发重编 App。本轮模拟器使用完成后已关闭；独立研发继续使用各自锁与范围。两处重复暂存已清理，当前产物、符号、原始失败及恢复证据保留。

公开无签名 IPA SHA-256：`b8c18f062891e62a1a359c63301612df5e46c4f1b5d026c19ec68ffff42d61e5`。大小：915,566,752 bytes。

## 后续范围

本次是已确认修复的中间版，不自动结清[原整合计划](../../FLOE_IOS_UPDATE_PLAN_20261111.zh-CN.md)。Linux GPU／Blender、后续电子元件库、游戏与室内预研仍按各自源码和真实验收结果收件，不计入332。新版公开可安装状态以 Apple 后续审核结果为准。
