# Floe Agent 1.8.25（346）交付记录

2026-11-14，内部 TestFlight、正常 GitHub stable/latest 与 Feather 均已实际核验。

- 固定源：`0a6dc46b9f5cbe78e02e1730be9b342a5557f879`；不可变标签：`v1.8.25`。
- 标签对象：`ae53c621cef0e5c2e48ff6ca4476372a65383900`。
- 工具链：Xcode 27.2（27B52），iphoneos27.2，arm64；App 与四个扩展均为 1.8.25／346。

| 渠道 | 实际结果 |
| --- | --- |
| 内部 TestFlight | [签名及内部分发](https://github.com/JiangNanGenius/floe-agent/actions/runs/43575682995)成功；另经独立 Apple GET 确认为 VALID、未过期、Floe QA IN_BETA_TESTING。 |
| GitHub | [v1.8.25](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.25)为正常 stable/latest。实际下载未签名 IPA，版本、iOS 设备架构、来源、大小及摘要严格核对通过。 |
| Feather | [正常发布与 awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/43577549220)成功；在线源的新版本及旧客户端入口与实际公开包一致。 |

公开 IPA 为 649,780,098 字节，SHA-256：`fecd22f3022dc2cb195bd1f4a1c00c97824b94f50805c34b1cc35187fe25cf94`。GitHub／Feather 包需要使用者自行签名。

本版增加字体作品单项删除、多选、全选与批量管理，完整显示内置及导入字体，并保护内置字体；同时纳入首轮工具暴露、聊天／计划／智能体边界、按需本地工具定义，以及按实际进展判断工具目录停转的修复。详见[双语更新说明](../notes/RELEASE_NOTES_1.8.25_BUILD_346.md)。

本机实际 `xcodebuild archive`（FloeAgent／Release／generic iOS／6 jobs）成功，用时 925.43 秒；App 与全部 19 份符号在后续检查前保存。规范封包、运行时审计、原生依赖与符号匹配、实际签名权限及本地 App UUID 核验均通过。签名和公开发布复用同一份本地归档，没有再次构建 App。14 项字体 App 方法及 78 项工具／模式宿主方法复用对应源码的既有通过证据，保留原始失败与来源，不作为本版手动页面验收。

本轮未安装或控制真机。手动字体页面、换机容量整理、真实 Linux 客户机清理与跨设备 Keychain 到达仍待验；不重复计算历史回收收益。独立 Game 等研究未作为本候选门槛。本线程未提交公开 TestFlight 或正式 App Store，原安排保持。
