# Android Alpha67 / code93

本版为持续迭代的 GitHub 预发布。App 接入 12 份 Android 内置指南，模型可通过既有技能发现和读取通路使用；PDF、图片、SVG 和批处理使用任务 Linux 中的通用工具，模型执行以 `exec.shell` 为主。图形桌面主要供用户手动使用专业软件，轻量文本、Markdown 和代码编辑继续保留在 Floe 内。

内置指南与签名 Hub、社区安装来源分别保留身份。启动安装不会覆盖用户管理的包、修改或停用状态；显式删除的指南不再自动复活。“恢复内置指南”提供实际恢复通路，并显示结果或失败，不恢复执行授权。签名、平台、摘要及原安装/回退校验保持。

技能更新后的回退入口随实际安装状态及时刷新。公共表单顶部栏减少留白、保留点击区域，更新页移除重复的应用按钮；忙碌时取消入口不可用。手机操作指引要求等待授权或界面改变后重新观察，继续保留旧观察拒绝和失败停止规则。

This intermediate GitHub prerelease adds 12 Android-authored built-in guides to the real skill discovery/read path. Model work prefers the resolved task Linux environment through `exec.shell`; the graphical desktop is primarily for users operating professional software. Lightweight text, Markdown and code editing remain in Floe.

Bundled guides retain a distinct source identity. Startup preserves user-managed packages, edits, disabled states and explicit removal. An explicit restore action reinstalls missing guides and reports actual outcomes without restoring execution grants or bypassing Hub verification. The update sheet refreshes rollback availability, shared form chrome uses less space, and phone guidance requires fresh observations after approval waits or UI changes.

## Known issues / 已知问题

- 这是中间版本，N01–N08 尚未结束；自动解锁/条件重新锁屏、部分后台跨 App 接续和全局 UI 精修继续推进。
- Alpha66 计算器收尾实测的首个动作因等待审批后观察过期而停止，未打开计算器；不作为后台完成通过。未重试原失败任务。
- Android9 索尼组件报障、早期 VNC 断连、完整设备恢复及不同硬件/提供商组合仍有未闭合项。中断技能升级的启动恢复调用仍是明确代码余项，不标为平台限制。
- 现有远端签名目录中的部分指南仍带有 iOS 专属说明，属于待更新内容；本版不改写其签名或版本来绕过校验。用户可继续配置、使用实际兼容的第三方服务和技能。

- Intermediate build: automatic unlock/relock, some background cross-App continuation and whole-App interface polish remain open.
- The retained Alpha66 Calculator case stopped on its first action after an approval wait expired the observation. Calculator never opened; this is not background-completion acceptance, and that failed task was not retried.
- The reported Sony Android9 component issue, earlier VNC disconnect, full-device restoration and untested hardware/provider combinations remain explicit. Startup invocation of interrupted skill-upgrade recovery is a remaining code item, not a platform limitation.
- Some existing signed remote catalog guides retain iOS-specific instructions. Their content must be updated by its publisher; this App does not bypass signatures or rewrite versions. Compatible user-configured services and skills remain available.

版本、来源索引与发布说明已准备。当前已通过 Full/Play Kotlin 编译及 6 项真实指南模块检查；实际 ARM64、APK、三星行为和公开字节读回另行记录。本准备记录不代表已经构建或发布。
