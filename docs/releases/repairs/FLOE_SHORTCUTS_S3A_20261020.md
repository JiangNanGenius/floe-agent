# S3-A：快捷指令可靠初始化（2026-10-20）

实现源码：`91269c602a01a2c5cdf926aad5759521741dc0b1`。本小包完成并合并；不改版本或发布既有安装包。1.7.40（281）的不可变标签与安装包保持原源码，本修复等待后续集成交付。

## 修复结果

- 生产 App 只持有一份长期服务图，在 App 初始化时登记快捷指令依赖；预览或测试构造环境不再覆盖快捷指令运行时。
- 界面启动与旧 Run／Schedule Intent 共用完整初始化。并发调用等待同一次准备；成功后重复调用复用结果；失败后下一次调用能够重试。
- 取消等待立即返回，其他调用继续等待共有操作；取消的 Intent 在创建任务或计划前停止。准备完成前不提前执行，保存配置读取失败准确报错。
- 保留旧 Intent 参数、返回字符串、权限门控及调用路径。同步本地化生成模板，避免后续生成把修复覆盖。

The App owns one production service graph. Existing Run and Schedule intents join shared launch and configuration readiness, retry failed initialization, and stop cancelled callers before creating work. Preview graphs cannot replace the shortcut runtime. Existing intent contracts and capability gates remain compatible; the generation template is synchronized.

## 实际验证

| 层级 | 结果与边界 |
| --- | --- |
| 生产 single-flight helper，Swift 6 原生可执行测试 | 25 项检查通过，0 失败；覆盖并发合并、完成退休、失败后重试、快速完成、完成早于等待登记、取消等待和已取消调用 |
| 完整本地 App／测试宿主编译 | Xcode 27.0（27A266a），iOS Simulator 27 arm64，6 compiler jobs；`build-for-testing` 成功，包含 Swift 6 实际对象编译，构建前后源码一致 |
| 实际 App 宿主定向测试 | `FloeAppTests/FloeShortcutsInitializationTests`：9 通过、0 失败、0 跳过；结果包独立解析为 Passed |
| 实际 App／Intent 入口 | Debug 专用屏障让界面在 bootstrap 前等待；同一 App 服务图中的实际旧 Intent／就绪入口经历一次注入失败和一次正常初始化重试。实际空 Run、空 Schedule 和预取消 Run 均在执行前拒绝；任务及计划数量不变；释放后普通界面加入已完成初始化，未重复恢复 |
| 设备与安装包 | 固定的现有 iPad 模拟器串行使用，结束后已关闭；无真实模型执行、无新增任务／计划、不改用户能力开关。没有声称系统 Shortcuts／Siri 分发、物理设备或新安装包已经验收 |

完整编译使用 `FloeAppTests` scheme、`generic/platform=iOS Simulator`、`-onlyUsePackageVersionsFromResolvedFile`、`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO`。实际宿主运行通过测试配置传入 `FLOE_S3A_ENTRY_QUALIFICATION=1`，只选择该初始化 suite，禁用并行，使用项目 canonical-device 锁。屏障和一次性故障注入均由 `#if DEBUG` 隔离，Release 不包含这些控制。

原始 helper 首次快速完成测试曾挂起：完成先于等待登记时丢失信号。保留失败日志及采样；完成状态锁存后该用例和完整定向集合通过。25 项已通过的 helper 检查在新增 App 验收屏障时没有重跑，因为 helper 哈希未变。App 验证未因补文档重跑。

Qualification is bounded: a Swift 6 helper executable passed 25 checks; the full App and test host compiled locally; nine hosted tests passed without failures or skips. The ordered entry test invokes real legacy intents on the actual App graph before scene bootstrap. It proves initialization and rejection before work, not operating-system Shortcuts/Siri dispatch or physical-device acceptance. The published Build 281 is unchanged.

## 收尾与下一包

原始日志、结果包、源码摘要和失败记录保留于本地私有证据。该包没有残留可安全删除的独立编译目录或临时可执行文件；App 增量缓存明确留给同一集成工作区的 S3-B，模拟器用户数据保持。另一 S3 工作区的 HEAD、修改、未跟踪文件摘要均与起始快照一致。

下一包仅 **S3-B 草稿队列**：连续提交不覆盖、按序准确消费、旧单项迁移、消费失败与重启恢复；查询／等待／文件结果和系统定时留后续。固定范围和退出条件，通过即结项；不因文档或脚本修正重跑无关检查。新发现的非阻塞问题记录后续，构建、设备和发布串行。
