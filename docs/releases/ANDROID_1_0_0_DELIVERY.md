# Android 1.0.0 / code108

状态：候选准备，尚未公开发行。计划使用不可变标签 `android/v1.0.0`，自行分发 Full ARM64 预发布，保留 iOS Latest。实际源码、安装包与对应源码摘要以冻结标签和发行元数据绑定；公开读回前不称交付完成。

## Changes / 更新

- 沿用内置预览、手记和轻量 IDE；Android 原生应用优先，项目 Linux 提供命令行执行和可选图形软件。桌面支持触控板与直接触屏操作。
- 手机和平板统一使用 `device.observe`、`device.act`、`device.screenshot`；发现、执行、审批、恢复和指南同名，旧任务保留三个精确兼容别名。
- 接通持久后台任务的真实执行归属，已打开和未打开的任务使用同一原生存活／结束观察。定时任务可按用户同意解锁设备，完成后在适用条件下重新锁屏。
- 文件同步记录最新已确认版本，保留冲突恢复，退休已删除的同步输入；返回内置编辑器时重新读取干净标签页的外部修改，保留未保存草稿和旋转状态。
- 延续按需离线组件、环境准备进度与诊断、终端多会话、应用管理与系统授权、跨版本完整包及增量失败回退／镜像更新。语音使用系统或用户配置的云服务；诊断截图按需附加并压缩，普通任务异常不自动上报。

The Full ARM64 build keeps built-in previews, Notes and a lightweight IDE, preferring Android applications with project Linux for additional execution and optional graphical software. Phone and tablet tools share the device namespace throughout discovery and execution while exact legacy aliases retain historical tasks. Native run ownership now covers unopened scheduled tasks and completion/relock observation. Workspace synchronization preserves the latest acknowledged revision, recoverable conflicts and deletion retirement; retained clean editor tabs read external changes on re-entry. Existing on-demand components, setup progress, multi-session terminals, system/app management, full updates, delta fallback and mirrors continue. Voice uses system/user-configured cloud services; screenshots are optional compressed diagnostics attachments and ordinary task failures are not automatically uploaded.

## Verification / 验证

本批复用未改组件的原始证据，完成135项相关 Swift／JVM检查及 Full 实际编译，保存 native42／43 ARM64 原生产物，并对私有工程包完成58项封装／原生绑定检查。原失败与修复后的独立用例分开保存。

三星新 S2 由一次原生计划触发，运行前从未打开生成的对话；真实完成锁屏→解锁→计算器9→任务完成→自动重锁。49条原始记录确认 Ark Plan／`ark-code-latest`、4项成功的规范工具调用、3次设备动作。G4首次返回保留的干净标签页即读取 Linux 新内容，未关闭标签或刷新重试；已删自建文件在原生与新 Linux 会话均不存在。临时凭据／权限／电源设置、测试文件与结束会话已清理，原5任务／2项目保留。

Focused compilation and135 relevant Swift/JVM cases pass with retained exact native42/43 artifacts and58 engineering package checks. Fresh Samsung S2 proves scheduled launch without a pre-opened conversation, actual unlock/result9/completion/natural relock and4 successful canonical calls. G4 reads the Linux update on the first retained-tab return. Owned native/guest files, ended tabs and temporary configuration are removed/restored. Original failures remain separate.

## Delivery checks / 发行核对

最终 code108 的实际构建、签名、原生／对应源码绑定、API28/29签名、增量重建、完整包回退、升级后数据保留及公开下载／更新发现须使用本次实际产物核对，随后追加交付证据。不会由工程包107的成功替代108的产物／发行检查。

Final108 packaging/signing/source bindings, legacy Android signatures, reconstruction/full-update fallback, retained data and public download/discovery are verified against the actual final artifact. Engineering107 evidence does not substitute for108 publication and installability.

## Remaining limits / 已知边界

供应商服务和硬件能力按实际配置、授权及设备支持开放。真实笔、射频、具体USB配件和厂商Root差异保留未验记录与反馈入口；独立新增的 iOS 重型工作台和双端实时同步继续留在后续范围。本版只维护自行分发 Full，不恢复 Play 发行。

Provider/hardware features remain available according to configuration, permissions and device capability. Physical pen/radio/USB accessory and vendor-specific Root differences retain honest unverified records and feedback paths. New independent iOS workbenches and live cross-platform synchronization remain later scope. Distribution stays Full-only.
