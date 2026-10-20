# 1.7.41（282）本地验收与交付 / Local verification and delivery

日期 / Date: 2026-10-21（Australia/Sydney）。本记录为已完成的交付，不代表所有系统自动化组合或真实 Pencil 手感已验收。

## 固定源码与产物 / Immutable source and artifacts

- 不可变标签 `v1.7.41`，源码 `268e21cb8aaaf13c92f3b35a07e57ae1071126ee`，已推送合并 main。后续文档及 Feather 提交不会改变该标签。The immutable tag binds the released source; later documentation/feed commits do not move it.
- Xcode 27A266a／iphoneos27.0，本地 ARM64 Release archive 成功；主 App 与屏幕共享扩展均为 1.7.41（282），原始包和全部 11 组匹配符号已保存。Local device archive succeeded; the App, extension, original package and all matching symbols are retained.
- 模拟器实际 App 验收源码 `672d843a0b505359d6a44af30903cc296afb4fc4` 至冻结源码只有文档变更；本轮设备归档从冻结源码生成。六个 Run/Start/Status/Wait/Text/Cancel Intent 的归档导出元数据可发现；这不替代系统分发实跑。The qualified App source differs from the frozen source only in documentation. Exported discoverability is distinct from system dispatch.

## 实现与本地检查 / Changes and local checks

当前页未保存笔迹进入实际助手请求，同一手记由编辑器提交后可新增数字、求和并保存回读；移除永久魔棒命令表单，修复实时缩放和落笔预览。C 提供同一次运行的身份、状态、有限等待、取消和精确最终文本，保留旧 Run 的 String 返回值。文件结果及真实定时接续 D／S4。Current Office ink reaches the assistant request; editor-owned save and numeric edits round-trip. Commands is removed, live pinch/ink is repaired, and exact-run status/text actions preserve legacy compatibility. Files and scheduling remain in D/S4.

- 完整 App／AppTests／UITests 编译通过。Office 11 项实际原生引擎与 10 项单元格编解码通过，修复后的 1 项真实发送通过。Two animated UIKit pinch cases with the assistant sidebar also passed, with in-flight frames and recordings inspected.
- C 首次 142 项中 137 通过、5 失败、0 跳过；修正夹具后 13 项 Intent 与 3 项实际修复／SQLite 保存证明补验全部通过，0 跳过。保留无关通过及原失败证据，没有重跑全矩阵。C retains the unaffected original passes and failure evidence; focused repairs passed without a repeated historical matrix.
- 固定 iPad 模拟器已关闭，未创建／清空／重置设备。真实 Pencil 压力、手掌误触、设备手感及联网模型的手写识别准确率未由这些检查证明。Physical Pencil behavior and network-model handwriting accuracy remain separate.

详细证据 / Detailed qualification: [Office](../repairs/FLOE_OFFICE_ASSISTANT_LIVE_INK_20261021.md) · [S3-C](../repairs/FLOE_SHORTCUTS_S3C_20261021.md)。

## 内部 TestFlight / Internal TestFlight

复用已保存的本地设备包，仅做云端签名／上传，没有云端 App 重建：[上传和内部准备](https://github.com/JiangNanGenius/floe-agent/actions/runs/39478307360)成功；[独立只读回查](https://github.com/JiangNanGenius/floe-agent/actions/runs/39482127761)确认 1.7.41（282）`VALID`、未过期、`APP_STORE_ELIGIBLE`，只关联现有内部 Floe QA，`IN_BETA_TESTING`——**内部可安装**。The exact local artifact was signed/uploaded without rebuilding; independent readback confirms availability in the existing internal group.

Apple 的处理记录曾为 PROCESSING、errors/warnings 为空；保留当时记录及成功回执，没有重复上传。未新增 282 外测提交，未重新查询／提交 281 外审，275 正式 App Store 提交保持不变。Earlier processing evidence is retained; no duplicate upload or new external submission was made.

## 稳定无签名 Release 与 Feather / Stable unsigned Release and Feather

[同一次发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/39479921433)从不可变标签执行：同源无签名打包 → Actions 来源证明及验证 → stable/latest 发布 → 严格发布后回读 → job-level awaited Feather 更新及实时回读，全部成功。[稳定最新版 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.41)是 `draft=false`、`prerelease=false`。This canonical flow completed attestation, stable publication, strict readback and the awaited Feather job.

公开资产仅为无签名 IPA、`.sha256` 与精简 `PROVENANCE.json`；未公开 raw ZIP、签名资料、符号或私有规范化报告。

- [Floe-Agent-1.7.41-build282-unsigned.ipa](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.7.41/Floe-Agent-1.7.41-build282-unsigned.ipa)，800,954,813 bytes。
- SHA-256：`7fac824e544f0c75d52d69317e71616799c2ddfe090836eddc208cc6b50f0dff`；[校验文件](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.7.41/Floe-Agent-1.7.41-build282-unsigned.ipa.sha256)。
- `verify_github_release_publication.py` 的完整 staged 审计通过：精确 tag/ref/object → source、远端摘要／大小、真实 arm64 iphoneos 可执行文件、最新版指针。主负责人另取公开元数据、校验／来源文件并运行独立核验，与完整审计一致；没有以元数据检查冒充第二次 IPA 全字节审计。
- [实时 Feather 源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)独立回读：1.7.41／282、原下载地址、上述源码／大小／摘要全部相同。Unsigned installation requires the user's own signing; this is separate from TestFlight.

## 合并、清理与接续 / Integration, cleanup and continuation

本轮任务分支本地与远端已删除；Feather 提交已快进接回 main。私有传输 draft 及其标签已删除并回查 404，公开源码标签保持不变。模拟器 booted 列表为空。Merged task branches and the private transport are removed; the immutable public tag and simulator data remain intact.

导出并核对日志后，删除本轮三个内部缓存，实测可用空间增加 **5,706,735,616 bytes（5.31 GiB）**；三个外部展开副本清理后实测增加 **1,898,262,528 bytes（1.77 GiB）**。外部 du 为约 5.46 GiB，APFS 共享使实际回收较小，未将其当作实际增量。此前原生／模拟器缓存清理按原记录单独保留，不重复计数。原始设备 ZIP、重传 transport、签名私有 IPA、11 组符号、archive 小元数据、回滚及全部原失败／资格证据保留，可恢复而无需为分发重建。

C 和本轮 Office 从活动目标移除。下一包 D 固定同次运行的真实文件归属／稳定快照／摘要及错误恢复，再接 S4；D／S4 合用下一次必要的 App 集成和发包，仅补验受影响行为，不把已通过 C 重启为新一轮全套验证。C is complete; file results and scheduling continue under bounded scope and shared integration checks.
