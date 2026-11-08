# Android 0.1.0-alpha.59 / code85

This intermediate preview continues N01–N08; whole-App acceptance remains in progress.

- Phone-action review now receives the exact node from the most recent matching observation. After entering text, an old node label cannot substitute for the Save control in a newer observation. Only the requested node and bounded page context are projected; protected values stay redacted.
- The evidence is activation-local and cleared on resume, invalid results and unknown execution. Existing authorization, observation freshness and dispatch checks remain authoritative. No older screen receipt is restored as a current one.

Thirteen focused host tests passed, including the real classifier-input contract, stale/failed observations, redaction, bounded decoding and legacy actions. Actual ARM64 production passed on the matching source inputs; exact APK and Samsung results are recorded separately. Test and compilation success alone do not establish automatic Save or original-file readback.

Known limits: automatic external editing and project-GUI model use still require device acceptance. A preceding Linux case produced assistant claims with zero actual tool calls; those claims are not runtime evidence. Unattended unlock, scheduled multi-App editing and remaining preview/UI paths continue through device iteration. Original files, failures and recovery copies remain.

---

本版为N01–N08的中间预览，整轮验收继续。

- 手机操作审批使用匹配观察中的实际目标节点。输入文字后，旧页面的节点含义不再替代新页面的“保存”控件；仅提供本次目标和有界页面上下文，受保护内容继续遮蔽。
- 这份观察依据只在当前执行期间有效；恢复执行、失败或状态不明时清除。授权、页面时效和实际操作检查继续生效，不把旧屏幕回执恢复为当前状态。

13项定向host测试及匹配源码的ARM64生产通过；精确APK及三星结果另行记录。编译和合同测试不能代替实际保存、原件读回或定时接续。

已知限制：跨App自动编辑与模型使用项目图形会话仍待实机验收。此前Linux用例出现助手声称执行、实际零工具调用，其文字不作为运行时回执。无人值守解锁、定时多App编辑及其余预览／界面功能继续迭代，原件、故障和恢复副本保留。
