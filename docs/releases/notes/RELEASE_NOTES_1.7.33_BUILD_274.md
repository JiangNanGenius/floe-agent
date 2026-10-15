# Floe 1.7.33 (274) — Task lifecycle, Notes covers and reader, honest storage

Release candidate. Source freeze, archive, TestFlight upload, Apple processing and review states are recorded separately from the qualification results below.

## 简体中文

- 临时会话入口收敛到“新建任务”启动台，会话内不再出现临时开关；只读工具上限真正作用于模型请求，切到其他会话或真正离开会取消并销毁，保留为正式会话不重复发送请求。
- 自动决定的回执并入引发它的工具卡片，不再重复占据聊天气泡；用户决定和历史记录保持原样。
- 子助手可自行搜索工具、读取 Skill 并加载所需能力；子运行拥有持久化记录，运行中与完成后都能查看，禁止再次委派。等待中的任务显示在等哪些后台作业，完整作业输出可分页读取。
- 调度沿用现有任务体系，完善一次性/每日/每周/间隔/上游成功触发的原子领取、时区锚定与提醒收口；后台有限作业保持原任务继续，不伪装成新任务。
- 供应商按每个模型的实际能力工作：多模态默认、显式覆盖保留、已有配置一次核对；不支持的预设不再出现在新添加入口。
- CAD 编辑使用任务授权，绘图/装配摘要更清楚，无需逐项到工作台确认；普通文档与媒体编辑减少重复审批，代码库写入与远端风险操作仍遵循任务审批。
- 存储页面改为应用自身占用的数值总计与分类明细相加一致，共享文件单独成区；采用公共 SDK 克隆/私有大小探测与快照缓存，不再每次打开全量扫描，普通界面不显示技术性下限说明。
- 手记（Notes）新增自定义封面：可手动选择照片或文件，也可由助手在授权文档上设置、读取和恢复；封面修订与内容修订分离校验。工作簿封面优先显示第一个有可见内容的表；隐藏行列或不完整读取保留有界摘要，不回落系统整页。
- 新增只读文档阅读器：打开文本类文档可切换手动编码（UTF-8、UTF-16 LE/BE、GB18030）以正确阅读旧文件，阅读位置按编码分别保存，关闭返回原编辑器不改变内容。
- 任务中心支持批量归档与删除：按任务身份多选、确认时冻结目标、逐项结果与部分失败重试；恢复后再次归档或删除按当前状态执行。
- 配置了辅助模型时，真正的自动思考强度在每轮开始时只决定一次，引导、工具与续跑不重算；超时或异常安全回退，模型能力范围仍生效；手动选择不变。
- 普通界面文案清理：数据管理清理区、同步脚注、供应商额外用途等改为简明说明，内部术语收进显式展开的详情。
- 修复输入框布局递归、系统通知回调、Linux 共享环境终端与会话归属、输出压力处理、以及取消过程中意外重新启动模型请求等问题。Linux 首次使用 Python 环境改为预置种子物化，已可用的环境不重建。

验证边界：本轮以本地 Xcode 27 完成完整 App 构建与针对性测试，并在模拟器中使用真实配置的模型完成手记 Office（Word/Excel/PPT）编辑与封面场景、真实辅助模型自动思考强度、以及正常 App 打开实际 AI 产物的验收。原生 Office 引擎在测试进程退出路径上的静态析构缺陷保留记录，未伪装修复；其业务与正常界面门槛已独立通过。组件、模拟器与宿主机结果分别记录，不代替真机：真实 iPad 存储数字、后台长时间行为与性能仍需对应设备复测。存储计量使用公开的 `fcntl(F_LOG2PHYS_EXT)` 接口计算实测 extent 并集；任何文件、卷或映射无法一致回答时按“全有或全无”回退到已接受的分配基准，绝不减去部分并集；不支持与部分克隆的限制保留在诊断文档中。

## English

- Temporary chat is entered only from the New Task launchpad; the in-thread switch is gone. The read-only tool ceiling applies to the actual model request, navigating away or leaving cancels and destroys the session, and Keep saves it without resending requests.
- Automatically decided receipts are folded into the tool card that produced them instead of adding a duplicate chat bubble; user decisions and history stay unchanged.
- Subagents discover tools, read Skills and load capabilities on demand; child runs have durable records that can be inspected while running and after completion, and further delegation stays disabled. Waiting tasks show which background jobs they are waiting for, and full job output is readable page by page.
- Scheduling keeps the existing task model and improves atomic claiming for once/daily/weekly/interval/after-success triggers, time-zone anchoring and reminder closure. Bounded background work keeps the original task round alive instead of presenting itself as a new task.
- Providers follow each model's real capabilities: multimodal defaults, preserved explicit overrides, one review for existing configurations, and unsupported presets removed from the new-add entry.
- CAD editing is task-authorized with clearer drawing/assembly summaries and no per-step workbench confirmation. Ordinary document and media edits need fewer repeated approvals; repository writes and risky remote operations still follow the task approval mode.
- Storage shows this app's own usage as a numeric total that matches its category details, with Shared Files in a separate section. Public-SDK clone/private-size probing plus a snapshot cache replace the full scan on every open, and the ordinary screen keeps technical lower-bound notes out of view.
- Notes adds custom covers: choose a photo or file manually, or let the assistant set, read and restore a cover on an authorized document, with cover and content revisions checked separately. Workbook covers prefer the first sheet with visible content; hidden rows/columns or an unreadable workbook keep a bounded summary instead of falling back to a system page thumbnail.
- A new read-only document reader opens text documents with manual encoding selection (UTF-8, UTF-16 LE/BE, GB18030) for legacy files, keeps reading positions per encoding, and returns to the original editor without changing content.
- Task Center supports bulk archive and delete: select by task identity, freeze targets on confirmation, per-item results with retry after partial failure, and restore-then-rearchive/delete actions follow the current state.
- When an auxiliary model is configured, true automatic reasoning effort is decided once at the start of each round; steering, tools and continuations do not recompute it. Timeouts or errors fall back safely within real model capabilities, and manual choices stay unchanged.
- Ordinary copy is simpler: cleanup, sync footnote and provider extra-use wording became plain-language summaries with internal details folded into explicit detail views.
- Fixes cover composer layout recursion, system-notification callbacks, shared-Linux terminal session ownership and output-pressure handling, and a cancellation race that could restart a model request. The Linux Python first-use environment now materializes a seeded environment instead of rebuilding, and an existing usable environment is kept.

Qualification limits: this round used local Xcode 27 for the full App build and focused tests, and qualified the configured real model through the Simulator App for Notes Office (Word/Excel/PPT) editing and cover scenarios, live automatic reasoning effort with the real auxiliary model, and opening actual AI outputs in the normal App. The native Office engine's static-teardown defect on the test-process exit path is retained as recorded, not masked; its business and normal-UI gates passed independently. Component, Simulator and host results are recorded separately and do not replace physical-device acceptance: real iPad storage numbers, long background behavior and performance still need device retesting. The storage basis uses the public `fcntl(F_LOG2PHYS_EXT)` interface for the measured extent union and fails closed to the accepted allocated basis whenever a file, volume or mapping cannot be answered coherently, never subtracting a partial union; the unsupported and partial-clone cases stay documented in the diagnostics guide.
