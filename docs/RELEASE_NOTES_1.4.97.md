## Floe Agent 1.4.97 (Build 128)

### 简体中文

- 修复内置技能的标识符、安装清单与首次读取竞态；系统指南保持只读，PDF、Office 和网络指南支持显式 GitHub 来源更新。
- Python 与 Executor 保持底层能力，交互 SSH/Telnet/串口归入 Terminal；工具按任务和已读取的技能按需加载，不再把完整目录重复塞进提示词。普通聊天不受某个技能工具清单的全局限制。
- 技能读取支持完整的有界分页、工具自动加载和检查点保存；审过的脚本按哈希校验，运行中的任务固定技能快照。Python 版本和 NumPy/Pillow 可用性由当前运行时探测。
- GitHub 更新使用现有连接器：固定 commit、逐文件哈希校验、内容与权限审核、安装回读验证、中断恢复和回退。可更新单个 SKILL.md，或显式列出文件与 SHA256 的完整技能包；不自动跟随文档链接，不升级原生运行时。
- SSH guardian 升级至 1.4.5：会话设备隔离、数量限制、定时过期回收、有界进程关闭，以及部分输入写入处理。交互会话固定已解析的主机，避免默认主机变化后串到另一台机器。

仅内部 TestFlight。发布状态以 CI、上传回执、Apple VALID 和 Floe QA 可见性分别核验为准，不开放外部 Beta。真机重点验收：技能首次读取与工具加载、Python 脚本运行、GitHub 审核/回退、SSH Terminal 与 Executor；已修复的 PiP 不做行为变更。

### English

- Fixed bundled skill identifiers, installation manifests and first-read seeding races. System guides remain read-only; PDF, Office and Network guides can bind to explicitly reviewed GitHub updates.
- Kept Python and Executor as execution substrates, separate from the interactive SSH/Telnet/serial Terminal group. Task- and skill-driven tool discovery replaces repeated full catalogs; one skill no longer globally restricts ordinary conversation tools.
- Added bounded, complete skill pagination, read-to-tool activation and checkpoint-safe results. Audited scripts are hash-verified and running tasks retain pinned skill snapshots. Python and NumPy/Pillow availability comes from the current runtime probe.
- GitHub updates reuse the existing connector with immutable commits, per-file hashes, content/permission review, installed-content verification, interruption recovery and rollback. Updates support SKILL.md or an explicit file/SHA256 package inventory; linked documents and native runtimes are never implicitly downloaded.
- Guardian 1.4.5 adds device-owned shell sessions, capacity limits, periodic expiry cleanup, bounded child-process shutdown and partial-input handling. Interactive sessions pin the resolved host instead of following later default-host changes.

Internal TestFlight only. CI, upload receipt, Apple VALID and Floe QA visibility are separate release gates; no external beta. Device acceptance focuses on skill loading, Python scripts, GitHub review/rollback, and Terminal versus Executor. Existing PiP behavior is unchanged.
