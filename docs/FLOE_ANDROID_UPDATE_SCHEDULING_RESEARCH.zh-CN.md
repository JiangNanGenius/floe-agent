# Floe Android 应用内更新与真实调度：官方约束调研与实施设计

日期：2026-10-18。性质：调研与实施设计，**不是实现**；本文档不声明任何已完成的代码、构建、设备安装或厂商反馈。所有平台结论标注证据级别：【已验证】=当日访问的官方文档原文；【设计】=据已验证约束提出的本方案架构选择；【未实测】=尚无设备或真实产物证明、须在对应目标实测。

- 对应计划章节：第9节（后台 调度与三星测试）、第16.6节（full/play 构建边界）、第17.2/17.3/17.7节、第20节、第23.2/23.3/23.5节（G11/G12/G13/G15）、第11节 P5.4 与 P6.5 工作包。
- 台账归属不变：调度组件仍在 G11 实现、G12/G13 验证、更新产物打包在 G15；本文档只把这些既有目标的范围、退出条件与验收写具体，不新增或改变任何操作/工作包 ID、数量与状态。
- 本轮不创建实际自动化、不配置真实 GitHub 发布通道、不做 Git 或商店操作；发行仍按届时授权。

## 1 用户最新要求（复述为本设计输入）

1. **更新通道**：GitHub 完整包在 App 内自动检查并支持手动检查更新，下载并校验官方新 APK，在符合 Android 安装生命周期的前提下完成应用内更新；用户可自主控制是否下载/何时安装。Google Play 包物理排除 GitHub 更新器模块及其权限与更新源配置，只走 Google Play 的更新机制。
2. **真实调度**：自动任务必须真实执行而非仅发通知。触发器至少覆盖：一次、每天/每周（日历墙钟）、固定间隔、上游任务成功后。要求关闭 UI、进程死亡后仍能按平台条件运行，持久化与重启恢复，展示下次/上次运行、历史、停止/恢复与结果；延迟、权限缺失、锁屏等待等状态如实可见。
3. **既有不变量**：不引入本地模型；不用画中画或辅助功能保活；共享原始 Swift 运行时/数据权威；iOS 视觉对齐；普通非 Root 能力必须可用，Root 增强仅 full 版用户明确启用，不得成为任何普通功能的先决条件。
4. **2026-10-18 新增直接用户要求**：非 Root 设备可通过 ADB 授权获得更大权限（普通/ADB-shell/Root 三档能力分级）。该模式仅 GitHub/full 提供，Play 物理排除；实现归 G08、验证归 G12/G13、打包归 G15。专题调研由独立任务负责（`docs/FLOE_ANDROID_ADB_PRIVILEGE_RESEARCH.zh-CN.md`，截至本文档日期**尚未生成，调研进行中**）；本文档只处理它与调度/更新语义的交集（见 4.5 节），不重复其能力面调研，也不把它写成已实现。

## 2 官方来源（访问日期均为 2026-10-18，正文引用以页面当日内容为准）

调度与后台执行：

