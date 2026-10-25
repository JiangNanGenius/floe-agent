# Floe 1.7.56（297）语音播放短修复 / Voice playback repair

日期 / Date: 2026-10-25.

## 修改与边界 / Changes and limits

- 连续语音按输入和输出音频格式复用转换器，避免地址字符串造成逐块重新创建；新回答重置转换历史。
- 以实际入队的输出帧数记录播放进度和结束条件，覆盖整数及非整数采样率转换。
- 区分真实队列背压、暂时不可播放和转换失败；已被转换器接收但暂未输出的音频不重复发送，持续不可播放时及时提示。
- 本轮检查的是语音聊天共享播放路径。语音界面的实际帧率、真机听感和真实麦克风打断效果未由模拟器测试证明。

The shared continuous-voice output now reuses resamplers by format, accounts for actual scheduled frames, and distinguishes backpressure from engine/conversion failures. Buffered input is consumed once. This is not a physical-device frame-rate or acoustic-interruption acceptance claim.

## 验证 / Qualification

- Xcode 27.1（27A9275）：完整 App 与 AppTests 的 Swift 6 arm64 Simulator 对象编译通过。
- 复用唯一既有 iPad Simulator：83 项相关 App-host 测试通过，0 失败、0 跳过，包含 6 项新增转换、帧数和拒绝处理回归。测试后关闭实例，保留应用和数据。
- 首轮 83 项中有 1 项新增测试失败：测试将帧增量误作累计帧数；修正输入后保留原断言重新通过，原始失败记录保留。
- 原生转换探针和 App-host 转换测试验证格式复用、小音频块、非整数转换及暂存零输出；麦克风与模型输入使用测试替身，不代替真实语音验证。
- iPhoneOS 27.1 Release 归档及本地分发包核验通过，立即保留恢复包和 14 份匹配符号；分发复用同一产物。

Full Swift 6 compilation, all 83 selected tests, and the single device Release archive passed. Native resampler tests are separate from physical microphone, audible playback and UI performance acceptance. The original fixture failure remains recorded.

## 不可变产物 / Immutable delivery

- App 源码 / Source: `aaa92fd5be4734fb55fab59cca0193b8ebb9be60`。
- 标签 / Tag: `v1.7.56`，annotated object `d2bbd375116db5c20b3578d894d63ff93958b0e2`。
- [签名与内部交付 40161830994](https://github.com/JiangNanGenius/floe-agent/actions/runs/40161830994)：成功；独立回读 Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`，中英文测试说明一致。
- publictest1 只提交一次；重新打开准确构建及列表，确认 297 为“正在等待审核”、90 天有效期、Floe QA 与 publictest1 均已关联。外部尚未确认可安装。
- [稳定无签名 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.56)与[同次发布及等待完成的 Feather 任务 40162894613](https://github.com/JiangNanGenius/floe-agent/actions/runs/40162894613)成功。独立下载验证标签、源码、真实 arm64 iOS 可执行文件、latest 指针、侧车摘要及在线 Feather 的链接、版本、源码和摘要。
- `Floe-Agent-1.7.56-build297-unsigned.ipa`：812,218,253 bytes；SHA-256 `b367aa2e095dc5a4f469099174cab04c483af7893f0b6bd8fa67e41891170a0f`。

Internal installation and verified unsigned/Feather delivery are available. Publictest1 is waiting for Apple review; that is separate from external installability. The release tag was not moved.

## 收尾 / Cleanup

源码已推送 main，本轮已合并分支已清理。两个分发消费者及独立回读均成功后，删除本轮临时传输草稿并确认草稿与临时引用返回 404。

移除本轮测试／探针／Release 缓存、归档和分发暂存副本，移除分配量合计 15.69 GiB，各清理点实测可用空间增加合计 11.84 GiB；分配量和实测可用空间不等同，APFS 共享区块等会影响可用空间增量。保留当前无签名安装包与摘要、原始恢复传输包、14 份符号、成功／失败证据，以及既有回滚版本、共享依赖和模拟器数据。

Merged source and scoped branch cleanup are complete. Temporary transport was removed only after both consumers and independent readback passed. Required recovery artifacts, symbols, original failures and Simulator data remain protected.
