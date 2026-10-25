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
