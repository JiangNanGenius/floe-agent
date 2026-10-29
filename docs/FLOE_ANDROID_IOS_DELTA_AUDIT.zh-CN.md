# 安卓与 iOS 主线的增量差异记录

本记录随每个安卓大目标的收尾更新，用来调整下一阶段范围与优先级。以最新iOS主线源码为功能参照，保留安卓自身的原生实现方式和既有产品约束；主线新增功能不等于已在安卓实现。

## 执行规则

1. 记录上次与本次iOS主线提交、比较日期、安卓源码和实际发行版本。首次补核旧基线，后续优先比较两次基线之间的增量。
2. 追踪相关UI入口、服务、运行时／存储和实际成果，列出功能、视觉／交互和接口变化；注明代码证据与尚未验证的行为。
3. 为每项差异标记安卓状态、实际影响、对应工作包、优先级和目标阶段。保留原有编号／完成证据，新项独立追加。
4. 同步实施计划和进度记录，在切换下一大目标前确认下一目标仍覆盖最有价值的就绪工作。当前源码、编译、组件、App／设备和发行事实分别记录。

## 2026-10-26 首次增量盘点

本次比较原计划注明的iOS基线`037698e96e6890b0b3ac6d95037e3792aa32c692`与实际读回的最新`main`：`ab825370e3253285e777f4970ee993f73aeef95a`。后者的iOS来源为`f274b1f241673f75510da6c5ee956a57ceb03582`，新增的安卓提交没有改动iOS代码。`FloeApp/`与`Sources/`合计341个变更文件；以提交历史、变更清单和关键入口／服务／模型源码形成以下18组差异。这是需求及接口盘点，不是全部变更逐行审核，也不是iOS或安卓的新增设备验收。

安卓参照为已公开、下载校验通过的[Alpha11](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.11)，源码`ab825370`、构建号13。Alpha11的队列修复、已有文件／IDE／终端／浏览器／本地Git代表性结果保留；以下新增主线能力不能混记为Alpha11已实现。原183项操作、85个工作包与24项G04操作编号不重置；18个差异组也不作为18项已细化操作加入旧计数。

优先级：P0为下一目标必需合同；P1为后续相关功能接线前必须对齐；P2为所属阶段实现／平台等效适配。差异ID固定，后续在原行更新状态和证据。

