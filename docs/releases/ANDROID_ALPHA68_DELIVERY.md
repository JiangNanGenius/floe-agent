# Android Alpha68 / code94

普通任务接入既有 `skill.list/search/read/create/manage` 工具与设置中的同一技能服务，修复 Alpha67 中模型找不到技能工具的问题。启动先恢复中断升级，再准备内置指南；停用指南只返回元数据，关联工具只包含当前已注册能力。旧代际工具不可继续调用，任务、模型、临时聊天和手记的既有权限范围保持。

模型执行优先使用任务所属 Linux 的 `exec.shell`；图形桌面主要供用户手动操作专业软件。轻量文本、Markdown 和代码编辑继续保留在 App 内。

Ordinary tasks now register the existing skill list/search/read/create/manage tools against the same service used by Settings, repairing Alpha67's missing tool group. Startup recovery precedes guide seeding and task admission. Disabled guides return metadata only, related tools reflect the actual registry, and retired generations refuse retained runners. Existing task/model, temporary-chat and Notes ceilings remain authoritative.

Model execution prefers `exec.shell` in the selected task Linux environment. The graphical desktop is primarily for manual user work; lightweight text, Markdown and code editing remain in Floe.

补齐 Linux 文件层准备：继承已有环境时，Unix socket／FIFO 运行端点不再导致整层复制被拒绝，原层和用户文件保留；设备节点仍拒绝。文件准备、校验及发布失败带有受限阶段码和可用的 errno，模型／终端能通过现有错误入口读取阶段码，敏感路径和原生错误文本不进入回执。

Linux layer preparation now skips non-copyable Unix socket/FIFO endpoints from inherited live layers while preserving source content and refusing device nodes. Bounded preparation-stage codes and available numeric errno distinguish failures without reflecting paths or native text. Reviewed stage codes reach the existing model/terminal error-code surface.

## Known issues / 已知问题

- 这是中间版本，N01–N08 尚未结束；自动解锁／条件重新锁屏、部分后台跨 App 接续和全局 UI 精修继续推进。
- 技能读取当前安装版本；运行中升级后的持久任务快照隔离仍未接通。不能把工具名称或成功字符串当作执行成果。
- Android9 索尼组件报障、早期 VNC 断连、完整设备恢复及不同硬件／提供商组合仍有未闭合项。
- 远端部分签名指南仍含 iOS 专属内容，保留签名和平台校验，不改版本绕过；兼容的用户配置服务继续开放。

- Intermediate build: automatic unlock/relock, some background cross-App continuation and whole-App interface polish remain open.
- Skill reads use the currently installed version; durable task snapshots across an in-flight upgrade are not yet connected. Tool discovery or a success string does not prove a readable artifact.
- The reported Sony Android9 component failure, earlier VNC disconnect, full-device restoration and hardware/provider combinations remain open.
- Some signed remote guides still contain iOS-specific content. Signature/platform checks remain enforced; compatible user-configured services remain available.

准备记录：3项注册／读取／退役／审批合同检查及61项文件层／事务／启动诊断相关检查通过，无跳过，Full调试和Play生产Kotlin编译通过；原生31实际对象／链接证据按精确输入复用。候选03三星已证明读取指南成功，但首次文件层准备失败，原始回执保留；下一候选的实际设备成果及公开交付分别记录，本文不宣称已完成。
