# Floe Agent 1.7.19 — Build 260

## 简体中文

- 补齐独立手记验证工程的源码依赖，修复组件构建失败；App 运行逻辑与 Build 259 相同。

- 工程图本地预览首次连接临时失败时有限重试一次，保护已加载及未保存的编辑状态。

- 压缩本地模型运行说明，保留 Linux 首次启动参数选择和中断恢复规则，避免首轮上下文超过预算。

- 助手首次启动 Linux 时会按任务选择核心数和内存，优先发现状态及启动工具。
- 中断后恢复上次成功启动的资源配置；继续支持总计 4 核、单台最多 3 核。
- 优先复用已有的有效 Linux 镜像，修复新工作区缺失镜像时的安装入口。
- 工作区终端新增本地入口，缺少 Linux 镜像时显示安装提示。
- 本地 Python 服务不再因自动创建虚拟环境而卡在启动阶段。
- 修复 Office 开启自由绘制后自动插入默认图形的问题，并保持连续绘制工具激活。

请在实际 iPad 上重点测试会话恢复、Linux 启动和 Office 连续批注、保存及重新打开。编译及模拟器验证不代表设备验收，闪退原因仍需设备诊断日志确认。

## English

- Includes the missing source dependency in the standalone Notes qualification target; App runtime behavior is unchanged from Build 259.

- Retries one transient initial connection failure for local engineering previews while preserving loaded and unsaved editor state.

- Compacts local runtime instructions while preserving Linux startup selection and recovery, keeping first-turn context within its budget.

- The assistant selects Linux cores and memory for the task before first startup and discovers status/start tools first.
- Interrupted sessions restore the last successful resource configuration, with a four-core pool and at most three cores per guest.
- Reuses an existing valid Linux image and restores installation for fresh workspaces with a missing image.
- Adds a local workspace terminal entry with a visible Linux installation prompt.
- Local Python services avoid automatic virtual-environment creation during startup.
- Fixes Office freehand mode inserting a default shape and keeps the drawing tool active for consecutive strokes.

Please test session recovery, Linux startup, and consecutive Office annotations followed by save and reopen on a physical iPad. Compilation and simulator checks do not replace device acceptance; crash diagnosis still requires device diagnostics.
