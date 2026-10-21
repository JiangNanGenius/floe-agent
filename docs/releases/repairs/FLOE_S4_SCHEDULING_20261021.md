# S4 系统定时验证 / System scheduling qualification

2026-10-21。1.7.43（284）已内部可安装；已交付的 1.7.42（283）不变。实际 App 编译源码为 `8722c5cb35131ca9adbe6f617dde78102f02229c`，发布标签 `v1.7.43` 对应 `a5042e27ca95b4f4e8a9a24f57e180bc512af0a4`。两者仅发布说明的中文标题不同，整个 `FloeAgent` 树相同；本次标签修正经用户单次明确授权，原标签对象已保存，App 与符号未重编。Build 284 is available internally. Its compiled source is `8722c5cb`; the release source `a5042e27` adds only the required Chinese release-notes heading, with the identical App tree. The one-time tag correction was explicitly authorized; the original tag record and actual build evidence are preserved.

- 完整 App 和测试宿主经本地 Xcode 27.0（27A266a）、iOS Simulator 27 arm64 对象编译通过。实际编译的动作元数据保留旧动作参数、结果和授权契约，只增加选定计划动作及预期的前后台模式。Full App/test-bundle object compilation passed; compiled registration preserves existing action contracts.
- 首轮 45 项宿主测试实际为 43 通过、2 失败、0 跳过。修复同一实例并发启动被误判为竞争，以及未保存外来会话的测试夹具外键失败后，受影响的 29 项全部通过；未受影响的时间 8 项、Intent 7 项、旧返回兼容 1 项保留已通过结果。没有弱化断言；原失败仍保留。Initial 43/2/0 results are preserved. The affected 29 pass after repair; the unaffected 16 passes remain applicable.
- 真实 SQLite／planner 的 14 项模块检查与时间 helper 的 8 项检查继续适用；不重跑无关 Office／Pencil 历史矩阵。Existing focused module/helper evidence remains applicable.
- 在固定 iPad mini / iOS 27 模拟器，系统快捷指令能找到新增动作、选择实际保存的计划、在未到期时拒绝、到期后创建一次持久化运行。后续“获取 Floe 运行状态”自动连接该运行引用并返回失败；重复调用保持同一实例／运行。Actual system dispatch, typed result chaining and duplicate convergence were observed.
- 该次模型执行失败的明确原因是模拟器的 Apple 本地模型不可用／准备中。不能据此宣称成功生成内容或完整文本／文件结果验收。The actual model run failed because its on-device model was unavailable; successful generation and system text/file results are not claimed.
- 系统守护进程日志确认时间触发器登记成功，但本次后台观察没有取得自动执行证据；真实设备锁屏、强退、长期运行仍待设备验证。临时时间触发器已通过系统界面移除，自动化列表恢复为空。Registration is not execution proof. Physical unattended behavior remains unverified; the temporary trigger was removed.
- 两个实际界面问题已在 `c4b6f764` 修复：实际包内摘要模板与中英文键匹配；系统编辑器已显示本地化摘要，设置步骤按配置、选择、启用、运行后关闭排列。修正候选完整 App／测试宿主编译通过，未重复已通过的调度用例。Both observed UI copy defects are fixed; actual compiled catalogs, Chinese system rendering and setup order passed on the corrected full App build. Runtime tests were retained because their source paths did not change.
- 最终候选进一步修复摘要键的命名空间，`8722c5cb` 经完整 App／Swift 6 对象编译和实际系统中文摘要验证；未放宽本地化检查。The final source also passes the namespaced localization contract and actual Chinese system rendering.

## 284 交付 / Delivery

本地 Xcode 27.0（27A266a）、iphoneos27.0 Release 归档和匹配符号已保存；云端仅对原包签名上传，没有重编 App。[上传运行](https://github.com/JiangNanGenius/floe-agent/actions/runs/39587359107)成功后，[独立 GET 回读](https://github.com/JiangNanGenius/floe-agent/actions/runs/39589699551)确认 Apple `VALID`、未过期、唯一 Floe QA 内部组及 `IN_BETA_TESTING`。实际上传 IPA 已保存并核对版本、build 及与归档相同的 App UUID；SHA-256 为 `9772d12cc69d28939bd703037f191eca086621b2d7b18a98bc7736b4a7ce852c`。Local archive and symbols are retained; cloud execution signed and uploaded the same App. Independent Apple readback confirms internal installability. The saved uploaded IPA matches the archive's version/build and App UUID.

原首次上传流程因发布说明缺少中文标题，在签名和上传前失败；原失败及来源记录保留。随后[规范发布与同次 awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/39589691700)成功，[稳定 latest Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.43)仅包含无签名 IPA、校验文件和必要来源文件。独立下载、来源证明、实际 arm64 设备可执行文件及在线订阅的地址／版本／源码／大小／摘要全部匹配；IPA 为 801,604,177 字节，SHA-256 `53620fe9230c44fdacb4c198839321ed12e186a7fa970dc9d36b8e61bf0af2e6`。The canonical stable unsigned release and same-run awaited Feather passed independent artifact, attestation, executable and live-feed verification. The original failed attempt remains preserved.

两个已完成消费者使用的私有传输草稿已删除并回读为不存在；本地两份传输 ZIP 和重复展开的 App 也已清理，实测外置卷净增加 3,290,484,736 字节（约 3.06 GiB）。当前签名／无签名包、原始 App 恢复文件、11 份匹配符号及成功／失败证据保留，依赖缓存仅为下一组明确复用保留；当前没有启动的模拟器。Both private staging drafts and redundant local transport/App copies are removed. Measured net free-space gain is about 3.06 GiB; current packages, matching symbols and recovery evidence remain. No Simulator is booted.

当前阶段按既定计划合并 S5～S7：先完成所有代码、恢复路径与集成，再冻结共同候选统一测试和交付。Next: one combined S5–S7 code-first stage, then unified validation and delivery.
