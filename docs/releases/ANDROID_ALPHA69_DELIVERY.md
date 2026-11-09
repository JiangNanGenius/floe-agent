# Android Alpha69 / code95

普通任务首次读取已启用指南时，固定经验证的正文、清单和摘要；同一次运行的后续分页和恢复继续读取该版本。`currentDigest` 仍表示当前安装版本，供既有更新校验使用。停用、删除、工具权限和执行目标的既有规则保持。

任务删除后，仅清理该任务持久运行编号下确认归属的快照。迁移标记、未知条目和损坏内容保留并拒绝复用；普通根目录切换不清除未完成任务的快照。修复迁移目录被当作空缓存删除的问题，保留原始失败。

Ordinary runs pin the first validated enabled guide's Markdown, manifest and digest. Later pages and recovery use that revision; `currentDigest` still identifies the installed version for management. Disabling, removal, tool permissions and execution-target rules remain authoritative.

Task deletion releases only marker-verified snapshots of its persisted run IDs. Migration/unknown entries and corrupt content are retained; ordinary root rebinding preserves unfinished-run snapshots. The original migration-directory cleanup failure is retained separately.

## Known issues / 已知问题

- 中间版本，N01–N08 总目标尚未结束；自动解锁／条件重新锁屏、部分后台跨 App 接续和全局 UI 精修继续推进。
- 索尼 Android9 的 Alpha67 运行组件校验报障仍待诊断和设备反馈；不以宿主验证或三星结果代替索尼实机通过。
- 损坏快照明确报错，不自动替换成新指南；未知归属的缓存保留。完整 App 进程死亡后的任务接续与更多硬件组合继续记录真实反馈。
- 部分远端签名指南仍含 iOS 内容，签名和平台校验保持，兼容的用户配置服务继续开放。

- Intermediate build: automatic unlock/relock, some background cross-App continuation and whole-App UI refinement remain open.
- The Sony Android9 runtime-component report still needs precise diagnostics and device feedback; host or Samsung evidence does not establish Sony acceptance.
- Corrupt pins refuse instead of silently adopting a new guide. Unknown cache ownership is preserved. Full-App process-death continuation and further hardware combinations remain subject to actual feedback.
- Some signed remote guides contain iOS-specific content; signature/platform checks remain. Compatible user-configured services remain available.

准备记录：固定 Alpha69/code95 及匹配的 Office 对应源码链接。技能快照相关宿主检查、实际 Android ARM64 对象／链接、最终包设备结果及公开交付分别记录；本文件不单独表示已经发版。

Preparation: Alpha69/code95 and the matching Office source offer are selected. Focused host checks, Android ARM64 object/link, final-device results and public delivery remain separate evidence; this file alone does not establish publication.

源码检查补充：9项当前宿主检查有通过回执，保留此前迁移目录误删及一次指南准备拒绝的原始失败。后者在独立和批次诊断未再现，原因尚未确立，不按无害销账；Android原生对象和设备结果继续单列。

Source qualification: the current nine host cases have passing receipts. The original migration-deletion failure and one unclassified creator-setup refusal remain recorded. Later isolated and batch diagnostics did not reproduce that refusal; its cause is not established. Android production-object and App evidence remain separate.