| ID | iOS变化与源码入口 | 安卓现状和影响 | 优先级／目标 |
| --- | --- | --- | --- |
| IOS-D01 | `OfficeExplicitTargets.swift`、`OfficeFormulaVerification.swift`：目标绑定源摘要／成员／段落／工作表／对象；公式按真实依赖核验，保留嵌入工作簿格式 | Alpha11只有Office样例，没有内置Office用户闭环。G05不能只接一个渲染窗口；需复用明确目标、版本冲突及结果核验合同 | P0；G05：P1.5／P1.6／P3.3／P4.7／P5.1 |
| IOS-D02 | `OfficePDFExportService.swift`、`OfficePDFExportOptionsView.swift`、`OfficePrintCopy.swift`：实际PDF、分页／打印选项、选区／工作表解析、原文件保护、取消及弹窗拥有者 | 离线预览／导出尚待G05实现。预览、打印和保存从一开始采用同一源绑定与可取消服务；不能把导出命令成功当成真实PDF | P0；G05，代表性App统一验收 |
| IOS-D03 | `OfficeAutosaveCoordinator.swift`、`NotesOfficeView.swift`、`OfficeSavedCoverRenderer.swift`、`NotesSession.swift`：保存证明、独立手记工作区、已保存封面及笔迹、直接笔刷控制 | 手记／PDF／笔迹未形成安卓用户闭环。G05保留Office编辑／保存接口，G06接独立编辑状态、保存封面与无笔设备触摸回退；不共享聊天选择／撤销／助手状态 | P1；G05接口、G06：P3.4／P4.1／P4.2 |
| IOS-D04 | `RunOutputFile.swift`、`RunOutputSnapshotStore.swift`、`RunOutputCleanupQueue.swift`、`WorkspacePublishOutputTool.swift`：不可变运行文件与实际交付回执，清理可恢复 | G04文件保存／执行已代表性通过，不能据此认定新运行成果协议已对齐。G05输出生产者接入前核对快照、任务归属与提交／清理回执 | P0（Office生产者接线前）；G05＋G11：P5.5／P5.8 |
| IOS-D05 | `DocumentIntakeCenter.swift`、`DocumentIntakeQueue.swift`、`ImportDestinationCenter.swift`、`ShareInbox.swift`：持久接收、FIFO、去重、取消、任务／手记／画布明确目标与完成回执 | 现有SAF导入已通过代表性路径；系统分享接收和跨目的地事务未验收，不能用一次选文件代替 | P1；G06／G09／G11：P3.8／P6.1 |
| IOS-D06 | `VoiceConversationCoordinator.swift`、`ConversationVoiceTurnDriver.swift`、`SpeechPlaybackControlGraph.swift`及云语音适配：连续轮次、打断／恢复、真实播放队列与历史、配置来源和凭据归属 | Alpha11语音入口不等于连续语音产品已实现。对齐云端／系统可用语音和播放行为；iOS本地模型分支不自动迁移至安卓 | P1；G11：P5.3，先冻结音频会话／生命周期合同 |
| IOS-D07 | `WebSearchTool.swift`、`ProfessionalSearchAuthority.swift`、`WebSearchSettingsCenter.swift`：统一专业搜索、可更新来源目录、火山不同后端、紧凑答案及结果类型 | 安卓已有公共网页工具／配置基础，新专业搜索来源、目录和展示的完整对齐未验收。按实际可用配置发现工具，保留临时会话公开网页上限 | P1；G11：P5.5／P5.6；关联既有G02能力，原编号不改 |
| IOS-D08 | `ChildRunResume.swift`、`SubagentRunner.swift`、`ChildRunStore.swift`、`TemporaryChatToolPolicy.swift`：持久子任务续跑、父任务租约／模型身份及临时工具边界 | 当前队列自动续跑已实测；不能替代子代理恢复及最新临时策略的逐项核对。需比较共享源码固定点和JNI可达接口 | P1；G11：P5.6／P5.8；不为此重开整个G02 |
| IOS-D09 | `LinuxGuestSoftRestart.swift`、`LinuxLifecycleTools.swift`：刷盘、退出观察、磁盘提交和新启动的分阶段日志／恢复 | 安卓PRoot后端与iOS客体机制不同；已有停止／输出／退出证据保留。对齐可证明的服务重启与失败恢复，不能移植为重启宿主或声称PRoot是虚拟机 | P1；G11：P5.8；关联G03后续差异 |
| IOS-D10 | `BrowserTaskSessionStore.swift`、`BrowserTools.swift`、`LocalPreviewServer.swift`：任务级预览／浏览器生命周期、迟到结果隔离、空白捕获拒绝及有界观察 | G04本地受控页面、接管／返回和拥有者收尾已代表性通过；新增主线观察／捕获细节需独立列出，远程账户仍未验收 | P1；G11：P5.8；完整浏览器矩阵保留G12／G13 |
| IOS-D11 | `FloeScheduledTaskIntents.swift`、`TaskScheduleStore.swift`、`TaskScheduleCleanupReminderStore.swift`：确切计划／发生次序、并发去重、结果与清理提示、系统墙上时间 | 共享调度账本基础不等于安卓定时执行可用。以安卓调度、前台服务、通知、重启恢复落实等效结果；不搬运Shortcuts执行器，不用PiP保活 | P1；G11：P5.4／P2.10 |
| IOS-D12 | `FloeAppEntryRoute.swift`、`WidgetSnapshotProducer.swift`、`SystemAlarmService.swift`、`SharedDocumentsCenter.swift`及扩展目标：验证入口、快照、原生控制及事务化共享文件 | App Intents／WidgetKit／AlarmKit／File Provider属于平台机制；安卓需自己的深链、系统入口、通知／小组件和授权文件提供路径，不将Apple框架列为安卓依赖 | P2；G11：P3.8／P2.10／P6.3 |
| IOS-D13 | `LocationServicesCenter.swift`、`ContactsReadService.swift`、`NDEFReaderService.swift`、`HealthKitService.swift`：持续／后台定位及按任务授权的系统数据服务 | 安卓对应能力未形成该批App证据。按真实设备／系统／权限分别实现等效能力，所属目标开始时复核官方规则；不得因此本轮扩大三星权限 | P2；G11：P5.3／P6.3；完整渠道边界与G08分开 |
| IOS-D14 | `MediaEnhancementContract.swift`、`MediaEnhancementPipeline.swift`、`MediaExport.swift`：HDR／透明度、真实PTS与有理数输出时间、按需模型／引擎交付及工程保存 | 现有附件与文件链路不等于媒体工作台完成。G09须按真实输入／输出格式声明能力，保留不支持时的诚实拒绝与原工程 | P2；G09：P4.5；既有P5.2后续归属保留 |
| IOS-D15 | `FoldableDisplaySupport.swift`、`LayoutPreferences.swift`、`SettingsRootView.swift`、Office／语音控件：折叠区域、窗口布局和新增设置／二级弹窗 | Alpha10／11代表性两列设置、图标及紧凑工作区已保留证据；完整最新iOS材质、透明度、布局和状态仍未对齐 | P1随功能；G11：P4.8，最终G14／P6.13 |
| IOS-D16 | `SkillWorkspaceResourceStager.swift`、`SkillManagement.swift`、`SkillProvenance.swift`：固定版本技能资源真实送入任务工作区，路径／摘要／软链接拒绝和来源显示 | 安卓已有Skills发现和执行基础；不能把提示中提到资源路径视为文件已交付。Office／其他技能依赖资源前补核实际暂存与拥有者接口 | P1；G05接线前核对；实现差异归G11：P5.6 |
| IOS-D17 | `MailMutationJournal.swift`、`MailBodyPaging.swift`、`CalendarOccurrenceIdentity.swift`、`DocumentRecovery.swift`、`OrdinaryDocumentActionProfile.swift`：邮件回执／正文、精确日历实例、保存恢复和普通文档授权 | 本地Git／文件验证不覆盖远程邮件日历或新恢复协议；继续任务授权和原文件保护，不自动授予远程账户写入权 | P1相关接线前；G11：P5.3／P5.8 |
| IOS-D18 | `CredentialVaultService.swift`、`ConfigSyncEngine.swift`、`Personalization.swift`、`ProviderServiceOffers.swift`、`ContentUpdateCenter.swift`：凭据同步、配置迁移／个性化、服务来源和内容更新 | 已有安卓安全存储／模型能力覆盖证据保留；新增跨端同步不默认为获准建设新服务。GitHub自更新仍须实现，Alpha11是手动安装阶段包 | P1合同；G11：P6.1／P6.2／P6.5；Play不内置侧载更新 |

