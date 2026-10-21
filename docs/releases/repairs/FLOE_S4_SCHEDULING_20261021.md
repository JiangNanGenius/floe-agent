# S4 系统定时验证 / System scheduling qualification

2026-10-21。当前功能候选 `2aa42a256d7948ccd099a981f95ad043896e3328`，尚未生成新分发构建；已交付的 1.7.42（283）不变。Current feature candidate; no new distribution build yet. Distributed 283 remains unchanged.

- 完整 App 和测试宿主经本地 Xcode 27.0（27A266a）、iOS Simulator 27 arm64 对象编译通过。实际编译的动作元数据保留旧动作参数、结果和授权契约，只增加选定计划动作及预期的前后台模式。Full App/test-bundle object compilation passed; compiled registration preserves existing action contracts.
- 首轮 45 项宿主测试实际为 43 通过、2 失败、0 跳过。修复同一实例并发启动被误判为竞争，以及未保存外来会话的测试夹具外键失败后，受影响的 29 项全部通过；未受影响的时间 8 项、Intent 7 项、旧返回兼容 1 项保留已通过结果。没有弱化断言；原失败仍保留。Initial 43/2/0 results are preserved. The affected 29 pass after repair; the unaffected 16 passes remain applicable.
- 真实 SQLite／planner 的 14 项模块检查与时间 helper 的 8 项检查继续适用；不重跑无关 Office／Pencil 历史矩阵。Existing focused module/helper evidence remains applicable.
- 在固定 iPad mini / iOS 27 模拟器，系统快捷指令能找到新增动作、选择实际保存的计划、在未到期时拒绝、到期后创建一次持久化运行。后续“获取 Floe 运行状态”自动连接该运行引用并返回失败；重复调用保持同一实例／运行。Actual system dispatch, typed result chaining and duplicate convergence were observed.
- 该次模型执行失败的明确原因是模拟器的 Apple 本地模型不可用／准备中。不能据此宣称成功生成内容或完整文本／文件结果验收。The actual model run failed because its on-device model was unavailable; successful generation and system text/file results are not claimed.
- 系统守护进程日志确认时间触发器登记成功，但本次后台观察没有取得自动执行证据；真实设备锁屏、强退、长期运行仍待设备验证。临时时间触发器已通过系统界面移除，自动化列表恢复为空。Registration is not execution proof. Physical unattended behavior remains unverified; the temporary trigger was removed.
- 两个实际界面问题已在 `c4b6f764` 修复：实际包内摘要模板与中英文键匹配；系统编辑器已显示本地化摘要，设置步骤按配置、选择、启用、运行后关闭排列。修正候选完整 App／测试宿主编译通过，未重复已通过的调度用例。Both observed UI copy defects are fixed; actual compiled catalogs, Chinese system rendering and setup order passed on the corrected full App build. Runtime tests were retained because their source paths did not change.

下一阶段按既定计划合并 S5～S7：先完成所有代码、恢复路径与集成，再冻结共同候选统一测试和交付。Next: one combined S5–S7 code-first stage, then unified validation and delivery.
