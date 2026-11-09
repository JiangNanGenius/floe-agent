# Android Alpha68 / code94

普通任务接入既有 `skill.list/search/read/create/manage` 工具与设置中的同一技能服务，修复 Alpha67 中模型找不到技能工具的问题。启动先恢复中断升级，再准备内置指南；停用指南只返回元数据，关联工具只包含当前已注册能力。旧代际工具不可继续调用，任务、模型、临时聊天和手记的既有权限范围保持。

模型执行优先使用任务所属 Linux 的 `exec.shell`；图形桌面主要供用户手动操作专业软件。轻量文本、Markdown 和代码编辑继续保留在 App 内。

Ordinary tasks now register the existing skill list/search/read/create/manage tools against the same service used by Settings, repairing Alpha67's missing tool group. Startup recovery precedes guide seeding and task admission. Disabled guides return metadata only, related tools reflect the actual registry, and retired generations refuse retained runners. Existing task/model, temporary-chat and Notes ceilings remain authoritative.

Model execution prefers `exec.shell` in the selected task Linux environment. The graphical desktop is primarily for manual user work; lightweight text, Markdown and code editing remain in Floe.

补齐 Linux 文件层准备：继承已有环境时，Unix socket／FIFO 运行端点不再导致整层复制被拒绝，原层和用户文件保留；设备节点仍拒绝。文件准备、校验及发布失败带有受限阶段码和可用的 errno，模型／终端能通过现有错误入口读取阶段码，敏感路径和原生错误文本不进入回执。

Linux layer preparation now skips non-copyable Unix socket/FIFO endpoints from inherited live layers while preserving source content and refusing device nodes. Bounded preparation-stage codes and available numeric errno distinguish failures without reflecting paths or native text. Reviewed stage codes reach the existing model/terminal error-code surface.

修复继承环境中运行组件自有的 `000` 权限文件和目录阻断复制：文件打开后立即恢复原权限，目录在退出该层遍历后恢复；同一记录处理嵌套和中断恢复，兼容旧单文件记录。复制、快照校验和事务清理共用遍历实现。快照在遍历时保存原时间戳，再先写时间戳、后应用最终权限。文件内容、原权限和既有任务授权保留。

Owned mode-000 files and directories no longer block inherited-layer copying. Files restore their original mode before returning the open channel; directories restore on leaving traversal. One ordered recovery ledger handles nesting and interrupted changes, including legacy single-file records. Copying, snapshot validation and owned transaction cleanup share traversal. Snapshots capture timestamps while traversing and apply them before restrictive modes. File bytes, original modes and existing task authorization remain intact.

临时读取权限只在 Linux 运行空闲时变更；其他会话运行中需要借用权限时返回 `rootfs_source_busy`，不关闭用户会话或放宽现有会话上限。已准备的文件层仍可复用。

Temporary source permissions require an idle Linux runtime. A required change with live sibling work returns `rootfs_source_busy`; existing sessions stay open and capacity limits remain. Prepared layers can still be reused.

运行组件安装和在线更新共用当前签名读取：单签名优先取有序历史末项，多签名保留完整集合；不将旧证书或矛盾信息当作当前身份。保留摘要、版本、包名、证书集合和独立UID校验。区分文件摘要失败、系统未返回签名信息和签名不一致，准备失败不再一律提示检查网络／空间。

Runtime installation and updates share current-signer reading: the last ordered-history certificate for a single signer, or the exact complete set for multiple signers. Past certificates and conflicting facts never substitute for current identity. Hash, version, package, certificate-set and separate-UID checks remain. Setup now distinguishes digest failure, unavailable signing information and differing signing identities.

## Known issues / 已知问题

- 这是中间版本，N01–N08 尚未结束；自动解锁／条件重新锁屏、部分后台跨 App 接续和全局 UI 精修继续推进。
- 技能读取当前安装版本；运行中升级后的持久任务快照隔离仍未接通。不能把工具名称或成功字符串当作执行成果。
- Android9 索尼 Alpha67 组件校验报障仍待设备反馈；官方67主包及内置组件按API28的签名验证均通过，不代表索尼安装检查已通过。此次当前证书读取和提示调整仍需该设备实测。早期 VNC 断连、完整设备恢复及不同硬件／提供商组合继续保留。
- 远端部分签名指南仍含 iOS 专属内容，保留签名和平台校验，不改版本绕过；兼容的用户配置服务继续开放。

- Intermediate build: automatic unlock/relock, some background cross-App continuation and whole-App interface polish remain open.
- Skill reads use the currently installed version; durable task snapshots across an in-flight upgrade are not yet connected. Tool discovery or a success string does not prove a readable artifact.
- The Sony Android9 Alpha67 component-verification report still needs device feedback. API28-configured signature verification passed for the exact official67 APK pair; that does not prove Sony installation. The updated reader and messages need that device check. Earlier VNC disconnect, full-device restoration and hardware/provider combinations remain open.
- Some signed remote guides still contain iOS-specific content. Signature/platform checks remain enforced; compatible user-configured services remain available.

准备记录：3项技能合同及79项相关文件层／事务／嵌套恢复／启动诊断／回传检查通过，无跳过；59项来源未改的当前结果与20项后续App结果按输入摘要合并，不重跑已通过部分。Full调试和Play生产Kotlin编译通过；原生31实际对象／链接证据按精确输入复用。候选03／04模型读取指南成功但没有生成文件；三星候选06确认自有000文件、候选08确认自有000目录读取被拒。修复后的实际设备成果及公开交付另记，原始失败保留。

Preparation: three skill contracts and 79 distinct filesystem, transaction, nested recovery, diagnostic and host-propagation cases passed without skips. Input hashes bind 59 earlier passing cases and 20 subsequent App cases. Full-debug and Play-release Kotlin checks passed; exact-input native31 object/link evidence is reused. Earlier Samsung candidates read the guide but produced no file; candidate06 identified an owned mode-000 file denial and candidate08 an owned mode-000 directory denial. Original failures remain recorded. Post-fix device results and public delivery are separate.

补充准备记录：37项签名选择、身份、组件安装和更新策略检查通过，Full／Play编译通过；原有v1控制列表断言遗漏已上线控制，已保留原失败并更新为精确24项列表。三星候选10已完成25,489项／993,861,620字节文件层准备，并在真实PTY执行printf得到输出。模型文件交付和最终包设备验证继续独立记录。

Additional preparation: 37 signer, identity, component-install and update-policy cases passed, with Full/Play compilation. The stale v1 test omitted already-shipped controls; its original failure is retained and the exact24-operation assertion is updated. Samsung candidate10 completed the 25,489-entry, 993,861,620-byte layer and returned real printf output from its PTY. Model artifact delivery and the final APK device result remain separate.
