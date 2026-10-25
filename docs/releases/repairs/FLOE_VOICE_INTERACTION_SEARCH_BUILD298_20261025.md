# Floe 1.7.57（298）语音交互与统一搜索 / Voice interaction and unified search

日期 / Date: 2026-10-25.

## 修改 / Changes

- 语音结束判断共同检查真实麦克风静音与转写稳定性；持续说话及较短停顿继续等待，保留明确发送、静音、恢复与旧回合隔离。
- 暂停状态约束后续音频块及音频图恢复，保留原有转换器复用、实际播放帧计数和取消收尾。
- 中心图标平滑呈现真实音量，活跃状态以 60 Hz 为目标，静止状态停止刷新，并记录有限的刷新与音频供给时序。
- 更早的工具记录按可见性和真实滚动请求分批加载，保留失败重试及取消隔离；聊天和画布复用同一组件。
- 专业数据集并入 `web.search` 的 `source=professional`，冻结本轮允许的账户、注册代次和工具边界。经过限定的原生查询按读取处理；通用 MCP 的原有写入审批规则保持。无可用来源时移除不可执行的搜索入口。

Voice endpointing now combines real quiet with transcript stability. Playback pauses survive new chunks and graph recovery. The orb smooths measured levels and stops static redraws. Earlier tool activity pages on scrolling; professional datasets use the same search tool with frozen account authority.

## 验证与边界 / Qualification and limits

- Xcode 27.1（27A9275）：完整 App 与 AppTests 的 Swift 6 arm64 Simulator 对象编译和 iPhoneOS 27.1 Release 归档通过。
- 复用唯一既有 iPad Simulator，21 个相关测试套件共 259 项通过，0 失败、0 跳过；测试结束后关闭实例并保留应用及数据。
- 新增测试夹具曾暴露只读系统环境值与跨模块参数初始化两处编译错误，修正为实际系统状态和公开 JSON 参数解码后完成编译；原失败记录保留。
- 实际 SwiftUI 宿主图标测试使用合成音量输入，记录 24 个有效间隔、最大 67 ms；这些数据反映模拟器刷新节奏，不能证明真机 GPU 帧率或实际声音流畅度。
- 已授权的 M4 iPad 从 TestFlight 自动更新并实际启动 298，正确展示本版说明。通过原生文件夹导入安装 `brand-guidelines` 与 `jupyter-notebook`，均显示外部来源并启用；从设备读回的 12 个输入文件摘要全部一致。
- 无脚本 `brand-guidelines` 已完成实际读取与回复，配色、字体与原文一致。带脚本 `jupyter-notebook` 的安装和读取成功，但本次任务未完成脚本及模板在 Linux 环境中的访问，已停止尝试并保留记录，资源传递断点另行修复；不把安装成功计为脚本执行通过。
- 上述 Skill 验收不证明真实麦克风、听感或打断质量已全部验收。

All 259 selected App-host tests passed with no skips; full Swift 6 compilation and the device archive passed. The hosted orb probe uses synthetic levels and does not establish physical audio or GPU performance. Both real external Skills installed on the authorized iPad, with all 12 input hashes matching device read-back. The scriptless Skill returned the correct palette and typography. The scripted Skill loaded, but the task did not complete access to its script and templates in Linux; original evidence is retained for a separate resource-delivery fix. Installation is not counted as execution acceptance.

## 不可变交付 / Immutable delivery

- App 源码 / Source: `3d33adf64db55832ec2aa2f42ad202abef51c151`。
- 标签 / Tag: `v1.7.57`，annotated object `ee89b62c627eb6d542976da9deda082cb591d01d`；未移动标签。
- [签名与内部交付 40175902594](https://github.com/JiangNanGenius/floe-agent/actions/runs/40175902594)：独立回读 Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`，中英文说明均已核验。
- publictest1 只提交一次；独立重开列表和准确构建后，298 为“正在等待审核”、90 天有效期，关联 Floe QA 与 publictest1。外部可安装尚未确认。
- [稳定无签名 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.57)和[同次发布及等待完成的 Feather 任务 40177284317](https://github.com/JiangNanGenius/floe-agent/actions/runs/40177284317)成功。独立下载核验标签、源码、真实 arm64 iOS 可执行文件、latest、摘要及在线 Feather 的实际链接、版本、源码与摘要。
- `Floe-Agent-1.7.57-build298-unsigned.ipa`：812,266,024 bytes；SHA-256 `ba85970f15288bed7046cecedf2b6180cb029221d6c4819baf798d406c0eb2a7`。

Internal installation and verified unsigned/Feather delivery are available. Publictest1 awaits Apple review; submission and external installability remain separate. Distribution reused the saved exact-source device artifact and matching symbols.

## 清理 / Cleanup

移除本轮 Simulator／Release 构建缓存、重复归档、App 副本及传输暂存，分配量合计 15.75 GiB，各清理点实测可用空间增量合计 11.89 GiB。保留无签名包与摘要、原始恢复包、14 份匹配符号、原始失败及验证证据、既有回滚版本、共享依赖和模拟器数据。

两个分发消费者和独立回读成功后，删除本轮私有传输草稿，确认草稿与临时引用均返回 404。正式 App Store 275、其他工作树及独立任务保持原状。

Scoped cleanup reclaimed 11.89 GiB measured free space (15.75 GiB allocated removal). Recovery artifacts, symbols, original evidence, rollback versions and user data remain protected. Temporary transport cleanup followed both verified consumers.
