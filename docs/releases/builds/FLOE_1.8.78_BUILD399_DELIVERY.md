# Floe Agent 1.8.78（399）

本版修复切回 App 后的任务接续、后台状态误报、浏览器恢复和长会话相关更新。日常提问及进度工具直接执行，审批模型默认关闭思考。配对设备可同步用户附件，工作区文件的改名与删除由单独设置控制。另加入原生游戏运行、Studio 像素帧转视频、DeepSeek 流式语音播报，以及 1.4.0 图文帮助。 [双语发布说明](../notes/RELEASE_NOTES_1.8.78_BUILD_399.md)

## 构建与验证

`v1.8.78` 固定于 `05cae68a0f879e23d3348f58a290321c683955d8`。Xcode 27.2（27B52）完整 iPhoneOS arm64 Release 构建、App 及扩展版本核对、规范封包均通过。签名与发布共用同一设备产物，20 套匹配的调试符号已留存。

封包时核对了新运行库随附的隐私清单及二进制。后续打包脚本已补齐该运行库的登记，24 项封包测试通过。

- iPadOS 27.2 的 Floe App 定向回归 22 项全部通过，覆盖目标接续、后台状态、浏览器恢复、历史分页、附件同步和原生游戏存档重开。
- 合成 20,000 条任务和 81 个工作区时，侧栏分组用时中位数由 195.95 毫秒降至 5.28 毫秒，归属及排序一致。
- 内置图文帮助在模拟器 App 和设备 App 中逐文件核对。九种语言中，简体中文、繁体中文和英文的本轮新增内容齐全，另外六种语言的新增缺译段落显示英文。线上签名帮助包已经核对同一份内容。
- 实体设备间的同步仍待联调。ONS 的两个 iOS arm64 组件已编译，macOS 组件试跑完成 24 次交替启动与正常退出，iPad App 接入仍待验收。

## TestFlight

- **内部 Floe QA**。独立回读确认 399 为 `VALID`、未过期，内部状态为 `IN_BETA_TESTING`，可安装。签名 IPA 的 SHA-256 为 `84af4843080eaacb57669ed2a0102096fb912bef42a6642152314a8520578bde`，签名包与本地构建的 App UUID 匹配。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45275114922)
- **公开 publictest1**。2026-11-24 09:31（悉尼时间）提交同一构建。Apple 回读为 `WAITING_FOR_BETA_REVIEW`，自动通知已开启，外部安装待审核。 [公开测试入口](https://testflight.apple.com/join/nz6qeT2J)

## GitHub 和 Feather

GitHub 最新正式 Release 的无签名 IPA 已从公开地址完整下载并校验 GitHub 构建证明。在线 Feather 源的版本、构建号、源码、下载地址和文件摘要均匹配。IPA 为 736,117,257 字节，SHA-256 为 `8ae530ca4513639996b29bd254fc835312a3cabb6988d48cdde8367e9ecab2ca`。 [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.78) · [核验流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/45279740785) · [Feather 源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)
