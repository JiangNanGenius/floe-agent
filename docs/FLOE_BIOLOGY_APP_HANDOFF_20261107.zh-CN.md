# 生物工作台 App 接入交接（2026-11-07）

实现源码：`f00e150cd050b8515398d8c39673c4ff4285a9bb`（空间利用率），此前全界面 `50e08ec4f89593f409cb31a5545552c2eaa0956a`，基础组件闭环 `cbfcbe30d0bf932810eb56404a9f088651040199`，原生三维/抗锯齿 `71f520f882f6b53ce6bc9b7b2c36b3c938de138d`。均已在 main；本组件 UI 任务不修改主 App、版本、315/325 或分发。

最新布局采用 320 点检查器、同行 44 点选择框、真实坐标取景和内容相关图高；公开 Workbench / Library 回调不变，新增的 `BiologyViewportFraming` 为纯显示计算。7 项几何与同轮 2 项 UI 已通过，同蛋白显示面积约为旧图的 3.47 倍；原图、精确尺寸和包绑定见 [空间利用率记录](FLOE_BIOLOGY_SPACE_UTILIZATION_20261107.zh-CN.md)。

组件覆盖序列、蛋白、显微、组学、网络，加 Newick/MRC 原生视图；21 个原生方法、32 个可选成熟方法、22 个 AI 工具。既有组件/科学/适配器证据见 [代码闭环](FLOE_BIOLOGY_COMPONENT_CLOSURE_20261107.zh-CN.md)，最新 7 个 UI 用例和 24 张原始截图见 [界面记录](FLOE_BIOLOGY_UI_POLISH_20261107.zh-CN.md#全工作台布局增量)。独立 iPad 宿主、脚本协议 fixture、真实科学数值和完整 App 验收分别记录。

## 主 App 需要连接的部分

下表记录此前 `50e08ec4f` 交接时的主 App 接线事项；主线正在并发适配，由其所有者更新实际 App 证据，本组件宿主通过不代表正式 App 已验收。按既定架构，生物与化学是并列工作台，共用既有 AI、文件、环境与任务服务，保持各自编辑状态。

| 接入点 | 宿主工作 |
| --- | --- |
| 工程与入口 | 引用 `FloeBiologyCore` / `Engine` / `UI`、独立 HostAdapter 与已校验 worker resources；添加 Notes/Space/Creative 入口及持久 biologyProjectID 路由，关闭后能回到原记录 |
| 服务与持久化 | 长生命周期 `BiologyService`、`BiologyProjectStore`、`BiologyFileAccessing`、execution contexts 和 scientific jobs；绑定实际项目/文件授权及创建后的 ownership，不用资格宿主的空授权闭包 |
| UI 回调 | `onAI` 接真实现有 agent/model；`makeTools` 返回当前任务作用域会话；`executionOwner` 绑定实际任务/run/环境与授权；`onInsertInNotes` 使用现有保存/返回链 |
| AI 发现与调用 | `bridge.register(in:)` 注册一次；`bridge.descriptors(for: context)` 合入当前有效目录，调度再核对权限。临时/只读上限与真实 task/run/call 来源不由 JSON 改写 |
| 科学执行 | 实际环境 probe→backend→configure→`contexts.authorizeNative`；沿用 Linux `exec.shell`、BackgroundJobService、EnvironmentRegistry、审批与文件服务，不另建解释器、安装别名或队列 |
| 恢复与文件 | 保留 HEAD/CAS/原件/回放与软删除；按真实工作进程退出证据 reconcile。大原件使用 opaque file ID、环境与重新授权；project JSON 含引用，不能冒充便携大文件包 |

精确组合代码、权限回调及注册顺序在 [HostAdapter README](../FloeAgent/Modules/FloeBiologyKit/Integration/FloeBiologyHostAdapter/README.md)。不要复用手记/聊天的编辑选区、undo 栈或会话来代替组件状态；手记记录不依赖聊天任务存活。

## 许可与剩余验证边界

原生源码遵循仓库 MPL-2.0；合成样例与 PDB 原件的来源、许可和引用见 Samples。66 个外部包有 pinned 许可 metadata/license-file 清单；原生组件不链接 Python 解释器或科学库二进制。`igraph` / `leidenalg` 的 GPL 条款已记录，实际 runtime/轮子再分发仍需保留并核对上游许可文件，当前证据不构成 runtime 整包分发资格。见 [后端说明](../FloeAgent/Modules/FloeBiologyKit/Backends/README.md)。

科学数值使用已固定的 CPython 3.12 macOS arm64 环境验证；实际 Linux 平台轮子、完整 App 中的模型目录与调用、真实 guest/provider 路径、iPhone/iOS 26 运行时、实体 iPad 和大文件吞吐尚未由该宿主验收。缺开发侧账号实测不应封禁用户配置的外部 provider，实际错误走现有错误/回退链。多文件 OME 拼接等既有方法边界保持原样，不用 UI 预览成功替代它们。

最新独立 Simulator 包：`Local/Artifacts/FloeBiologyKit/20261107/round2/FloeBiology-space-05-iPad-Simulator.zip`，SHA-256 `23b82e3ab7e8f5c91366f25a14992eaade3350821d45727da6fcc7bde370b2e1`。冻结源码 / 代码映像 / 用例绑定为同目录 `space-qualified.json`，完整 82 文件源 ZIP 与逐文件哈希一并保存，不将同 checkout 后续 App 适配修改混入其通过结论。旧布局包、原始失败和原因未定的历史 Runner SIGTERM 均保留。组件原生窗口已释放，任务缓存已清理；既有 canonical 数据与其他任务的构件未删除。