以上路径分别位于`FloeAgent/FloeApp/`或`FloeAgent/Sources/`，以[本次固定源码](https://github.com/JiangNanGenius/floe-agent/tree/ab825370e3253285e777f4970ee993f73aeef95a/FloeAgent)和[比较区间](https://github.com/JiangNanGenius/floe-agent/compare/037698e96e6890b0b3ac6d95037e3792aa32c692...ab825370e3253285e777f4970ee993f73aeef95a)为准。源码存在不等同于已发布或已验收。

### 对下一目标的调整

1. 下一目标维持G05内置Office，先做G05-R1：核对最新Office／成果回执／技能资源合同，确定维护中的安卓原生内核与许可／ABI／16 KiB来源，接入真实离线DOCX／XLSX／PPTX预览。不得仅因有Office样例或菜单就算完成。
2. G05-R2再完成编辑／AI精确目标／重算与公式核验／保存冲突／成果交付／PDF打印等连贯代码，G05-R3集中做三格式代表性App流程、阶段发布与清理。组件构建按实际需要集中进行，不为每个小修反复完整构建。
3. IOS-D04／D16在对应Office接线前处理必要合同；其余差异进入所属目标，不把本轮G04队列修复无限扩展。G06及其后仍按既有顺序，下一次大目标收尾再按增量调整。
4. 每一阶段只派发已经有输入、拥有者和容量的工作；这些差异行不是预提交的Worker队列。

## 流程建立时的待办记录（历史）

| 项目 | 当前状态 |
| --- | --- |
| 首次执行目标 | G04-R2收尾；当前仍在进行 |
| 既有iOS比较基线 | 待从现有盘点资料核对并补录 |
| 新iOS比较基线 | 审计执行时重新解析最新`main`，尚未冻结 |
| 已发行安卓参照 | Alpha10，`android/v0.1.0-alpha.10`，源码`acc5e0c1a06d4ac05aa6b0b0e249acc993eb6164` |
| 本轮未发代码 | 按G04-R2交接单独记录，不能混作Alpha10已包含 |
| 功能差异盘点 | 待执行；此文档建立流程，不宣称已完成源码审计或全功能对齐 |

后续每条正式记录保留比较区间、差异来源、安卓现状与验证层级、影响和下一目标调整，历史记录不覆盖。

## 2026-10-27 增量盘点（截至 `def77893`）

本次比较上次盘点目标 `ab825370e3253285e777f4970ee993f73aeef95a` 与已提交主线 `def7789317521fd00f3da62676420e5217e6041d`；GitHub main 与本地对象一致，G05-R2 合入点 `8a42db21` 是本次目标的祖先。区间为 140 个提交，其中 67 个触及 iOS 代码。这里只记录提交源码差异，不能据此宣称 Android App 或设备验收。

安卓参照为固定源码 `a92c75ba`、公开 Alpha13／构建15，以及已整合但未重新构建的目录导入修复和 Office 源码链接修正。C07 是已安装、未发布的 Alpha14／构建16候选；保存修复仍在进行，不能把代码整合视为编辑闭环通过。当前主线后续若继续推进，大目标收尾时只需补查 `def77893` 之后的增量。

| ID | iOS 新落地 | 安卓现状 | 差距与归属 | 优先级 |
| --- | --- | --- | --- | --- |
| IOS-D19 | Skill Hub 精选市场：特色轮播/分类货架/编辑封面、宿主区分远程浏览、不可变版本远程安装、只读容器、批量选择（71761f26/84e34641/9d8414bc/672e530c；CuratedSkillHub*、SkillWorkspaceInstall*、SkillHubDiscoveryView） | SkillsHubPage 仅镜像旧 SkillsView 分段；canonical shared FloeSkills 无上述文件 | 完整市场 UX＋远程签名安装链；安卓 Hub 频道以真实签名发布为开启前置；G02 范围后续→G11，关联 D16 | P1 |
| IOS-D20 | dependency-v1 依赖供给：dependencies.json schemaVersion 1 公开合同（docs/skills/）、签名 pip 哈希闭包经真实 requirements 输入、精确 apt 钉版、显式 Linux 环境、调用门控 | 安卓零处理；PRoot 与 TinyEMU guest 发行版/ABI 映射不同 | schema 合同对齐＋安卓等效安装时供给；Office/技能依赖消费前核对；G03 后续＋G11 | P1 |
| IOS-D21 | MCP 服务创建向导＋捆绑 node-http 1.0.3 模板/合同/来源 | 仅有 MCP HTTP 传输与连接器页；无作者化；iOS 侧长构建资格尚未全 PASS | 待 iOS 资格收敛后排等效；G11/G13 | P2 |
| IOS-D22 | 无限时长执行、单一可取消时长提醒、本地化提醒文案、Live Activities（LongRunDurationReminder、TaskActivityAttributes、TaskLiveActivityCoordinator） | 已有原生 RunForegroundService、任务租约、可停止通知及自有工作唤醒接线；本轮未重验前台通知体验。尚缺新的单一时长提醒；Live Activity 呈现需安卓等效 | 复用已有前台生命周期，补充单一／可取消／不自动续提醒合同；调度适配归 G11，呈现归 G14；关联 D12 | P1 合同/P2 呈现 |
| IOS-D23 | 后台下载/唤醒结算硬化：取消声明持久结算、唤醒前 drain、重放保留、冷刷新围栏（BackgroundWorkSession、BackgroundDownloadEventSettlement） | 已有任务及前台生命周期；本次源码检查未见 WorkManager／AlarmManager 调度适配 | 为 D06/D11/D12 补充合同证据；实装 G11 | P1（接线前冻结语义） |
| IOS-D24 | 供应商模型表单适配器：chat/图像/视频、区域保留、角色本地化、紧凑弹层（ProviderFormSpec） | G02 已有模型配置与凭据存储，无适配器表单 | 设置规格对齐；关联 D18；G02 后续→G09/G11/G14 | P1 |
| IOS-D25 | 相册保存动作先认领再异步授权、可操作权限/格式错误 | 属 G09 未实现面 | MediaStore 等效＋真实错误文案，不以命令成功冒充交付 | P2 |
| IOS-D26 | 工具结果分页/捕获存储/清理队列、空背景输出即完整首页（ToolResultPagingTool、ToolResultCaptureStore） | 共享谱系 8e7857b0 基线无此文件 | 按 SHARED_SOURCE_PINS 流程评审后再消费；扩展 D04 合同面 | P1（相关接线前） |
| IOS-D27 | 侧栏/composer/长按内联选择、滚动命中稳定、迁移 V53/V54 | 安卓自有实现保留 | 呈现打磨归 G14，查漏 G11；V53/V54 仅 iOS 历史库漂移留痕 | P2 |
| IOS-D28 | TinyEMU 9P 元数据保留、guest 描述符诊断、loopback 每次客体启动供给、受信组件边界 | PRoot 语义另立（§4），os.fstat ENOENT 各自保留为已知限制 | 实现机制不照搬；文件元数据、guest 诊断和本地连接的等效行为仍须核对 | 记录 |

### 本轮边界与后续顺序

- 此区间未发现 Office／手记／PDF 编辑保存代码的变更；名称含 Office 的新增素材属于 Skill Hub 封面。G05-R3 仍完成三格式代表性 App 编辑、保存、重开与成果交付，统一验证当前修复并发布阶段 APK。
- D19／D20／D26 在所属目标接线前核对公开合同并复用已有环境、安装与生命周期能力。内置 Office 引擎当前不消费新的 Skill 依赖供给 schema，不因此扩大本轮发行范围。
- D22 的安卓现状已由主审校正：`:core:runlifecycle` 已被 App 引用，manifest 注册 `RunForegroundService`，`FloeApplication`、会话和本地 Shell 连接任务租约。后续补差不能重复从零实现前台服务。源码接线不等于本轮重新通过其设备体验验收。
- IOS-D01..D18、183 项操作、85 个工作包及已有 G04 操作台账保持原编号和范围；新增 D19..D28 追加，不以缺少现成组件为由删除需求。
- 原生 IDE／编辑、文档预览、图标／布局／菜单、无障碍及手机控制、通知／后台／调度、GitHub 更新／ADB／Root／网络能力、新旧安卓及平板支持全部保留。未进入本次固定主线的工作树候选不作为已落地能力，收尾时再按真实提交补查。



## 2026-10-28 增量检查点

本段仅追加主线源码差异。安卓C12候选的实际安装、数据保留和文档预览已验证，但实际DOCX成果发布仍被独立修改范围证明拦下，修复中、尚未发行；不能用本段源码核对或419项检查替代App闭环验收。

比较基线：上次已验收盘点目标 `def7789317521fd00f3da62676420e5217e6041d`（上次已验收盘点，IOS-D19..D28 已合入 `docs/FLOE_ANDROID_IOS_DELTA_AUDIT.zh-CN.md`）→ 本次主线检查点 `456db1795e66d7c7889eef0ea046f20f59a95f44`（2026-10-28T00:44:53+11:00，本地 `origin/main` 读回一致，祖先关系核验通过）。区间共 **36 个提交**，其中 25 个触及 `FloeAgent/FloeApp|Sources|Tests`，iOS 侧 **61 个文件 +10769/−1741**；无 FloeWidgets、Resources、`.github`、scripts、skill-hub/content-hub 改动。安卓合格源仍为冻结 C12（`8ce0c8aa`，tree `249e43d3…`）；本区间 C08–C12 批次与 主集成 的 saved-content 修复已落入 main 的 `FloeAndroid/` 路径（19 文件 +2187/−155；`OfficePrecisionLedger.kt` 与 C12 逐字节一致），但**规范源选择与 App/设备验收仍归 主集成**。

### 对本次区间的结论

- 区间内**零提交触及 iOS Office/手记/PDF/保存合同路径**（`git diff -- FloeAgent | grep -iE 'office|notes|pdf'` 为空）：G05-R3 的 iOS 侧合同基线不变，不新增任何阻断。
- `project.yml@456db179 = 1.7.61/302`（版本号由 2cfc74df 携带），Feather 源记录 79b27884、1.7.61/302 发行注记与 build302 审阅记录均已入 main——即 gap34 时点"302 未落地"的提示已过时；但**源码落地不等于编译、Apple 处理或设备可用**，发布动作与验收仍全部在 主集成。
- 真正新增的用户可见能力仅一项：**会话置顶（IOS-D29）**。其余全部是既有行 IOS-D06/D08/D10/D19/D27 的补强证据，**不发明新功能清单、不重置既有 183 项操作与 85 个工作包**。
- gap34 已验收的更正继续有效：安卓既有 `RunForegroundService`（specialUse/wakelock/notifications，绑定于 FloeApplication/RunForegroundBinding/LinuxShellPump），本区间无任何相反证据；D20/D21/D24/D25/D26/D28 无新证据。

### 新增差异行（编号接续 D28，不重置旧行）

| ID | iOS 新落地 | 安卓现状 | 差距与归属 | 优先级 |
| --- | --- | --- | --- | --- |
| IOS-D29 | 会话置顶：V55 迁移 `pinned_at`（纯 ADD COLUMN，无回填；置顶组内最新置顶排最前，其余保持 updated_at 序；持久在会话行上，改名/归档/恢复/工作区移动保留置顶；临时会话晋升默认未置顶）——2cfc74df：`Migrations/V55ConversationPinning.swift`、`ConversationListView`(+167)、`ConversationCenter`(±132)、`ConversationStore`/`DatabaseManager`；`ConversationPinningTests`/`ConversationPinningStoreTests`（已写未由本审计运行） | canonical 安卓 app+shared 检索 `pinned/置顶` 仅命中打包/许可文件；`FloeSidebar.kt`/`ConversationProjections.kt` 无置顶概念 | 安卓对话列表/侧栏持久置顶等效（分组内排序、历史零回填解码、晋升未置顶语义）；G02 对话工作区范围后续 → G11 查漏 → G14 呈现收口；与 D27 同族但属用户可见持久能力，独立成行 | P2（非 G05 阻断） |

### 既有行的补强证据（不另起新行）

- **IOS-D19（Skill Hub 市场与远程安装）**：7ca58d58 经不可变公共端点取回已验证官方包（`SourceControlCenter.swift` +309、`SkillHubPublicTransportTests` +417）；9e5e27a6 目录刷新失败仍保留已验证目录可用（`SkillsCenter` +239、`SkillHubStoreFlowTests` +360）；2cfc74df 新增 `SkillHubDetailView/DownloadPanel/InstallService`，2a99be67/12fcdb1a/18275818/6f789420 收尾安装服务 actor 隔离、取消/校验传播与原生导航挂载。安卓差距本体不变（无精选市场 UX 与远程签名安装 App 链；Hub 频道仍以真实签名发布为前置）。注意源谱系差：main 的 `FloeAndroid/shared/.../FloeSkills` 已含 6940f196 时代 `CuratedSkillHub*` 同步，而合格 capsule 血统仍只有 `OfficialSkillHub.swift`/`SkillInstallStagingService.swift`——以 主集成 的规范源决定为准。
- **IOS-D08（临时/会话工具边界合同）**：2cfc74df 重写 `TemporaryChatToolPolicy`：临时会话上限从"仅公开网页"扩为两族（公开网页三件 + 六个已编译基础设备只读 apple.calendar/reminders/maps/home/watch/location，且仅用既有授权、绝不消耗系统唯一授权弹窗；`LocationServicesCenter` 新增 `allowsAuthorizationRequest` 门；`AppleSystemTools` 对临时读改为授权状态检查）。同时删除 `ChatToolPolicy.swift` 与其 345 行测试：普通文本/语音聊天不再有额外 chat-only 上限（AGENTS.md 不变量随该提交改写）。5d1a7690 让 AgentRuntime 先报临时工具边界再给泛化拒绝。安卓共享谱系仍持旧"仅公开网页"版本且从未有 `ChatToolPolicy`——消费前按 SHARED_SOURCE_PINS 逐项评审的既有要求由此具体化。
- **IOS-D10（预览/浏览器生命周期）**：f9212ca9 运行终端"浏览器打开就绪 Web 服务"动作：已提交/在跑的 `exec.localService` 作业经运行终端点击时重解析就绪端点并打开应用内浏览器，`BrowserURLPolicy` 按作业所有者授权/回收（`IDELanguageRunView`/`IDEWebServiceView`/`IDEWorkbenchState` 等 +800 行；`IDERunWebPreviewTests/UITests` 本次源码审计未运行）。安卓仅有 RunOutput PDF 预览/外启与个别 ACTION_VIEW 点，无 Web 服务预览入口——属 D10 义务的新入口面，不另立行。
- **IOS-D06（连续语音合同）**：2cfc74df 语音重复句折叠与每任务每句自动提交前幂等锚（`VoiceConversationView/Coordinator/Semantics`）；537fdaa5 修复回放碎片并在整段被拦截时同步围栏空规范化草稿（`VoiceBargeInSafetyTests` +66）。仍按 D06：先冻结音频会话/生命周期合同再排等效。
- **IOS-D27（呈现打磨）**：c25238e7 编辑态导航栏呈现多选（`InlineConversationSelection` +316/−184 等）、bc470a31 窄侧栏动作可见、8d88e9c1 标题按可见宽度自适应、1d8c3318 手势对已落位自有行、5ee1218e 受限 composer 回流不替换编辑面（`ComposerEditingPrimitives`/`ComposerReturnField` +337）及 fe75532a/451e7aa3/dce4c260/978d0703 测试与采集工具。V55 置顶属 D29 能力行，不归此行。
- **纯测试/记录类提交**（无独立差异行）：a888c0ac、720ed1fc、e3a049d5、2dba117b、5e750d28、b6897c6f、2642c474、79b27884，以及安卓批次 eef5d7f8/b5cf497b/029c50a7/b9c24f5e/8ce0c8aa/456db179 与合并 7b431db8/d4688cbb/0e414eea。

### 对下一目标顺序的影响

1. **G05-R3 范围不变**：仍为实际 Office 编辑/保存/输出/重开、新 APK、干净预发布与源码回读；本区间 iOS 增量不扩发本轮。
2. 编号继续追加：D29 为唯一新行；D06/D08/D10/D19/D27 只补证据。183 项操作、85 个工作包、24 项 G04 操作与 D01..D28 均不重置；用户完整安卓范围全部保留，新增均为补充而非替换。
3. 下一次大目标收尾的核对锚点为 `456db1795e66d7c7889eef0ea046f20f59a95f44`；届时若主线再有前进，只比较该 SHA 之后的增量。

诚实边界：以上均为提交源码与 canonical 源静态证据；本核查未运行任何构建、测试、设备或发布动作，iOS 302 批内新增测试套件为仅按源码记载，运行状态未在本审计重验。

共同合同补充：iOS临时设备只读的新增源码属于待评审差异，安卓当前仍按已冻结上限运行；消费前先核对当前用户与仓库约束，不自动扩大工具或授权范围。

## 2026-10-28：iOS 源码增量与 Android Skill Hub 对齐

> 本节只读源码盘点，不含任何编译、设备或发布声明。

### 增量检查点（接续 checkpoint86）

- 基线链：`def77893`（已验收，D19..D28 合入）→ `456db179`（ios-gap56 已验收，新增 D29）→ `83d46e4368e0b5cb619932e04103c29c819912e6`（ios-gap-checkpoint86 证明 456db..83d46e 对 `FloeAgent`/`skill-hub`/`capability-hub`/`ios-wheelhouse` 零差异）→ 本节。
- **已发布增量：零**。fetch 后 `origin/main` 仍等于 `83d46e`（2026-10-28T07:03:49+11:00）。
- 核对的 iOS 开发分支 HEAD=`98fea137669b34abc73db0fabb9000e511f43eef`，分支 `codex/skill-onboarding-20261028`：**尚未合入所核对的 `origin/main`，远端分支未见该提交**；工作树干净（`status --porcelain` 空）。`83d46e..98fea137` 共 19 个提交、62 文件 +20543/−832；`skill-hub/`、`capability-hub/`、`ios-wheelhouse/` 路径零改动；`FloeAgent/FloeApp` 触及目录为 App/Browser/Content/Execution/Onboarding/Remote/Resources/Settings/Skills/TTS/Voice，**触及 Office/Notes/PDF/Canvas 路径的提交为 0**（G05-R3 边界不变，无新阻断）。
- 版本事实（仅源码存在）：`project.yml` 在此**本地分支**上 1.7.61/302 → **1.7.62/303**，并附带 build303 release notes/REVIEW_NOTES 记录。本审计未核对 303 的编译、上传或分发状态，不能据 Git 分支状态断言这些步骤未完成；G05 收尾边界不变。

#### 新增差异行（编号接续 D29）

| 编号 | iOS 侧新增能力（证据） | 安卓现状 | 差距与归属 | 优先级 |
| --- | --- | --- | --- | --- |
| IOS-D30 | 完整原生初始设置向导与不阻塞资源准备：`Onboarding/SetupGuide*`（6 个新文件 +3142）、`SetupResourceModel/Preparation`（+1058）、`OnboardingView` 重写（±680）、`Localizable.xcstrings` +4964、`EnvironmentManagerView` ±172、`LocalModelsSettingsView`/`TTSSettingsService`/`WhisperModelStore` 接线；f476ae89/57a7032e/1f6612a7/ec6495f7/eed3228b/16f2ab34/e182aabc/98fea137；`SetupGuideUITests`/`SetupGuideRegressionTests`/`SetupDownloadOwnerTests` 等（已写、本审计未运行） | canonical C15 安卓源无 Onboarding/SetupGuide 任何对应面（app/shared 检索仅命中设置/隐私既有实现）；模型配置走 G02 设置路径 | 安卓首启引导/预设选择/资源下载编排等效（含取消/延迟落盘围栏语义）；按后续 G14/G11 评审，不入 G05；沿用安卓不做本地大模型的范围，仅迁移适用的云端配置、权限和资源准备 | P2（非 G05 阻断） |

#### 既有行补强证据（不另起新行）

- **IOS-D19（Skill Hub 市场与远程安装）**：`83d46e..98fea137` 新增共享模块 `FloeSkills/SkillHubShowcase.swift`（+569，全新）与 App 侧 `SkillHubMediaCenter/MediaView`（+848）、`SkillHubDetailView`(+53)/`DiscoveryView`/`SkillsCenter` 画廊接线；fba6ddf3/8cfa9ac3 出版物绑定封面与旧任务让位；9e276a58 安装经既有任务审批生命周期续跑（`ToolContext`、`AgentRuntime`、`SkillWorkspaceInstallTool`）；611a954d 画廊控件本地化。**规范安卓源差距不变且已独立核实**：C15 capsule 的 `shared/Sources/FloeSkills` 无 `CuratedSkillHub*`/`SkillHubShowcase`，Kotlin 侧无 Hub 客户端（见下方兼容性清单）。Curated 协议本身已预留安卓商店频道（`CuratedSkillChannel = { ios, android }`，频道根 `android/catalog.json`，iOS 主线 `CuratedSkillHubModels.swift:19-22、98fea 同`；`CuratedSkillHub.swift:124-133`），但所查仓库路径未包含 android schema-3 feed；独立 Skill Hub 仓库的在线发布状态未核对，iOS App 硬连线 `channel: .ios`（`SkillsCenter.swift:94/106/121/333`）。
- **IOS-D06（语音合同）**：e47cd1e3 待提交语音选择的幂等保留与进度快照一致性；eed3228b 缺失资源语音预览/下载状态本地化——D06 冻结音频合同前先照此补核。
- **IOS-D10（预览/浏览器生命周期）**：a5be00de 集成已验证的浏览器文件导出合同与事务（`BrowserStagedExportServiceTests` 已写未运行）——D10 义务的新出口面，不另立行。

### 安卓 Skill Hub 实际兼容清单（canonical C15 capsule 源码事实，行号为据）

> 独立于早前基于过期 `Root/FloeAndroid` 的报告重做；下表全部来自 C15 规范源逐文件核对。capsule 的 `SOURCE_SNAPSHOT.json` 把共享 Swift 输入钉在 iOS 侧 `12e36ba7b41d24634526ea55568fe88e4de26745`（2026-10-22）：`shared/Sources/FloeSkills` 为 19 个指向该钉定快照的相对符号链接镜像 + 2 个 capsule 自有常规文件（BundledDomainSkills/ContentPackageCodec）；C15 提交 `e00925af` 已核验为 `origin/main@83d46e` 的祖先（安卓 Kotlin 侧修复，触及 Hub 源为零）。

1. **模型谱系＝旧官方目录面**：2026-10-22 钉定快照本身不含任何 `CuratedSkillHub*`（4 件套在 2026-10-26 的 6940f196 才进入 iOS 主线，晚于 10-22 钉定），capsule 有效输入即 `OfficialSkillHub.swift`/`SignedContentFeed.swift` 谱系（schema-2 `skill-hub/catalog.json`+`catalog.sig`），亦无 `SkillHubShowcase.swift`。
2. **客户端/发现＝宿主投影**：`feature/integrations/SkillsHubPage.kt` 逐段镜像旧 iOS `SkillsView`（分段卡片/启停/更新/删除），可用性完全来自宿主投影，无独立 Hub 客户端；无 Curated 画廊/精选/媒体面。
3. **目录刷新已接线但按设计 fail-closed**：`RuntimeFacadeSkillsService.swift:779-795` 复刻原 `refreshOfficialCatalog`（小时闸、不可变 commit、编译内信任根、失败保留旧缓存）；但 `:791-792` 先取 `validatedAppVersion(hostContext.appVersion())`，而 `G02ProviderImplementations.swift:398-402` 的 `appVersion()` **硬编码 nil**（注释明示"受信宿主在集成时绑定真实语义版本"），故当前所有目录/升级流抛 `.appVersionUnbound` → `needsConfiguration`（`:2579-2580`）。传输层已经由 `SkillsRemoteTransportComposition.makePublicHubTransport()` 组成进 `G02DomainServices.swift:298-304`（`RuntimeFacadeSkillsTransport.swift:193-203`；文件头"NOT registered"为候选期陈旧标注）。
4. **平台判定**：capsule `SkillPlatform` 仅 {ios, macos, linux}（`shared/.../SkillModels.swift:18-22`），安卓运行时环境投影为 `platform: .linux, supportsJavaScriptCore: false, hasRemoteExecutionHost: false`（`RuntimeFacadeSkillsService.swift:2046-2053/2090-2098`）；`SkillCompatibility.evaluate` 以 `package.supportedPlatforms.contains(environment.platform)` 判不符。所查仓库包样例 manifest 声明 `platforms: ["ios"]`（`skill-hub/sources/*/floe.json`），故官方包在安卓上会诚实判 `.unsupportedPlatform(linux)`——即便版本绑定后也不会"顺带可用"。iOS 主线已为 `SkillPlatform` 增补 additive `android` case（98fea137 `SkillModels.swift:28-30` 注释：未列该值的 manifest 不变，旧构建对新值 fail-closed）；capsule 尚无此 case。
5. **安卓版本域≠iOS SemVer 域，禁止假定等价**：APK 身份为 `floe.version.code=16` / `floe.version.name=0.1.0-alpha.14`（capsule `gradle.properties:14-15`），运行时互证绑定 `versionName/versionCode` token（`core/runtimeipc/.../RuntimePeerProof.kt:62-67`）。capsule 版本闸只接受"数字+点、≥2 段、≤64 字节"（`RuntimeFacadeSkillsService.swift:2292-2298`），原始 `0.1.0-alpha.14` 不过校验；宿主绑定时须选域内投影（如 `0.1.0`）。而 iOS 域目录条目 `minimumAppVersion` 为 1.x（schema-2 catalog，如 floe-pdf 1.5.3；iOS 组件域 `minimumCapableAppVersion = "1.7.60"`，`SkillDependency.swift:25/177`；schema-3 要求严格 X.Y.Z 并对打包条目强制该字段，`CuratedSkillHubModels.swift:655-670`，比较用 `SignedContentVersion`，定义于 `SignedContentFeed.swift:25`）。数值比较跨域会把 `0.1.0 < 1.5.3` 判为全量不兼容——**正确路径是给安卓频道按安卓域书写下限**，仓库已有先例：`skill-hub/android/guides.json`（schema 1、`platform: "android"`、`minimumAppVersion: "0.1.0"`）与 `build_android.py`（"从不按 OS 名推断二进制/脚本兼容"，guide-only；脚本包需另行作者化/资格）。
6. **映射要求（供 D19 收口）**：安卓 Hub 等效需 ① 在受信集成处绑定安卓域 appVersion（或显式扩展域验证器）；② 发布 android schema-3 频道 feed（协议路径/前缀 `android/` 与 installPlatforms-含频道校验已就绪，`CuratedSkillHubModels.swift:848/936`）或在 capsule 引入 Curated 谱系；③ 包 manifest 增列 `android` 平台并复核 capability 集（capsule 无 localPython/localJavaScript）；④ 执行 OS 枚举当前不含 android（`CuratedSkillHubModels.swift:866` 允许 linux/macos/ios，安卓脚本包若经 PRoot 执行仍以 linux+证据映射，需集成时明确，勿静默复用）。注意：把 capsule 快照在后续升级时重新钉到更新 iOS只会自动带入 Curated*/`SkillPlatform.android` 等共享协议输入；Kotlin 客户端、画廊 UI 与 appVersion 绑定接缝仍需另行作者化，不因重钉出现。

### 下一收尾锚点

- G05-R3 实际收尾时：先读回 then-live `origin/main`——若仍为 `83d46e`，已发布增量继续为零；再判断 `codex/skill-onboarding-20261028`（98fea137，含 1.7.62/303 与 D30 素材）是否已合入，若有则仅按本节方法对合入后主线做增量。源码存在 ≠ 编译 ≠ 上传 ≠ 设备安装。

本轮保持已固定的 Android 原生输入；上述 Skill Hub 协议和设置向导差距纳入后续目标，不能通过在 G05 中整体刷新共享快照或冒用 iOS 版本号来消除。脚本能力仍应复用统一 Linux 环境与现有执行服务。



### 2026-10-28 发布前增量检查点（非 G05 收尾结论）

再次读取远端后，`origin/main` 从 `83d46e4368e0b5cb619932e04103c29c819912e6` 更新至 `e528e444b462a7c3f03346fb3fe53af836885d2a`。区间仅修改 `.github/workflows/floe-skill-hub-auto-publication.yml`；`FloeAgent/`、`skill-hub/`、`capability-hub/`、`ios-wheelhouse/` 的源码差异均为零。iOS 活动工作树 HEAD 仍为 `98fea137669b34abc73db0fabb9000e511f43eef`，尚未成为该远端 main 的祖先；既有 IOS-D01..D30 编号及后续归属保持不变。本检查不代表 Android Hub 客户端已完成，也不代表 iOS 的编译或分发状态。

G05-R3 当前仍在修复后的统一编译及 App 验收阶段，实际大目标收尾时再次读取主线，只补查此检查点之后的增量。

### 2026-10-29 C19 公共源推送后的增量检查点

再次读取远端后，`origin/main` 从 `e528e444b462a7c3f03346fb3fe53af836885d2a` 前进至 `5ed31c1628f83877b3ce3969d9b34b34e65f79b6`（C19 公共源，已由 GitHub API 独立读回；尚无 tag 或 Release）。区间共 **3 个提交**：`1312beb9` 仅把 Feather 源发布工作流按 App 标签命名空间守护；`48c5771` 与 `5ed31c1` 只修改 `FloeAndroid/`（Alpha14 自更新、Office 传输与任务策略修复，以及冷开 Full access 解码）。**`FloeAgent/` 的 iOS 源码差异为零**，没有新的 iOS 能力、界面或合同变化；IOS-D01..D30 编号与后续归属不变，本检查不新增差异行，也不重启全审计。

最新 iOS 正式发行仍为 `v1.7.61`（build 302）；Android 尚无 Alpha14 公开 Release，本次推送只改变 Android 源码与一条 Feather 守护工作流。G05-R3 实际收尾时仍以届时的 live `origin/main` 为锚点，只补查本检查点之后的 iOS 内容增量；本地未合并的 iOS 工作树不属于公开基线。


### 2026-10-29 G06 启动参照

最新公开主线从 `5ed31c1628f83877b3ce3969d9b34b34e65f79b6` 前进至 `96cd41c92ad20a8070776887ccbf3a3967e7d8a3`，新增提交属于云端 Skill Hub 签名转发基础设施；`FloeAgent/FloeApp` 与 `FloeAgent/Sources` 差异为零。本轮按该公开源固定手记参照，复用 FloeNotes 的资料、编辑、资源、导图与归档模型，新增 Android 宿主、编辑界面、PDF/笔迹和助手适配。保持 IOS-D01..D30 身份及既有后续范围；不将未合入 iOS 工作树视为公开基线，不整体刷新已验证安卓原生输入。


### 2026-10-30：G06 实测期间的 iOS 增量对齐

基线为 `96cd41c92ad20a8070776887ccbf3a3967e7d8a3`，实际公共主线参照为 `90da89dbc1ee9c6e38bc0bb313547ecb192b6ba6`（tree `8ea1fd124929ff2bbc33470afcc1deab42bde7d9`）。GitHub API与本地对象读回一致，祖先关系已核验。区间55个提交；`FloeAgent/FloeApp`与`FloeAgent/Sources`合计109个文件变更。后续安卓提交`1f267e1b`没有新增iOS源码差异。

`Sources/FloeNotes`、`FloeApp/Notes`与`FloeApp/Canvas`本区间均无产品代码变更，手记参照保持。已有IOS-D01..D30身份及归属不重置；D05/D06/D09/D10/D12/D15/D16/D18/D19/D21/D22/D24按现有目标补强，不为本次G06另起全量审计。

| ID | 新增实际源码差异 | 安卓安排 |
| --- | --- | --- |
| IOS-D31 | `FloeMacBridge/`、`MacBridgeClient`/`MacBridgeShellBackend`及受信环境租约：同机Mac执行后端，断连保留任务身份、报告未知结果而不自动回放 | 平台专属，不移植宿主终端或公证分发；未知结果语义并入D33，P2记录 |
| IOS-D32 | `StorageSuspensionCoordinator`、`StorageOperationBudget`、数据库挂起/恢复、文档所有权租约；`OfficeDocumentEditorView`失去所有权后只读并保留副本 | P1合同：后台写入可取消、外部改动保留副本与明确只读；不把iOS后台断言照搬为安卓保活，不宣称当前已等效完成 |
| IOS-D33 | `ToolContext.approvalOrigin`、`RuntimeNestedApprovalHandle`与`outcomeUnknown`：执行中审批复用单一等待面，未知执行结果禁止重放 | P1合同：下一次共享谱系/工具结果接线前核对，保留安卓现有权限围栏，不扩大本次修复批次 |

G06尚未关闭或发布。文本保存与重开状态已修复，并通过三星实际保存及强制停止后重开；Office准备、PDF背景、手机操作层级和完整工作区导入仍需闭合。下一批集中编译/设备复核这些改动，已通过的定向证据复用。上述新增系统差异登记为后续输入，不预排工作队列。

下次大目标收尾从`90da89dbc1ee9c6e38bc0bb313547ecb192b6ba6`之后的实际iOS源码增量继续核对。以上差异审计是源码/元数据证据，不代表审计任务运行过iOS编译、Apple处理或设备安装。

### 2026-10-30：G06 收尾前的公共主线增量（`b469c25b` → `ac11bdf0`）

- 读回：`origin/main` = `ac11bdf05f7c829dd712c6c0c7a8ad198996c73d`（2026-10-30T07:46:26+11:00，tree `0c61c75c09f5e6b3d2895a0e5ac85a8f003ca8b3`）；基线 `b469c25bf11bd88bfb551ef346d7c31a1b82134d`（tree `35790e2d9c7302e0469070d5e6d7af9981ea4a24`）。`90da89db` 至 `b469` 的 `FloeAgent` 差异为零（仅 Android/Feather 提交），`b469` 是 `ac11` 的祖先；区间 11 个提交，其中 4 个触及 `FloeAgent/FloeApp|Sources`。
- 范围：仅 `FloeAgent/FloeApp` 与 `FloeAgent/Sources`，32 文件 +24700/−19592；逐文件变更行数与预计算 `SOURCE_DELTA.stat` 一致（stat 只给增删合计；路径缩写宽度不同）。`FloeAgent/ThirdParty/FloeCADKit` 另有 54 文件 +14156/−241，属 vendor 输入，未计入本 32 文件，也不据此声称已进入安卓共享源。
- **G06 结论：当面无功能变化、无新增阻断。**`Sources/FloeNotes`、`FloeApp/Notes`、`FloeApp/Canvas`、Office/PDF/笔迹产品文件均为 0；`Localizable.xcstrings` 仅新增 162 个键（153 个 `cad.*`、9 个 provider 连接/发现键），既有键与值零改动、零删除。手记参照、PDF/笔迹合同和 Office 保存/重开路径不漂移；待验证项仍是最终 APK 的连续笔迹/保存/导出、终端关闭文件导出与手机头部几何。
- 分类：provider/content 正确性 17 文件 +921/−87（端点身份、订阅连接探针、发现闸、图像/视频 wire family、catalog 限额、服务角色语义、provider 内容包基线 1.1.1→1.1.2）按 D18/D24 既有行补强，归 G02 后续/G11/G14，不进入 G07；原生 CAD 编辑 4 文件 +863/−13（material/parameters/capture、共享材质库、canvas-cad 所有权）新增 D34，归 G10；本地模型 CAD 暴露 2 文件 +180/−28 因安卓不做本地大模型排除；共享管线 6 文件 +95/−8 的新行为限定于 `cad.document`、canvas-cad 键或 CAD 视口 artifact 前缀，`document.*`/`office.*`/`notes.*`/`canvas.*` 的 typed target、mutation lease 与普通文档审批不变；CAD 测试夹具 1 文件 +13，资源 2 文件为 catalog/字符串。
- 新编号（接续 D33）：

| ID | 新增实际源码差异 | 安卓安排 |
| --- | --- | --- |
| IOS-D34 | `cad.document` 新增 `material`/`parameters`/`capture`：共享材质库合并写、特征参数与既有圆半径更新、真实视口 PNG（revision/change_count/图像与内容摘要分离）、canvas-cad 冻结映射、修订钉与临时会话只读拒绝；同批 `FloeCADKit` vendor 为输入 | G10（G07–G09 之后）；复用统一几何内核、typed mutation 与审批，不把 RealityKit 捕获当安卓等价；canvas-cad 只接受冻结的 conversation→canvas→package 映射；不扩 G06 或当前发布 |

- 既有 IOS-D01..D33 身份与归属保持不变；D34 不改变 G06 收尾顺序或 Android 当前批次。下次收尾继续比较 `ac11bdf0` 之后的实际 `FloeAgent/FloeApp|Sources` 增量。以上仅为源码/元数据静态比对，未运行 iOS 编译、测试、设备或发布。

### 2026-10-30：G06 阶段交付后的最终增量复核

G06以Android Alpha15/code17交付，源码标签`86b20a34a14ebda636213fa480cdf14f8d4fee05`，实际APK与公开附件哈希已通过。收尾读回公共main为`b7feb3f8fe749ec730e27444dda02f909d7d47c9`；`ac11bdf05f7c829dd712c6c0c7a8ad198996c73d`之后的`FloeAgent/FloeApp`和`FloeAgent/Sources`差异为零。本次只关闭安卓交付和文档，不自动重钉共享源码；此前D01..D33与D34安排完整保留。下一目标仍为G07网络/Wi-Fi，后续从本次iOS基线继续做增量核对。实体笔硬件、OCR真实推理和紧凑列表优先的验证/精修边界保留。
