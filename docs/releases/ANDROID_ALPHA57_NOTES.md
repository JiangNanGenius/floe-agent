# Android 0.1.0-alpha.57 / code83

This intermediate preview continues N01–N08. Whole-App acceptance remains in progress.

- Agents can request an installed Android editor through `workspace.externalEdit`, then check the saved original, finish the handoff or cancel while retaining recovery copies. Task ownership, file access, native save verification and conflict handling use the existing workspace services.
- Opening an editor or checking an untouched file no longer counts as a saved modification. Earlier verified saves remain recorded. A lost launch acknowledgement keeps its recovery identity and cannot silently launch a second editor under a new model call.
- A foreground handover uses the existing task question. File checks can continue independently; automated phone input retains the Full channel's existing permissions and controls.

Related Full/Play Kotlin compilation and12 JVM regressions passed. Four focused host contracts cover actual tool registration/dispatch, trusted ownership, cancellation and settlement. ARM64 production, package identity and Samsung evidence are recorded separately for the exact candidate. These checks do not imply every external editor or device passed.

Known limits: return to the owning task when prompted to open an editor; conflict and incomplete source saves retain recovery rather than claiming completion. Existing task software is preserved and is not automatically copied into the project layer. Cross-App automation, unattended unlock, scheduled UI recovery and remaining professional-preview paths continue through real-device iteration.

---

本版为N01–N08的中间预览，整轮验收继续。

- Agent可通过`workspace.externalEdit`打开已安装的安卓编辑器，核对原件保存结果、结束编辑或取消并保留恢复副本。继续使用现有任务归属、文件授权、保存校验和冲突恢复服务。
- 打开编辑器、核对未修改文件不再算作“已保存”；已确认的历史保存仍保留。启动回执丢失时保留恢复标识，模型换一个调用也不能自动重复启动。
- 需要切回任务时使用原有提问提示继续；文件核对可独立进行。自动操作手机继续遵循Full版现有权限和接管逻辑。

相关Full／Play编译、12项JVM回归及4项宿主调用／归属／取消契约通过；精确包的ARM64生产、安装身份和三星实测另行记录，不据此宣布所有编辑器或设备通过。

已知限制：提示后需回到所属任务再打开编辑器；冲突、来源文件未保存等情况保留恢复，不伪报完成。旧任务已安装软件保留，不自动复制到项目软件层。跨App自动化、无人值守解锁、定时界面恢复及剩余专业预览继续按实机问题迭代。