- [闹钟与调度（AlarmManager 指南）](https://developer.android.com/develop/background-work/services/alarms)（页面标注 Last updated 2026-10-16）
- [Android 14 精确闹钟权限变更](https://developer.android.com/about/versions/14/changes/schedule-exact-alarms)（2026-03-03）
- [Android 15 行为变更：所有应用](https://developer.android.com/about/versions/15/behavior-changes-all)（2026-10-16）
- [Android 15 行为变更：target 15 应用（BOOT_COMPLETED 启动 FGS 类型限制）](https://developer.android.com/about/versions/15/behavior-changes-15)（2026-10-16）
- [前台服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [后台启动前台服务限制](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)（2026-10-16）
- [前台服务时限（dataSync/mediaProcessing 累计上限）](https://developer.android.com/develop/background-work/services/fgs/timeout)（2026-10-16）
- [WorkManager 入门](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started)（2026-09-23）
- [PeriodicWorkRequest（最小周期常量）](https://developer.android.com/reference/androidx/work/PeriodicWorkRequest)（2026-06-24）
- [WorkRequest.Builder.setExpedited](https://developer.android.com/reference/androidx/work/WorkRequest.Builder)
- [WorkManager 长时运行 Worker](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/long-running)（2026-10-16）

安装与更新：

- [PackageInstaller.SessionParams.setRequireUserAction](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams)（2026-08-03）
- [PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller)（2026-08-03）
- [AOSP：App ownership 与 update ownership](https://source.android.com/docs/setup/create/app-ownership)（2026-06-17）
- [Android developer verification（时间线与地区）](https://developer.android.com/developer-verification)
- [Play“受限设置”说明](https://support.google.com/android/answer/12623953)
- [Google Play Device and Network Abuse 政策全文](https://support.google.com/googleplay/android-developer/answer/9888379)
- [Play Console 权限与敏感 API 政策（含 USE_EXACT_ALARM 受限声明）](https://support.google.com/googleplay/android-developer/answer/16558241)
- [Play in-app updates（Kotlin/Java 指南）](https://developer.android.com/guide/playcore/in-app-updates/kotlin-java)（2026-10-16）
- [Play in-app updates 测试指南](https://developer.android.com/guide/playcore/in-app-updates/test)（2025-07-21）

## 3 GitHub 完整包应用内更新器（full only）【设计】

### 3.1 更新源与制品信任【已验证约束 + 设计】

- 只信任官方发布源：固定归属的 GitHub Releases/API 通道与仓库标识，传输强制 TLS 校验；不使用任意镜像 URL，不“从成功字符串推断已发布”。feed/仓库标识与更新器代码只在 full 构建图中存在。
- 通道筛选：区分 stable Release 与 prerelease；比较 installed `versionCode` 与候选 `versionCode/versionName`；校验 `applicationId` 一致、ABI（arm64-v8a 主发行）、`minSdk`/target 兼容、分包形态（单 APK vs split）与当前安装形态匹配。2026-10-19阶段Release要求追加：Android使用独立`android/v<版本号>`标签和平台产物元数据，同仓库发布的iOS版本不能进入Android候选集合；不直接使用未筛选的仓库Latest，亦不因Android发版替换既有iOS更新入口。现有iOS正式发行校验要求占有仓库级Latest；Android发布及编辑公开版（含稳定版）显式`--latest=false`，更新器从Android标签/平台筛选的Release或独立feed选择候选，发布前后核对Latest未被Android接管。参见计划第23.1.1节和[GitHub CLI说明](https://cli.github.com/manual/gh_release_create)。
- **校验和不能证明来源**：SHA-256 只证明下载完整，不证明发布者可信。必须核对候选 APK 的实际签名证书（读取 APK signing cert / 与已安装包 signer lineage 比较），与 Release 携带的签名发布元数据或等价的可信摘要互验。与已安装版本签名 lineage 不一致 = 拒绝安装并如实说明，不引导“先卸载再装”。
- 【未实测】签名 lineage、更新器与 Play 签名的跨渠道行为须在 G12/G13 真机实测，不在本文档承诺。

### 3.2 自动检查与手动检查【设计】

- 自动检查是**服务拥有的周期 WorkManager 作业**（网络约束、默认每日级、尊重 15 分钟最小周期即平台下限，实际取远大于下限的间隔），ETag/条件请求减少流量，失败有界退避、同一时刻单飞（single-flight），空闲/省电窗口延迟属正常，不承诺检查的即时性。
- 手动检查是设置页/关于页的显式动作，走同一校验管线并即时呈现结果（无更新/新可用/失败原因）。检查本身不下载、不申请安装类权限。

### 3.3 下载、暂存与用户控制【设计】

- 用户可配置的三级偏好（默认最小打扰）：仅通知；自动下载后询问安装；（满足平台条件时）自动安装。任何一级都不越过的底线：安装动作永远受系统用户确认策略约束，App 不绕过 OS。
- 下载：有界缓冲、断点续传、磁盘余量预检（含解压/暂存/回滚，与既有 P6.5 预检口径一致）、计费网络默认询问。
- **续传正确性（本轮确认的硬约束）**：恢复下载必须校验服务端 `Range` 支持、`Content-Range` 起点与 `ETag`/Last-Modified 一致；制品一旦变化（ETag 不同）即**丢弃已暂存部分、重新起流**，绝不把新旧字节混合追加。完成后全文件 SHA-256 校验 + 签名校验，再原子改名入暂存区。
- 取消语义分开：**取消下载**（可丢弃暂存、无系统副作用）与**已 commit 的安装会话**（只能 abandon/等待系统结果，不伪装成“已停止安装”）。
- 更新下载/检查失败必须保留旧版本可运行；不删除用户数据；下载缓存计入可清理空间口径（对齐第6节资源显示规则）。

### 3.4 安装会话与 PackageInstaller【已验证】

官方 `SessionParams.setRequireUserAction(int)` 文档（API level 31 起）确认：

- 默认为 `USER_ACTION_UNSPECIFIED`；对持有 `REQUEST_INSTALL_PACKAGES` 的安装器等价于 `USER_ACTION_REQUIRED`，其余等价于 `USER_ACTION_NOT_REQUIRED`。
- 持 `REQUEST_INSTALL_PACKAGES` 时，**同时满足全部条件**才不要求用户动作：`requireUserAction=USER_ACTION_NOT_REQUIRED`；被安装应用 target 达到系统门槛（Android 12 上 target≥29、13 上 ≥30、14 上 ≥31、15 上 ≥33、16 上 ≥34、Android 17 上 ≥35，且官方明示该门槛将随版本继续提高）；安装者是既有版本的 update owner（更新所有权强制开启时）、installer of record（未开启时），或**应用更新自身**；安装者声明 `UPDATE_PACKAGES_WITHOUT_USER_ACTION`。
- 官方同时要求：会话属主**必须始终准备处理 `STATUS_PENDING_USER_ACTION`**。

因此正确表述不是“总是静默”也不是“永远一次确认”：Floe full 自更新属于“updating itself”路径，在声明 `UPDATE_PACKAGES_WITHOUT_USER_ACTION`、满足门槛且策略允许时可免额外确认；任何不满足（旧系统、策略收紧、用户撤销“安装未知应用”授权）即回退到系统确认界面，UI 显示“等待你在系统弹窗确认”这类真实状态，不谎报已安装。安装前 App 进程可能被系统终止属正常生命周期，须按 3.6 恢复。

- 会话对象经 `PackageInstaller.getMySessions()`（本应用拥有的会话；单个会话用 `getSessionInfo(int)`；`getAllSessions()` 另受 `<queries>`/`QUERY_ALL_PACKAGES`/会话属主条件限制，三者均为 API 21 起的公开接口）枚举，session ID 在设备重启后保持到 finalize【已验证】——进程死亡/重启后必须对账：无主会话要么恢复写入要么显式 abandon，不静默遗留占满存储。
- 安装结果码区分 `STATUS_SUCCESS / STATUS_PENDING_USER_ACTION / STATUS_FAILURE_*`（含 BLOCKED、INVALID、STORAGE、ABORTED 等）【已验证】，逐个映射为可读状态；`STATUS_FAILURE_BLOCKED`（如设备管理限制）如实显示阻塞方，不转圈假装进行中。
- 侧载安装的“受限设置”（restricted settings）授权流程已验证存在于官方帮助页；更新器引导用户去真实系统入口，不自动改设置。

### 3.5 Android 14+ update ownership 与开发者验证【已验证】

- AOSP 文档确认：Android 14 起初始安装器可声明为某包的 **update owner**；其他安装器更新该应用时须经用户同意。预装应用由系统配置指派 owner。对 Floe 的含义：同一 applicationId 在不同安装来源（GitHub 侧载 vs 商店 vs 厂商预装）间更新会触发所有权/来源检查，**不承诺跨渠道直接覆盖安装**；full/play 渠道互换按第17.7节既有决定执行（优先双 ID 并装，签名与 versionCode 连续性各自保持）。
- PackageInstaller 文档当日已含开发者验证结果附加信息（验证失败原因 extra、`EXTRA_DEVELOPER_VERIFICATION_LITE_PERFORMED` 等）【已验证】：Android developer verification 官方时间线为 2026-08 开发者 API/有限分发账号/高级流程上线，2026-09-30 起对部分区域（巴西、印尼、新加坡、泰国）认证设备上从参与商店安装的应用生效，2027 起扩大到全球认证设备；面向 Google Play 之外分发的开发者需经 Android Developer Console 或 Play Console 注册。这直接落在 GitHub APK 的未来分发体验上：更新器必须把“开发者验证失败/需用户确认绕过”作为一等结果处理（原因码区分网络不可用与其他失败，官方说明部分场景允许用户确认后继续）。本轮不创建账号、不注册、不上传；G15 产物整理时按届时官方要求复核。

### 3.6 安装与运行中作业的协调（本轮确认的边界）【设计】

- 自动检查/下载可在资源预算内与前台并行；**提交安装单独排队**：安装 APK 会杀死本 App 进程，因此安装只允许发生在（a）所有归属中的 Agent/Linux/Office/媒体/文件保存作业为空或已到达检查点的安全静默时刻，或（b）用户显式确认“现在就装”。
- 用户选择“现在就装”**不是数据安全的豁免开关**：它先触发优雅收敛流程——对每个归属作业执行其真实可实现的取消/保存/检查点，无法安全收敛的对象明确保留可恢复状态——之后才 commit 会话；不得隐式绕过原子文件提交或既有迁移安全线。OS 安装器杀进程在两种路径下都可能发生，故（b）同样要求按 3.4/3.6 的对账与恢复处理，界面对“正在收尾/已提交安装/等待系统”如实分段。
- 不满足时状态显示为“已下载，等待当前任务完成后可安装”，逐个可解释在等哪个任务；不 force-stop 其他 App，不强杀自己的服务拥有的运行作业，不静默丢弃未保存文档。
- 安装前持久化“待对账安装”记录（版本、会话 ID、意图来源），新进程启动后与 `getMySessions()`、已安装包版本三方对账：成功/失败/中断都归结为真实结果；进程死于安装窗口不重复触发第二次安装提交。
- 升级后的数据兼容沿用第17.7/P6.5 既有迁移门槛：更新前暂停/排空实际写者、失败保留恢复点；调度存储按 4.3 的 revision 机制跨版本兼容。

### 3.7 Play 构建的物理排除【已验证政策 + 设计】

- Play 政策（Device and Network Abuse，已验证原文）：**经 Google Play 分发的应用不得使用 Google Play 更新机制以外的方式自我修改/替换/更新，也不得从非 Google Play 来源下载可执行代码（dex/JAR/.so）**；VM/解释器内运行的代码（如 WebView 中 JS）不在此限。
- 设计（不是仅运行时隐藏，与 16.6 既有裁剪口径同法核验）：`:updater` 模块、GitHub feed/仓库标识常量、`REQUEST_INSTALL_PACKAGES`、`UPDATE_PACKAGES_WITHOUT_USER_ACTION`、更新检查/下载/安装全部 UI 与入口只进入 full 构建图；P6.7 验收检查 Gradle 依赖图、合并 Manifest、最终 DEX/资源/资产/原生库和运行工具发现，证明 play 产物不含更新器代码与上述权限声明。Linux rootfs/包管理等既有“数据/解释执行”路径的渠道规则另行按第10.1节逐类评估，不因排除更新器而扩大或缩小。
- play 版更新提示只能使用 Google Play 机制。in-app updates 官方指南【已验证】说明其依赖 Play 安装链路（测试文档明确“in-app updates 仅对经 Google Play 下载过该应用的用户账号可用”，且 Play 只会把应用更新到更高 versionCode）：play 构建可选接入 Play in-app update（立即/弹性两流），把 Play 返回的可用性/用户拒绝/取消如实映射，不假装能强制更新，不把 Play in-app API 用于 GitHub 包。

### 3.8 跨渠道身份与签名【设计 + 边界】

同/不同 applicationId、debug 与发行签名、full 覆盖 play 或反向的交叉安装行为，一律以“不承诺直接跨渠道覆盖安装”为默认表述；实际行为归 G12/G13 用真产物与真机验证后写进兼容报告（对齐 17.7 双 ID 决定与第13节“渠道互换不能假定覆盖安装”）。

## 4 真实调度（full 与 play 共同的产品核心）

### 4.1 语义基线与唯一权威【设计，沿用既有共享核心】

- 原始权威仍是 iOS 共享 Swift 运行时：`FloeAgent/Sources/FloeModels/TaskSchedule.swift`（cadence 枚举 once/daily/weekly/interval/afterSuccess、锚点墙钟、`anchorTimezone`、interval 绝对时长语义、afterSuccess 绑定具体上游 run 且按 run id 去重）、`FloeAgent/Sources/FloePersistence/TaskScheduleStore.swift`（occurrence 入队去重、原子 claim、running/finish 状态、中断 occurrence 对账 `reconcileInterruptedOccurrences`、`recentOccurrences/pendingOccurrences` 历史）、`FloeAgent/Sources/FloeModels/TaskPolicy.swift`（预算与允许域）。Android 平台适配器只做“到 AlarmManager/WorkManager/JobScheduler/BOOT 接收器的映射与恢复”，经既有 JNI 桥读写同一存储语义；**不建第二套 Kotlin 调度库/平行运行时**。G01 已验证的共享策略核往返（FND-SHARED-CORE）即此通道；G02 当前任务核心持久化不得另起平行调度表（该边界现在记录，不改 G02 操作台账）。
- interval 的 DST 稳定性、afterSuccess 的“一次性 + 上游成功才触发 + 重放回调不重复”来自上述共享模型的既有语义，双端一致。

### 4.2 平台触发机制的已验证边界【已验证】

**墙钟 vs 经过时间**：daily/weekly 是日历墙钟语义（须按 `anchorTimezone` 在触发时重算，处理 DST 与用户改时区）；interval 是绝对时长（elapsed 语义，不随墙钟跳变漂移）。AlarmManager 提供 RTC 与 ELAPSED_REALTIME 两类；elapsedRealtime 不受用户改表影响。

**不精确是常态**：Android 4.4 起所有 repeating alarm API 均为不精确；target 12+ 时窗最短 10 分钟（更小被抬到 10 分钟）；`set()/setInexactRepeating()/setAndAllowWhileIdle()` 保证不早于给定时刻，但 target 12+ 的时窗型不精确闹钟可能被推迟至少 10 分钟以上；Doze 中闹钟整体推迟到退出 Doze。官方建议：不精确闹钟触发后把实际工作交给 WorkManager/JobScheduler 执行。

**精确闹钟资格**：SCHEDULE_EXACT_ALARM 是“闹钟与提醒”特殊访问，用户授予、可被用户或系统撤销；targetSdk ≥ 33（Android 13） 全新安装默认拒绝；备份迁移到新设备不自动带入；权限被撤销时“应用停止且未来精确闹钟全部取消”。文档确认的是**授予**该权限时系统发出 `ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`，应用收到后须立即重新检查 `canScheduleExactAlarms()`（官方明确“用户可能刚授予几乎马上就撤销”）再重排；**撤销方向不得依赖回调**——恢复须借后续生命周期（BOOT_COMPLETED、应用回到前台、升级替换等）自行核对并重排。USE_EXACT_ALARM 自动授予不可撤销，但 Play Console 政策（已验证原文）把它列为受限权限：**只有核心功能为闹钟/计时器/日历事件提醒的应用可声明**，否则不予上架。Floe 不是闹钟类应用——结论【设计】：play 版不声明 USE_EXACT_ALARM；full 版可声明 SCHEDULE_EXACT_ALARM 走用户授权，play 版是否声明 SCHEDULE_EXACT_ALARM 按功能真实性与届时政策评估；未获精确资格时全部退回“灵活窗口 + 如实显示将延迟/待执行”，绝不把通知当执行、不把灵活承诺写成“准点”。

**OnAlarmListener 不是旁门**：文档确认经 OnAlarmListener 的 setExact 不要求 SCHEDULE_EXACT_ALARM——因为回调只投递给进程存活的监听者，进程死即闹钟无效果。这是进程生命周期的限制而非绕过资格的路；【设计禁令】：Floe 不为省权限而用监听器型精确闹钟承载需要跨进程死亡执行的调度。

**闹钟触发≠无限执行权**：到点只启动一次受限的执行窗口；网络请求、前台服务启动、长任务仍分别受本节的启动/时限/类型限制约束。文档同时确认：精确闹钟本身不受前台服务启动限制牵连（作为精确性的对价仅此而已）。

**WorkManager 与配额**：周期工作最小间隔 15 分钟（常量级下限，设计值远高于它）；长时 Worker 用 `setForeground()` 可超 10 分钟，但 targetSdk ≥ 34（Android 14） 必须声明对应 FGS 类型；**Android 16 起长时 Worker 内部使用的前台服务会消耗应用 job 配额，配额耗尽即无法继续**——官方给出的出路是直接前台服务或用户发起的数据传输作业（UIDT，豁免普通配额）。UIDT 的适用面须按已验证原文收窄：它只用于**设备用户真实发起的数据传输**、要求通知、立即启动并“在系统条件允许时运行较长时间”，且**必须在应用对用户可见（或官方允许条件）时创建**；它不是定时任务/AI 作业的通用豁免。直接前台服务同样受合法类型、启动条件与时限约束。平台条件不满足时，设计必须显式落到“等待或预算分段执行”，不存在可承诺“常驻随起”的通用服务。dataSync/mediaProcessing 前台服务在 targetSdk ≥ 35（Android 15） 受 24 小时累计 6 小时、按类型分别计量、回前台重置、超时回调 `Service.onTimeout()` 约束，超限抛 `ForegroundServiceStartNotAllowedException`。expedited 工作有配额且“电量管理限制较少、适合用户发起的短任务”，不用于伪装长任务。
**开机、任务移除与停止语义**：BOOT_COMPLETED 须声明 RECEIVE_BOOT_COMPLETED，且应用须已脱离首次安装的停止态；targetSdk ≥ 35（Android 15）的 BOOT_COMPLETED 接收器禁止拉起 dataSync/camera/mediaPlayback/phoneCall/mediaProjection/microphone 类型前台服务（microphone 自 Android 14 起受限）。Android 15 起进入 stopped state 会取消全部挂起 PendingIntent，待用户动作使应用脱离该状态后再按实际系统事件重建。以下情况分开设计和测试：

- **LMK/内存回收**：进程被回收，按持久记录和平台允许的启动条件恢复对账。
- **最近任务划除**：任务被移除不等于整个进程死亡或 Settings force-stop；运行服务的行为还取决于 `stopWithTask` 与 `onTaskRemoved()`。见 [Service 官方 API](https://developer.android.com/reference/android/app/Service#onTaskRemoved(android.content.Intent))。
- **厂商清理/冻结**：按具体 OEM、系统版本和实际退出/停止状态记录，不能统一归入 LMK，也不能承诺原有闹钟或作业必然保留。
- **Android 13+ 前台服务 Task Manager Stop**：终止整个应用进程、移除通知且无回调，官方基线保留既有 job/闹钟；下一次启动时按可用 API 核对 `ApplicationExitInfo.REASON_USER_REQUESTED` 等原因。此 API 在旧系统需做可用性保护。
- **UIDT Task Manager Stop**：立即终止进程（包括其他 job/前台服务），不调用 `onStopJob()`，并阻止用户可见作业重新调度；通知另提供可优雅停止的操作。
- **Settings force-stop**：进入 stopped state；不承诺后台自行恢复。用户动作使应用重新具备运行条件后，再核对实际权限、待办记录与系统调度状态。
**锁屏与凭据存储**：device-protected 存储之外的凭据加密数据在开机后首次解锁前不可用（既有第17节决定）——调度恢复遇到该状态时任务进入“等待解锁后执行”的真实状态；【设计禁令】不为提前执行把密钥搬进设备保护存储。

### 4.3 调度架构【设计】

- 一次触发 = 一个 **schedule revision + occurrence 身份**（沿用共享存储语义）：入队去重、原子 claim、running/finished 显式转换、重启后 `reconcileInterruptedOccurrences` 式对账。派发是 at-least-once：崩溃窗口允许重复投递，**持久去重与原子领取提供的是“同一逻辑 occurrence 只有一个活跃执行属主”并抑制重复触发，不是跨崩溃与远端副作用的全局 exactly-once 真实执行**。三层概念分开记录：逻辑 occurrence（一次计划触发）/ 执行 attempt（同一 occurrence 的第 N 次尝试，带检查点续跑）/ 外部幂等键（远端支持时随 attempt 携带同一键去重）。外部副作用结果未知（超时/断连）时先查证再决定，不盲目重发（对齐 17.6“先查远端状态”）；产品文案与验收均不得宣称“外部世界恰好执行了一次”。
- 触发链设计：daily/weekly/once → 有精确资格且用户授予时用一次性精确闹钟（**用“触发后重排下一次”的一次性闹钟实现日历重复**，不用被文档判为不精确的 repeating API 假装准点）；无资格时使用有界的请求窗口和 `setAndAllowWhileIdle` 型机会，结合 WorkManager 约束作业收敛；请求窗口不是系统保证的最晚执行期限，超出预算时按错过/等待策略如实处理；interval → 经过时间锚 + WorkManager/JobScheduler；afterSuccess → 共享核心的成功完成回调直接入队 occurrence（不经闹钟）。
- 执行体归 G03 已有作业/服务生命周期与 jobs 所有权（environmentID、任务归属、取消、输出背压）；调度器只是触发与账本，不拥有第二执行栈。
- 用户可见状态：下次运行（含“将延迟”窗口提示）、上次运行与结果、历史列表、启用/暂停/恢复、立即运行（校验同一策略与预算）、错过/合并/跳过/追赶策略按用户设置呈现且默认保守合并；force-stop 后显示“已停止，需打开 Floe 或等待系统时机恢复”，不谎称仍在运行。
- 预算与权限快照：每条自动任务保存模型/工作区/环境/允许域/网络/令牌/时长/并发预算与授权快照，**触发时重新验证**；配置、模型、工作区、环境被删除或授权被撤销时进入“可处理的等待/失败”状态并给出动作入口，不静默改用其他账号/模型；调度本身不授予未来执行权限。
- 时间改变/应用更新/恢复出厂或新设备恢复：重算全部 pending 闹钟与 WorkManager 注册（MY_PACKAGE_REPLACED、备份恢复、时区变更路径），新设备避免重复运行历史 occurrence。

### 4.4 与运行中/前台工作的关系【设计】

- 前台正在使用与调度触发冲突时按共享 TaskPolicy 的并发/资源预算决定排队或合批，不强占；普通进程回收（LMK）≠ force-stop：前者由持久作业与恢复对账处理，后者不承诺无人值守重启——两种恢复语义分开测试分开显示（对齐 S13/S08）。
- 通知权限缺失不阻断执行本身（执行状态仍可在运行中心查看），只降级提醒渠道；提醒/前台通知内容遵循 17.2 真实状态规则。

### 4.5 ADB 权限档与调度的交集（仅记录边界）【范围复述 + 设计】

- 新增“普通（默认完整可用）/ ADB-shell（用户明确选择，仅 GitHub/full）/ Root（仅 full、opt-in）”三档。能力专题由独立任务调研并已产出**提案草稿**（[GitHub 专属 ADB 增强模式调研](FLOE_ANDROID_ADB_PRIVILEGE_RESEARCH.zh-CN.md)）：该稿自述“只调研、只提案、未实测”，Main 已反馈修正意见、待其负责人收敛；本文只把它作为**研究提案**引用，不复制其能力矩阵，也不把其中任何条目升为已验证事实。
- 调度侧硬边界：依赖可选 ADB-shell/Root 后端的 occurrence，须在**每次触发时实际复核该任务所需的具体后端能力**，且三种形态分开：由 ADB 写入且当前仍生效的 App 权限/app-op/设置、经 shell 身份（UID 2000）在线桥接的执行通道、Root（UID 0）后端——各自的存在性与有效性独立探测，不能互相推断。只有**当任务确实需要的后端当前不可用**（例如重启后桥接进程未重新建立）时才进入“等待重新激活/重新授权”的可操作状态，不得假装完成；但**不得泛化为“重启即丢失所有授权”**，也不得反过来承诺任何具体授权必然跨重启持久，Root 档同理不写“永远无法开机自启”的统一断言——一切以逐能力复核结果为准。保存的启用意图不等于后端已激活；启动后按真实权限、连接与有效身份重建状态，其缺失不影响普通档的基本定时能力。
- 第17.5节“测试机 ADB 成功不代表发行安装流程成功、不用 ADB 设置替代正常用户路径”继续约束**普通模式验收**；用户明确启用、作为产品功能发布的 ADB-shell 档按 G08/G12/G13 单独验收，两者不混淆。

## 5 测试与验收场景（设计，未执行）【未实测】

正向（每条须真实产物与设备证据才升状态）：

1. full 自更新：新 APK 发布 → 自动检查发现（手动检查同样通过）→ 下载（含一次断点恢复，ETag 一致）→ 签名/摘要双校验通过 → 提交安装 → 按当时系统门槛出现“免额外确认成功”或“一次系统确认成功”两种可解释路径 → 安装后数据保留、versionCode 连续、调度账本重建。
2. Play 排除：合并 Manifest 无 `REQUEST_INSTALL_PACKAGES`/`UPDATE_PACKAGES_WITHOUT_USER_ACTION`，最终 DEX/资源/资产/依赖图中无更新器类与 feed 常量（P6.7 同法）。
3. 调度真实执行：每天 09:00 任务在 UI 关闭、进程被回收、次日重启三种场景各至少一次成功执行并留有 occurrence 历史；“立即运行”与触发链共用同一执行体。
4. interval DST 稳定：跨越夏令时切换的 6 小时间隔任务相邻两次执行间隔保持约 6 小时（elapsed 语义）。
5. afterSuccess：上游成功→触发一次；上游失败/取消/中断→不触发；重放成功回调→不重复触发。
6. 精确权限授予：授予广播到达后先 `canScheduleExactAlarms()` 复核再重排，一次性精确闹钟按点执行。
7. 停止语义分列：经系统任务管理器停止前台服务、设置 force-stop、最近任务划除、LMK 与厂商清理分别独立记录——任务管理器停止应无回调、进程死亡且通知移除，但既有 job/闹钟仍按时到点；设置 force-stop 则挂起 PendingIntent 取消、待用户动作后重建；三种结果分开呈现，不以单一“已停止”概括。
8. 显式“现在就装”：存在未保存 Office 编辑与运行中 Linux 作业时选择立即安装，验收 App 先完成逐作业可实现的保存/取消/检查点（不可安全收敛者明确保留可恢复状态）再 commit；进程被 OS 安装器终止后按对账恢复，不发生原子提交绕过或文档丢失。
9. ADB 档重启复核：重启后逐能力探测“App 持久授权记录 / shell(2000) 在线桥 / Root(0) 后端”的真实状态，只有所需后端确不可用才显示等待重新激活；三种形态的结果与恢复路径分开记录，不出现“重启后一律失效”或“授权必然持久”的话术。

负向（如实呈现的验收）：

1. 候选 APK 被篡改/摘要不符 → 拒绝且不进入安装会话；签名 lineage 与已安装不符 → 拒绝并解释，不引导卸载。
2. 恢复下载遇制品变化（ETag 变） → 已暂存片段作废、整包重新下载，最终摘要校验通过才入暂存区（验证“绝不混合追加”）。
3. 存在未保存 Office 编辑/进行中的 Linux 作业时到期安装 → 安装推迟并显示“等待哪些任务”，用户显式选择“现在安装”才提交；期间不发生任何 force-stop。
4. commit 后被系统要求用户动作而用户取消 → 状态停在“等待确认/被取消”，不出现“已更新”假成功；会话对账后无遗留占空间会话。
5. 未获精确闹钟资格 → 界面永不出现“准点执行”承诺；错过的窗口按合并策略显示“错过 N 次”，不伪造按时。
6. force-stop 后 → 不自动重启、不假装有后台运行；用户回到 App 后从持久账本恢复。
7. 开机后锁屏未解锁 → 凭据依赖任务显示“等待解锁”，不提前失败为“配置损坏”，也不把密钥移入设备保护存储。
8. 任务绑定的模型/环境/授权被删除 → 触发时不执行、不改用他人账号，显示可处理的等待/失败与修复入口。
9. 新设备/备份恢复 → 历史 occurrence 不重放，未来计划按 revision 重排且不重复触发。
10. full 覆盖安装 play 同 ID 场景 → 不宣称可行；按实测写入兼容报告，默认话术保持“跨渠道不保证覆盖安装”。
11. UIDT 误用审查 → 后台定时器、AI 作业等非“用户在可见界面真实发起的数据传输”不得创建 UIDT；作业配额耗尽场景必须落到等待或预算分段，而不是换用另一种常驻服务规避。UIDT 被用户在任务管理器停止后按官方后果（进程终止、无 onStopJob、用户可见作业不重排）核对，不依赖清理回调。
12. 崩溃注入：原子领取后、外部调用前/后分别杀进程 → 同一逻辑 occurrence 的后续 attempt 与重排不得被描述为“外部世界恰好执行一次”；远端支持幂等键时重试须携带同一键且记录 attempt 序号，远端结果未知时先查询再决定，不盲目重发。
13. 精确权限撤销路径（无可靠撤销回调）→ 借重启、升级替换、回到前台等对账时机重建未来窗口；在重建完成前界面不得出现“准点”承诺，也不得因收不到撤销广播而继续按精确时间调度。
14. ADB 三形态重启复核 → 重启后分别核对持久授权记录、在线 shell 桥、Root 后端；只有**任务实际所需**后端缺失才进入等待激活，三种结果分开记录，统一“重启一律失效”或“授权必然持久”的话术都视为失败。

## 6 未决与限制

- 本文全部“免确认/需确认”的表述依赖 target SDK 随 Android 版本推进的官方门槛，每次目标系统更新后由 G13 复核，不以旧文档为准。
- 开发者验证 2027 全球扩大后的 GitHub APK 分发体验、`app-ownership` 各 OEM 实现差异、真实 Root 管理器与 ADB-shell 档行为均属【未实测】。
- 调度组件的实现归属不变（G11 收口、G03 作业/服务为其执行前提、G12 三星省电/重启/force-stop 实测、G13 新 SDK 行为实测、G15 更新产物/feed 打包）；本轮全部是计划与验收具体化，未开始实现，也不改变 85 工作包 / 172 操作 / 30 项 G02 操作 / 26 样例的当前台账。
