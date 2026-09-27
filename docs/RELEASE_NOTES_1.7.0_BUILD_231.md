# Floe 1.7.0 (231) — release notes / 发布说明

**Status / 状态：修复候选，尚未发布。** 构建、IPA、TestFlight 与 GitHub 状态以交付记录为准；下列代码变化不代表 iPad 验收通过。

## 简体中文

- PPT、Excel 打不开：移除文档初始化期间抢先切换编辑的重复入口，由原生宿主在文档就绪后统一进入编辑。新的原生宿主已在云端编译；真实文档可编辑首帧、修改保存和重开仍需 iPad 验证。
- Word 中文字体：将字体放到 Office 引擎实际扫描的目录，并验证字体确实可以按名称解析；不能只以字体文件存在或描述符可读取视为成功。
- Office 诊断：导出包含文档加载阶段、宿主渲染状态、会话和代次。应用重启后保留上一次的有界日志，便于定位持续转圈与进程中断。
- 本地模型：改为边生成边传递可见文本，并保留工具协议和推理内容过滤；第一条消息创建后直接进入已持久化的会话，避免等待模型目录刷新。首次云端真实权重验证发现工具续答时解析普通 JSON 的循环缺陷，已修复并正在重新验收，不能宣称两轮调用已通过。
- Linux：新增状态、开机、关机和硬重启工具，显式传递核心数、内存和环境身份。硬重启全程独占环境，避免普通 Shell 在停止与启动之间抢占；返回实际分配而非仅回显请求。普通 Shell 冷启动仍默认单核。
- 仍未完成：生产双核启动资格验证、Guest 软重启实现。相应请求明确返回不支持，不静默降成单核后报告成功。

请重点复测 PPT/XLSX 在工作区、手记与 IDE 中打开，Word 中文显示与保存；本地模型普通回复及至少两轮工具调用；首条消息跳转。若失败，请导出应用诊断。组件、云端 macOS 模型与模拟器证据均不是 iPad 功能验收。

## English

- PPT/Excel opening: remove the competing edit entry during document initialization. The native host now owns readiness-gated edit entry. The rebuilt host compiled in the cloud; a real editable document, save and reopen still require iPad verification.
- Word CJK fonts: stage fonts in the engine's actual discovery directory and verify name resolution, rather than accepting file presence or readable descriptors alone.
- Office diagnostics now export bounded loading/render stages with session and generation identity, including the previous process's retained tail after relaunch.
- Local models stream visible prose while withholding reasoning/tool envelopes. A newly created first conversation can navigate without waiting for model-catalog refresh. The first cloud real-weight run exposed an ordinary-JSON parser loop during a tool continuation; the parser fix passed component tests and renewed real-weight acceptance is pending, so two-turn success is not claimed.
- Linux lifecycle tools expose status, start, stop and hard restart with explicit environment, core and RAM requests. Restart exclusively owns the environment across stop/start and verifies the granted shape. Parameterless shell cold starts remain single-core.
- Still unavailable: production dual-core qualification and guest soft reboot. Unsupported requests fail explicitly rather than silently claiming a downgraded start succeeded.

Please check real PPT/XLSX opening in Workspace, Notes and IDE; Word CJK display/save; an ordinary local reply and at least two tool-enabled turns; and first-message navigation. Export diagnostics on failure. Component, macOS inference-host and simulator results do not establish iPad behavior.
