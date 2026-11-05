# Floe 1.7.70（311）交付状态

更新日期：2026-11-05。安装包不可变来源：`8b79471dc458ed005e6dc9fccd13e27243614dca`，标签 `v1.7.70`。后续文档和分发源提交不改变该标签或安装包。

## 本轮变化

- 本机执行切换为共享 ARM64 Linux，CPU、内存在执行环境中统一设置；保留任务、项目及依赖的明确归属。
- 修复受管理任务工作区重定位、共享项目中的 Skill 配置归属，以及原生 Shell 默认环境被误判的问题。
- 完成官方签名 Skill 的 ARM64 组件准备、任务间复用和环境重启后的重新核对。
- 增加恢复初始状态、重新下载及统一运行状态。恢复重置环境和依赖，保留项目文件、聊天、已安装 Skill；不迁移旧 RISC-V 二进制依赖。
- Mac 配对入口、重试和状态改进保留在本版；iPad 不显示 Mac 连接设置。Bridge 独立程序的实际配对验收与发布单独记录。

双语更新说明：[Release notes](../notes/RELEASE_NOTES_1.7.70_BUILD_311.md)。

## 编译与行为证据

| 范围 | 实际结果 | 边界 |
| --- | --- | --- |
| 最终 App 归档 | Xcode 27.1（27A9275）、iPhoneOS 27.1、Swift 6，Release 对象编译、链接及 archive 成功；全部 5 个 App／扩展版本一致 | 使用最终来源 8b79471dc，未以 typecheck 代替编译 |
| 官方 Skill 完整 App 流程 | 指定 iPad 模拟器执行 15 项测试、4 个套件，全部通过，0 跳过 | 行为测试来源 1783a6054；最终提交仅新增审核文案，App、模块、测试、工程及资源身份逐项相同 |
| Skill 与依赖复用 | 实际 `skill.manage` 更新、签名安装读回、`exec.shell(skillID:)` 执行 ARM64 二进制；同一项目中两个任务复用准备结果，重启后重新核对 | 合成引擎扫描输入与真实网页捕获分开，不将测试夹具算作完整网页分析 |
| 网页服务与回环 | 真实客体启动服务，转发后 WebKit 读到对应 HTML／CSS 字节，语义点击及原生捕获完成，取消后端点关闭 | 复用此前本轮实际 App 验证，未重复启动未变化的链路 |
| 原生网页扫描 | 真实 WebKit 捕获并交付给 Impeccable | 引擎最终返回 inconclusive，如实保留；不宣称所有页面规则通过 |
| 隔离及恢复 | 真实客体检查环境重置、项目隔离、共享缓存、CPU 配置；App 中检查任务归属与代次变化 | 环境隔离不宣称为原生代码安全沙箱 |
| iPad 界面 | 状态从准备中转为已就绪／未运行，检查共享资源、恢复及重新下载菜单、文件保留提示，Mac 区域隐藏 | 没有对用户现有环境执行重置；原有未发送草稿与附件保持 |
| 输入框 | 相关实现与交互测试和 310 完全相同，复用已有换行、光标、三整行与展开检查 | 未冒充本次新增长输入测试；未使用用户手机 |

App 行为测试使用 `xcodebuild test-without-building`，关闭并行模拟器，限定以下测试：

```text
FloeAppTests/SubagentSimulatorExecutionTests/impeccableARM64OfficialWorkflow()
FloeAppTests/SkillGitHubDownloadTests
FloeAppTests/SkillConfiguredShellSessionTests
FloeAppTests/TaskEnvironmentOwnershipTests
```

保留了首次下载超时、错误测试绑定、受保护 Shell 变量及项目归属失败的原始记录；修复后执行相关测试。模拟器用后关闭，没有清除用户数据。

## 分发状态

| 渠道 | 核验状态 |
| --- | --- |
| 内部 TestFlight／Floe QA | Apple 上传完成；独立读回 `VALID`、未过期、`IN_BETA_TESTING`，中英文测试说明一致 |
| GitHub | stable、latest、非 draft、非 prerelease；公开 IPA 实际下载，来源、tag 对象、摘要、大小及 arm64 iPhoneOS 可执行文件通过发布核验 |
| Feather | 同一发布流程等待的下游任务成功；实际读回地址、版本、来源、摘要、大小与 GitHub 资产一致 |
| 公开 TestFlight／publictest1 | 尚未提交成功。更新审核说明的 Apple API 请求返回 403；保留失败，需要恢复网页登录后继续，不算作审核拒绝或公开可安装 |
| 正式 App Store | 尚未替换。需先读取现有提交状态；仅按用户授权在未进入审核时替换，不自动公开发布 |
| Bridge 1.1.1 | Developer ID 签名、公证、装订及 Gatekeeper 通过；更新签名对最终 DMG 验证通过。实际配对验收待完成，分发草稿未公开，更新源未切换 |

公开 App 安装包：

- [GitHub v1.7.70](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.70)
- 文件：`Floe-Agent-1.7.70-build311-unsigned.ipa`
- 大小：`821346303` 字节
- SHA-256：`e215c4677091e348c08e0e2856b252e685c0f1f8f789ed2a5b479837ccbf7615`
- 无签名包需用户自己的签名配置，与 TestFlight 签名分发分别核验。

上传／发布记录：

- [Apple 签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/41937799704)：成功。
- [Apple 独立读取](https://github.com/JiangNanGenius/floe-agent/actions/runs/41941124932)：成功。
- [GitHub 与 Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/41941586264)：成功。首次 Feather 网络连接被重置，保留失败后仅重跑失败的下游；没有重新编译或替换安装包。
- [公开 TestFlight 提交](https://github.com/JiangNanGenius/floe-agent/actions/runs/41941701969)：API 权限失败，未报作完成。

## 源码与清理

主目录回到 main，已合并且无人使用的本轮旧分支已移除；其他线程未完成的分支和修改保留。旧根目录修改另存恢复材料，没有覆盖到 main。

TinyEMU 上游基线、许可证、Floe 改动及历史实验来源已移交独立 [floe-tinyemu](https://github.com/JiangNanGenius/floe-tinyemu) 仓库并逐项核验；本地退役实现、旧镜像及缓存按精确范围清理，Git 历史与用户数据保留。

本轮清理分别记录实际磁盘变化：旧安装包／重复 App 36 项约 28.6 GB，指定模拟器旧镜像、系统层和缓存约 6.1 GB，311 归档后的派生构建目录约 4.2 GB。原始符号、证据、当前 311 安装包和恢复材料保留；不同卷和不同时段的测量不作为单次总量承诺。

## English status

Build 311 is compiled, archived, uploaded and available in the existing internal Floe QA group. The stable/latest GitHub IPA and the awaited Feather feed were independently verified against the immutable source and actual downloaded bytes. Public TestFlight submission remains blocked by an Apple API permission error; the conditional App Store replacement and real Bridge pairing acceptance remain pending. No production App Store release or public Bridge update has been claimed.
