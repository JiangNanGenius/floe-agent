# S3-B：快捷指令草稿队列（2026-10-20）

验收源码：`88dc1b71487a5906cbae96903d38504bfe536a4b`。本小包完成源码交付，不改版本或已发布安装包；不可变 `v1.7.40`／281 仍指向原交付源码。本修复随后续集成构建交付。

## 用户可获得的行为

- “发送到 Floe”和“创建任务”各自追加持久草稿，相同文字的多次提交分别保留。加入草稿只需要本地存储准备完成，无须配置模型。
- 普通首页按顺序接收。已有输入、附件和发送过程优先保留，待接收条数及“填入”按钮提示后续草稿；不自动发送任务。创作及其他草稿位置不领取首页队列。
- 旧单项草稿按原始内容生成稳定迁移身份；相同内容的失败重试不重复，迁移期间换成的新内容保留并独立迁移，原值只在保存后删除。
- 已领取的队首阻止后续条目越过。交付回执与文字一起保存并核对落盘后才确认；保存或确认失败保留可恢复状态。重新进入首页／重启时，已落盘的交付不重投，未交付的恢复领取。
- 输入框继续允许编辑。尚未核实保存的接收过程会暂缓发送和转入临时会话，并同步保护同一首页的其他窗口；避免未确认文本已被发出、重启后又重投。
- 普通草稿继续保留文字、附件、选区和修改代际；旧版草稿文件可读取，新版回执随同一文件原子保存。旧 Intent 参数、返回类型、能力开关及原有运行／计划入口保留。

Repeated Send/Create actions append separate durable drafts. Home preserves existing input and attachments, accepts in FIFO order, and acknowledges only disk-verified delivery. Recovery distinguishes delivered receipts from unproven claims. Legacy single-slot values and v1 composer files migrate without replacing user input. Draft creation needs local storage, not a configured model; sending remains a user action.

## 实际验收

| 层级 | 已核实结果 |
| --- | --- |
| 真实 SQLite 存储宿主探针 | 34 项检查、0 失败；schema v47、落盘重开、迁移去重、认领互斥、token 确认／释放、进程恢复、队首阻塞及迁移墓碑 |
| 完整 App／测试宿主编译 | 本地 Xcode 27.0（27A266a）、Swift 6.4、iOS Simulator 27 arm64、6 compiler jobs；实际对象编译通过，构建前后源码一致 |
| `ShortcutInboxStoreTests` | 11 通过 |
| `ShortcutInboxHandoffTests` | 28 通过：实际旧 Send/Create `perform()` → 生产运行时 → 隔离存储；真实 Home 消费实现，输入保护、迁移、落盘回执、写失败／确认失败／进程恢复、相同内容、多窗口及接收期间编辑／提交保护 |
| `ComposerDraftStoreTests` | 18 通过：普通草稿、修改代际、附件、选区、100k 文本、真实写失败、受控超时和损坏文件保留 |
| `ComposerLaunchHandoffTests` | 5 通过：普通发送的恢复、晚到结果及临时会话边界 |

最终原生运行由结果包独立解析：**62 通过、0 失败、0 跳过，4 个 suite**。固定现有 iPad 模拟器串行使用，任务结束后已关闭；不创建、克隆、抹除设备。测试使用实际 App 服务图中的生产入口与独立队列／草稿文件／默认值／通知通道，不执行模型，不覆盖真实用户草稿。生产者测试的 DEBUG 上下文为任务局部，Release 不包含该控制。

This is native hosted App/Intent and production Home-consumer qualification. It does not claim system Shortcuts/Siri dispatch, visible-device interaction or a new installable build. The final result bundle independently reports 62 passed, zero failed and zero skipped.

## 保留的失败与修复

- 首次完整编译发现旧草稿迁移传递 `UserDefaults` 的 Swift 6 隔离错误，已将读取／比较／删除约束在主执行域；随后修正三处恢复测试的参数顺序。
- 首次原生运行记录 35 通过、8 失败，后续屏障未完成。生产消费入口先取得锁、再使用“锁未占用”公共条件检查自身，因而拒绝自身；已区分内部空闲检查与公共可接收条件。确认该原因后中止本轮已失败运行，保留原始结果，未把中止当作通过。
- 普通草稿写失败用例同时发现低优先级写入队列与主线程等待的优先级倒置；调整写入调度，原失败断言不变。新增受控挂起队列测试，区分尚未执行的超时与真实失败，不虚报落盘或伪造错误。
- 已通过的 34 项存储探针未因 App／测试修复重跑；最后一轮覆盖实际受影响的消费、普通写入和此前尚未执行的存储集合。补文档不重新运行这些检查。

## 交付和后续

源码合并推送 main 并独立回读，本包分支清理；另一 S3 工作区的 HEAD、脏修改和未跟踪文件摘要保持原样。原始失败、成功日志及结果包保留；一次性模块缓存和已执行的测试配置清理，同一工作区的 App 增量缓存明确留给下一小包。

下一包仅 **S3-C 同次运行查询与文本结果**；文件结果留 S3-D，系统定时留 S4。B 已占用 schema v47，仅加入草稿队列，原型夹带的运行查询索引未引入；后续确需该索引时使用新的迁移。固定范围、通过即结项、只补验受影响行为、不无限等待的约束继续保留。
