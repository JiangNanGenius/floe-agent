# 安卓全应用代码收口

2026-11-03 当前状态：同源 Alpha23/code26 私有候选已覆盖三星和平板，原件文件读取及终端正常退出已有三星实际回执；手记全窗口、PDF 缓存重开和窗口明暗状态已修复并保留原始故障。一次 Ark 真实任务发现的终端回传失败已修复基础运行时链路，修复后的模型成果附件完整通路尚未复测，不把手动终端成功算作模型交付成功。公开 APK 尚未发布。原183项编号和历史状态保留，尚待源码逐项对账108项；此数量不是缺功能数量。新确认压缩包安全引擎缺 Android 可达入口，需补实现；手动 Office 原件保存与 Git 远端拒绝回执正在独立代码包推进。

2026-11-03 设备验收增量：顶栏执行位置遮挡已修复，源码 `481da898` 已推送读回；同源 Alpha23/code25 候选03正式签名整包检查通过，并覆盖安装到三星与复用的 API37／16 KiB 平板模拟器。三星通过 App 内组件安装流程更新至 code25，两个手动终端分别返回真实输出，关闭其中一个不影响另一个，结束后两者均已关闭。平板确认设置左右两列及本地组件安装路径。仅做了一次 Ark Agent Plan／ark-code-latest 激活：交互终端实际输出 A23_ARK_TERMINAL_OK、exit0，但原 exec.shell 因执行目标解析失败未被提供，故不能计为该工具验收通过，也不自动重复云端测试。

本次已定位并修复真实环境目录异步回执被当成结果读取的问题，增加同请求身份、完成、失败、超时和取消处理；5项定向回归与12项既有计划环境测试通过，Full／Play Kotlin通过，执行目标缺失／SSH目标的本地会话边界和旧服务指南同步修正，两份ARM64原生产品对象／链接通过。另发现对话按HH:mm排序导致跨日新消息显示在旧记录之前，已改为完整时间戳，集中验证继续。设备验收还发现“完整任务导出”目前错误地只分享已加载Markdown，真实完整结构化导出接线保留为未闭合项，不能以按钮存在销账。尚未发布公开APK。已清理被替代候选02安装包及root助手一次性构建目录，回收约308MiB；保留现用包、原生符号、故障记录和下一轮缓存。

2026-11-03 集中 JVM 验证：首次运行应用 2,087 项测试，保留原始 317 项失败；修复未绑定平台上下文时的设备服务初始化、工程包图片头读取、日历发生项标识往返、语音空结果终态、个性化生成旧回调竞争及联系人默认分页。同步纠正与真实协议不符的测试夹具，保留取消、CAS、保存及摘要不匹配断言。仅复测失败所属套件，最后一组 15 项通过；按精确测试身份合并最新结果后，原 2,087 项全部有通过证据，没有跳过。此结论复用了未改组件证据，不是再次完整运行 2,087 项；不能替代 Android 设备及实际安装升级验收。原生最新产物已保存，清理约 353 MiB 被替代的原生副本与完成的私有索引，保留故障记录、现用产物和后续构建缓存。尚未发布新 APK。

2026-11-02 最新增量：MCP Node 依赖准备与活动 Linux 工作区新增输入检查点 `34850c3cfc86173fff59b66d198d0a88a89fb2c5` 已推送读回；对应 ARM64 Core／LinuxAuthority 对象编译和链接成功。手记增加独立阅读模式，保留页面渲染、翻页和缩放，屏蔽画布编辑与写入快捷键。工程自动封面沿用固定离线 CAD 查看器、授权手记资源及真实画布截图，串行限额、取消和失败回退均已接线；不将图标或标题冒充截图。最新 Full Kotlin 编译通过；尚未在设备验证封面渲染、MCP 自动安装及活动工作区新增输入。覆盖范围为单文件工程资源，依赖外部侧文件或目录包时保留普通封面。原 183 项逐项对账和最终整包验收仍待完成，未发布新 APK。

状态：C01–C08 全应用代码收口推进中，使用普通任务模式；固定复用基线 `a59b4d4005f616c611df67fab7620e9853c525b9`。已读回源码检查点推进至 `89d96bec774b4e5aac7f4e9e1cc92a2628dea201`，本文件所在提交另含 MCP 依赖准备、活动 Linux 工作区新增输入及手记阅读模式。Full／Play Kotlin 和两份 ARM64 原生核心已分别完成一轮编译；升级模块 89 项、工作区模块 70 项测试通过，原生最新增量和整 APK／设备验收仍待完成。三星当前安装的构建24与公开 Alpha22 安装包摘要一致；本轮未发布新 APK。全代码收口前只推源码检查点，不发布新公开 Release；G09-R2完成事实保留，原G09-R3立即发包安排由本计划替代。下方较早检查点按其当时源码阅读，当前状态以本节和末尾增量记录为准。

| 批次 | 代码范围 | 当前状态 |
| --- | --- | --- |
| C01 | 会话置顶、供应商地区保存、项目库／任务归属、模型终端会话、环境状态、长运行服务与网页预览 | 置顶、地区、项目、多会话、持久服务／预览及环境目录源码已集成；任务目标与MCP专用原作业上下文已接入源码，后续集中验收未完成 |
| C02 | 执行目标固定／迁移、存储／提问审批／结果连续性、浏览器隔离、完整Hub与MCP | Hub、结果分页、连续性、目标固定／迁移及真实 stdio 管道源码已集成；MCP无模型调用的原运行上下文、HTTP服务适配与新stdio绑定入口已接入源码；依赖自动准备及集中验收未完成 |
| C03 | 系统默认／可选云语音、文件转录字幕、媒体图库保存与缺失编辑／转场／HEIC能力 | 语音、图像／图库、视频共同合成与 HDR 边界已源码集成；待集中编译、测试和 Android 验收 |
| C04 | .floecad、DWG/DXF与既定通用3D格式只读预览，真实视口与截图 | 离线查看器、原生目录包、BRep 派生表面与截图保存已源码集成；待集中编译和 Android 验收 |
| C05 | SSH／VNC及TCP/Telnet、BLE GATT与USB串口 | SSH／SFTP、VNC／RDP、TCP／Telnet、BLE／USB 和桌面辅助源码已集成；真实环境归属与文件暂存仍依赖 C01，原生生产及运行验收待集中完成 |
| C06 | 邮件、日历、待办、系统数据与硬件接口、VPN／Root抓包 | 系统服务、邮件、日历待办、抓包与 Root 守护源码已集成；统一迁移52已登记，真实助手／网络／硬件验收待完成 |
| C07 | 分享／深链／通知返回、引导、备份交换／反馈、布局图标与材质 | 材质、分享入口、持久用户数据、MCP定义及Office保存副本交换源码已集成；描述符目录修复已合入，待集中备份恢复与权限验收 |
| C08 | 既有操作台账逐项闭合、迁移／渠道／许可与最终源码冻结 | 原183项编号保留；固定源码33项编辑操作静态对账已完成；统一迁移52已登记，剩余逐项对账、代码缺口和最终冻结待完成 |

语音只使用Android系统接口及用户配置的云服务，不内置、下载或维护App本地语音模型，保留已保存选择，默认系统语音。PDF本地预览，模型通过任务所属Linux的exec.shell自行寻找、安装和使用通用工具处理文件，验证成果后回App查看；不增加原生PDF编辑工具别名，现有手记功能保留。CAD仅查看，包含原生.floecad目录包，不增加建模。暂不建设双端实时同步，完成显式备份、导入导出和文档包交换，默认不携带凭据。

沿用任务、环境、授权、凭据、作业和存储服务；所有操作带实际task/environment/root/owner，外部路径和模型文本不授予权限。SQLite迁移登记只有单一所有者，兼容已有R2表，不叠加旧V50补丁。Hub保持签名、平台、版本和回滚校验。iOS复用字节从固定Git对象获取，不从旧根工作区同名源复制。

每批先完成连贯代码，只在确切接口／编译阻塞处提前检查；收齐后集中编译与定向测试，复用未改组件证据。实施任务按实际输入和互斥写域派发，不预排依赖队列；构建串行。每个阶段源码推送后读回远端；仅删除本任务确认不用的生成物，保留交付／回滚／故障证据及马上使用的缓存。

复杂调查、跨模块实现和有完整交付边界的工作交给 OpenCode，默认 Normal／auto。已完成任务中的少量、原因和影响清楚的小修复，以及测试后的定点修正，由主协调者直接实施并做对应检查，避免高于修复本身的交接成本；仍有活动写入者时先交回该所有者，不并发抢改。短改动若原因未明或影响较广，仍按调查／实施包处理。

当前执行约定：OpenCode 已恢复，Normal／auto 承担输入就绪、写域明确的连贯代码包；主协调者负责集成、编译和设备验证。派发前检查活动所有者，写域重叠先交接，未就绪的后续要求保留在计划而不预排任务。

代码收口之后再构建同源ARM64核心和实际使用的一份Full APK，完成三星与最新平板的代表性流程、更新和增量核验，Root只在受控模拟器验收。通过后发布下一空闲Android预发布版本，保留iOS Latest，附件只放安装包和必要更新／校验／源码许可文件。

必需项必须有真实入口、后端和失败路径；未配置、未授权、设备不支持分别报告，缺代码不得改称平台限制。编码期不调用真实App云端；最终确需时只做最小实测，失败即停。大批次收尾增量核对iOS，原编号和旧证据不重置。

## C01 第一源码检查点

会话置顶已接入持久化、历史列表／搜索、归档保留和菜单入口；供应商地区字段贯通读取、编辑、保存，旧客户端省略字段时保留原值。单一迁移版本为50，保留已有R2表及selected_at。新增针对性测试源码，尚未执行本批编译或测试；这不是新的可安装版本。项目库及模型终端／服务仍在实施，随后继续C02–C08。

## C01 项目源码检查点

用户项目库、项目详情、侧栏与新建任务项目选择已接通源码；任务仅在首次运行前绑定，旧文件不自动搬动。项目文件、编辑器和终端根解析复用同一工作区记录；网页预览的两处目录适配留给Linux包统一合并。删除以单个SQLite事务核对版本及已围栏任务集合后重归属，明确停止时等待真实作业排空；显式移除文件使用目录描述符和不跟随符号链接的相对操作。默认保留项目文件并返回保留位置，备份／恢复包后续接入这些保留目录。源码未统一编译或执行新增测试；不代表设备可用，也不发布新APK。

## C03 语音源码检查点

系统语音默认、可配置云端识别／朗读、有限时长云端听写、音视频分段转录及字幕回填已接通源码。长文件按真实音频解码分段，保留源时间映射；未返回时标的提供商不能伪造字幕。设置通过原有app_settings做原子CAS，取消等待真实请求结束，重复分段不重复上传。临时对话仅使用不落盘的系统文本听写，云端录音入口不创建隐含持久任务。权限、设置、对话与媒体入口已接线；未调用真实云端、未编译或执行新增测试。C03其余媒体能力与C01–C08未闭合项继续推进。

## C02 Hub 客户端源码检查点

Android平台与0.1.0兼容版本独立绑定，完整schema 3目录消费与旧四项目录分别处理；安装、升级和回滚复用原校验、暂存与日志。缓存收据保存签名原文，加载时结合实际包重新核验，不以JSON中的“已批准”字段授予信任。浏览卡片入口已接入源码。Linux依赖准备代码已实现，但四处终端与注册钩子留给Linux包统一合并；目录详情入口与分页、运行时组件适配、任务连续性与MCP仍未闭合。Android签名内容包供给独立记录，不修改版本号或跳过校验宣布可安装。新增源码未编译、未执行测试、未进行App联网或提供商调用；这不是新Release。

## C03 图像源码检查点

图层填充、剪切、合并、复制，图库保存回执及 AndroidX HeifWriter 1.1.0 已完成源码集成。模型与界面复制选区共用同一合成顺序；能力标志跟随真实渲染器绑定状态。现有图片导出为 8 位 SDR，遇到已识别的 HDR／高位深来源明确拒绝，不静默转换。补齐许可资源及中英文导出边界。

本检查点仅为源码：Kotlin／Swift 编译、已编写测试、像素一致性、真实编解码／图库／取消行为及设备验收均未执行。视频合成仍待完成，C03 整体尚未闭合，不发布 Release。

## C04 查看器源码检查点

已接入固定 iOS 源的离线查看器、真实 `.floecad` 目录包、网格／实例／变换／插入图片、BRep 离线派生表面和实际视口截图保存。派生 glTF 使用米制坐标，显示信息保留源毫米语义；WebP 使用派生 PNG 纹理，不改原件。截图通过系统文件选择器保存，并读回校验字节数和摘要。

截图、导出和清理由应用级任务持有；停止超时返回未完成，保留真实排空任务，不提前删除仍在使用的临时资源。代码尚未在 Android 编译或运行。真实格式显示、WebGL、截图与 SAF、停止时序、原件不变及旧三星／最新平板兼容性统一验收。BRep 材质与解析表面不冒充原始建模数据，超出预览资源上限明确提示。

本次增量对账比较公开主线 `afdb846` 与固定源 `a59b4d4` 的 `FloeAgent/`：没有新增 iOS 源码差异。保留原差异编号；未合并开发分支不替代本轮固定复用源。C05–C08 和其余未闭合项继续推进，不发布 Release。

发布文件检查发现原 DWG WASM 含构建机绝对路径，故从固定 Rust 源与原 Cargo.lock 定向重建，使用路径重映射而不修改二进制字符串。保留原资源摘要、派生记录、原工具链及 384 MiB 内存上限。重建后组件样例 DWG→DXF 读取通过；Android WebView／App 验收仍未执行。其余上游资源和版本固定记录不变。

## C03 视频源码检查点

视频预览和导出共用同一合成计划、双轨交叠及逐帧透明度规则，保留裁切、变速、旋转、音量／静音、音乐和字幕路径。无有效交叠或超出双画面合成范围时明确拒绝，不降为硬切。转场覆盖帧使用实际透明源帧，避免空档帧改变时间和色彩语义。

HDR 输出范围为 HDR10／HLG 静态信息；真实编码器能力不足、HDR 混合或 HDR 转场明确拒绝。最终成果核对色彩与静态信息，拒绝静默降为 SDR。已识别的杜比视界、HDR10+ 等动态 HDR 明确拒绝；元数据未暴露动态信息不等于已证明保留任意动态侧数据，导出页说明支持范围并保留来源原件。

媒体解码匹配改用实际轨道 MIME，避免将 MP4 等容器类型当作编码器格式；轨道读取失败不默认推断为 SDR，依据 [Android 轨道格式接口](https://developer.android.com/reference/android/media/MediaExtractor#getTrackFormat(int))。本批没有执行 Gradle／App 构建、已编写测试或设备验收；已有 API 定向检查不能代替真实预览／导出一致性、音频转场、取消、图库及 HDR 验收。

## C05 SSH 基础源码检查点

复用固定 iOS 源的 Citadel／SwiftNIO 核心，接通真实主机配置、凭据网关、主机密钥确认、跳板、独立 PTY、远程命令和仅回环隧道；使用现有终端渲染组件。补入原依赖固定版本、许可证和真实界面入口，修正 CAD 通道缺失版本声明。

该检查点仅为主机端 SSH 基础代码。Android 37 局域网授权接线、所有异步界面的根实例／请求隔离和 C02 的模型远程执行目标绑定仍须闭合；主机界面通道不能代替任务授权。未执行依赖统一解析、Swift 6 对象编译、Android 编译、网络或设备验收，不标记 C05 整体完成。

外部提供商和模型默认开放给用户配置，配置满足后允许调用；开发者的订阅、余额或真实账户实测不作为设置、调用或交付门槛。保留编译、契约与生命周期检查，实际服务错误走正常错误路径，未实测情况如实记录。

## C02 完整 Hub 客户端源码检查点

完整目录使用独立分页和全目录搜索，详情页保留平台、版本、依赖、安装审查及回滚信息。自动分页预算达到后可以继续加载，旧四项包目录独立保留；列表、详情和搜索结果按真实根实例隔离，停止时失效。依赖准备通过任务所属 Linux 执行已验证的签名组件，保留摘要、平台、版本及探测校验。当前未提供的 Android 签名供给如实记录，不跳过校验。

该批只推进源码，未运行编译、已编写测试、App 联网或设备验证。终端依赖门禁仍与 C01 统一接线；执行目标、任务连续性及 MCP 继续实施，C02 整体尚未完成。

## C06 抓包源码检查点

无 Root 抓包已接入固定 NetBare 核心、真实 VPN TUN、IPv4 TCP／UDP 转发和持久通知。IPv6 显式绕过，ICMP 不冒充已转发；加密流量不做中间人解密。停止等待线程、转发器和写入排空，未证明停止时保留部分文件；落盘失败不返回成功。IPv6 行为按 [Android VPN 地址族接口](https://developer.android.com/reference/android/net/VpnService.Builder#allowFamily(int)) 显式设置。

Full 已接入受控 Root 抓包协议，生产助手的固定源码构建、打包及校验安装链路仍待补齐，不能把缺助手当作功能完成。原始 PCAP 暂留应用私有目录，显式导出列入 C07。邮件与日历待办实施中，系统硬件接口继续推进。保留 NetBare 上游 MIT 文件及源文件 GPL 通知，最终分发按实际许可履行源码与通知义务。此为源码进展，没有执行 Android 编译、真实 VPN／Root 或设备验收。

## C06 邮件源码检查点

邮件账户设置、IMAP／POP3、SMTP、分页读取、正文和附件、发送及邮件变更已接入真实协议后端与系统 TLS，包含主机名校验和 STARTTLS 失败路径。密码只经现有凭据网关保存，发送和变更使用持久回执处理不确定结果，不能自动重发。账户和邮件界面、七个模型工具、局域网授权及根实例退出排空已接线。

新增账户表纳入 Main 统一迁移入口，兼容原 v1–v50 和 R2 数据；本轮其他持久字段仍由 Main 统一并入后续源码冻结，实施包不自行叠加迁移。该批未编译、未执行已编写测试，也未连接真实邮箱或发送邮件。用户配置可用账户后允许使用，开发者真实账户测试不作为开放条件。

## C05 VNC 源码检查点

VNC 复用固定 RoyalVNCKit 的真实 RFB 协议核心，画面使用有界二进制分页传输，接入缩放、平移、鼠标、键盘和滚轮；离开画面、后台和断线释放输入。支持独立 VNC 主机与 SSH 隧道，凭据引用限定 VNC 命名空间。SSH 和 VNC 共用真实局域网授权入口，异步请求、会话和根实例分别隔离。

已合入六处主接线并保留邮件、抓包的新入口和退出钩子，补齐固定依赖与应用许可资源。该批仅为源码；统一依赖解析、Swift 6 对象／JNI／Kotlin 编译、真实连接与断线输入释放尚未验收。模型远程执行目标由 C02 接通，不能使用可信界面通道替代任务授权。TCP／Telnet、BLE GATT 和 USB 串口实施中，C05 整体尚未完成。

## C06 日历与待办源码检查点

已接入系统日历的实际查询、事件读写和结果回读，区分无权限、无账户、无可写日历及系统服务缺失。待办独立于聊天保存，支持版本校验、完成／重开、重复规则和提醒；提醒通过系统闹钟与通知执行，重启、时区变化和权限变化后重新核对安排，不调用模型。

日历／待办界面、通知返回及模型工具的十四处主接线已合入。待办表的声明式 SQL 留给本轮统一迁移收口，与现有 v1–v51、R2 修复分别保留；在最终迁移登记前，待办存储如实报告未就绪。没有把缺表标为设备不支持，也没有在旧数据库上临时建表绕过迁移。该检查点尚未执行编译、迁移测试、真实日历、闹钟或通知验收。

## C05 设备通信源码检查点

已接入 TCP／Telnet 持久连接、BLE GATT 和 USB 串口，包含设备界面、独立会话、真实权限申请、断开清理及模型工具。终端复用现有渲染器，Telnet 协商按分片连续处理；BLE 读写和通知串行化，USB 使用系统的逐设备授权，存储设备继续走 SAF。

USB 依赖固定为 usb-serial-for-android 3.11.0，记录实际 AAR、POM、源码提交和许可摘要；不开放其他 JitPack 分组。待办模型列表也修正为在摘要长度内返回完整记录，并携带实际下一页位置，避免跳过未显示的记录。

本检查点未执行整 App／原生构建或真实连接验收。实施包的独立 Kotlin 接口编译使用了部分主接线替身，只能作为局部签名证据；已编写测试未执行，BLE 外设、USB 适配器和真实 TCP／Telnet 行为留待统一验收或用户反馈。C02 的模型 SSH 执行目标仍待完成，不能把 C05 整体标为已验收。

## C07 界面材质与数据交换基础检查点

共享设计系统已接入固定 Haze 1.7.3，包含实际背景采样、弹窗与浮层效果、独立的应用弹窗场景和低版本回退。Main 补齐 Home／设置／功能弹窗的场景接线，窗口内控件与弹窗使用不同的采样所有者，保留原有分栏和导航。六动作媒体工具栏、文档头部、设置和对话顶部改用紧凑图标控件，补齐许可图标角色及应用内来源记录。Activity 显式固定到 Haze 所需的 1.12.2，工具链不变；依赖锁与校验元数据留到收齐新依赖后统一解析。

数据交换基础包已接通设置入口、异步作业、SAF 校验回执、分阶段导入和恢复日志。目前代码覆盖管理项目、保留的项目目录、活动手记及安全偏好，使用真实 `.floenote` 交换格式。任务与私有工作区、媒体／Canvas、持久回执及停用的计划任务恢复、协调数据库快照与其余文档包仍需补齐；这些属于本轮缺口，不把当前基础包称为全应用备份完成。

同时补上待办界面列表的实际序列化字节预算，保留完整记录和实际下一页位置。以上只有源码集成与静态来源核对；未执行 App／原生构建、已编写测试、数据库与 SAF 实测或截图验收，透明效果和手机／平板精修仍须在同一候选上检查。

## C06 系统服务与抓包收尾源码检查点

已接通一次性定位、只读联系人、前台 NDEF 读取和只读 Health Connect，包含真实系统能力判断、用户授权入口、生命周期及模型工具。Health Connect 固定稳定版 1.1.0，来源及许可收入仓库与应用。无设备能力、无授权及服务缺失分别报告，不以未做实测关闭用户入口。

VPN/Root 抓包服务销毁后，把同一套资源交给应用级收尾所有者，线程及转发器没有真实结束时保留账本。Root 助手优先从安装包原生库目录执行，备用路径验证受保护目录和文件摘要。PCAP 导出经 SAF 回读校验。助手提供固定来源构建与 Full 打包校验，Play 不包含助手。

Main 已合入 IPv4 校验函数重名及超时分支再次等待写入锁两处修复。实施包独立 Kotlin 环境的 37 项测试通过，并用接口替身检查服务签名；这些不是整 App、JNI、助手原生构建、VPN 转发或 Root 设备验收。后续统一验证联网、停止恢复、PCAP、权限撤回及双渠道产物。

## C02 执行目标源码接线检查点

目标域、SSH 模型适配、显式迁移及设置入口已交接，目标、运行绑定和派发回执使用原数据库，声明式字段等待统一迁移 52。Main 合入八处主接线和独立路由文件，修正 Swift 6 异步锁使用及旧运行代次清除新路由的风险。

三个终端相关接线补丁交由现有 Linux 实施包统一集成，尚未启用。审查发现原补丁会强迫每次聊天先手动选择目标，需要改为从可信的实际环境固定首次执行目标，并保留不使用终端的聊天体验；不能选择第一项环境或临时路径冒充所有权。该检查点不表示模型终端已修复或迁移已实测。

本轮另建立保留全部 183 个原操作编号的收口索引，区分历史状态与当前证据，记录只读 CAD 和不做实时同步的已确认范围，逐项核对入口、服务、运行时／存储与失败恢复后再冻结。

## C05 RDP 与 C07 数据图源码检查点

RDP 已合入原生桥、固定 FreeRDP/WinPR 与 OpenSSL 来源构建配方、证书指纹确认、画面分页、键鼠输入及应用入口。Main 核对固定 iOS Git 对象，确认桥头文件逐字一致、C 桥完整保留在 Android 编译包装内；补上现有成果读取体系的 RDP 命名空间和应用内许可。尚未构建 Android 原生前缀或整 App，也未连接真实桌面。文字锚点点击和安全凭据卡输入的识别器／解析器仍待接通，不能作为平台不支持销账。

数据交换扩展到单次 GRDB 读事务内生成的任务、对话、消息、运行记录、工具回执、目标及计划任务逻辑数据图，并加入 Canvas／媒体资源和文档包处理。恢复使用新身份和日志，计划任务保持停用，旧执行目标及远程派发记录只作历史证据，不恢复执行授权或重放命令。现有手记交换保留，新增 Canvas 包与 DOCX／PDF 导入校验。

这仍不是全应用数据收口结论：抓包文件、草稿与部分配置／成果覆盖，文件收集失败的显式处理，及新 RDP 数据的往返仍须核对补齐；Linux 环境快照调用端已接好，真实后端待 C01 提供。实施包只证明数据交换独立 Swift 模块构建和资源静态检查，Core 类型检查因其他模块错误未完成，数据库／SAF／设备行为与测试未通过统一验收。RDP 附带的其他模块锁文件副本已移出源码，等待一次真实的依赖解析生成，不能把模板当作依赖证据。

## C05 SFTP 与 C06 独立守卫源码检查点

SFTP 已接入真实 SSH `sftp` 子系统，使用同一已认证连接上的独立通道，取消远端程序路径和 shell 辅助依赖；目录读取按条目、数据包、累计字节及等待时间设限。Main 另补上解码器之前的入口队列限额，溢出关闭通道，避免慢消费者积压。上传覆盖保留修订核对、恢复副本及不确定结果处理，不把 SFTP v3 重命名宣称为原子内容比较更新。主机／网络挂载入口、工作区成果接线已合入；环境专属文件通路仍待 C01。

Citadel 从固定提交生成本地源码补丁层：45 份原文件逐字核对 Git 对象，保留许可，新增真实子系统接口和明确修改记录。其余依赖 pin 保持，过期远端 Citadel 条目移除；依赖来源哈希和新模块锁等待源码冻结后真实解析，不手写成已验证状态。

Root 抓包的独立原生守卫、单调截止时间、大小限制和守护进程崩溃恢复已接线；实际任务／运行／代次从授权声明传入日志，进程身份不确定时不宣布结束，失败成果明确为残缺。便携 C 守卫契约、18 项策略测试和 ARM64 守卫对象编译已有证据；真实 tcpdump 助手、App、抓包联网及受控 Root 模拟器验收未执行。Main 直接修正已报告的邮件、VNC、SSH 锁与协议见证编译问题，未重复整 Core 验证，全部仍需统一对象编译。

## C02 结果保留、任务连续性与 C05 桌面辅助源码检查点

工具结果在实际结算时脱敏并有界保留，模型通过 `tools.readResult` 按真实字节游标读取；现有工具卡接入分页详情，临时会话不落盘、不开放持久读取。运行检查点保留小型引用，不重复执行原工具。任务删除和清空历史的独立删除路径均接入同一任务清理与失败重试。Main 修正旧代次卸载清除新读取器的竞争，并将执行目标桥接到已安装的真实实例。

任务连续性复用现有问题、审批与运行恢复状态，补充存储暂停、恢复探测、显式一次恢复及界面。数据库不可达时使用有界非敏感恢复标记；待处理问题冷读取不再因无活动等待者而取消。新持久字段等待统一迁移 52，不提前登记。

VNC／RDP 的文字锚点使用任务 Linux 环境内的 Tesseract，凭据卡使用原凭据库和 AndroidKeystore；补上设置入口、作用域、撤销及迟到回调检查。识别引擎和任务文件互通仍须随 C01 实际执行链验收，不能把代码接线当作识别成功。

本次 77 份代码与配置文件已整合，33 份 Swift 文件仅通过语法解析，涉及 XML 可解析；未进行类型／对象编译、数据库与 UI 测试、原生构建、设备或云端实测。源码阶段不发布 APK 或 Release。

后续 Main 小修复将任务删除／清空历史绑定到捕获的根代次，旧回调不能清除新根的结果；精确放行已通过真实注册表可用性过滤的四个 SFTP 工具，其余未接通远程能力继续返回未实现。任务暂停字段已汇入声明式迁移清单，当前登记版本仍为 51，等待其他包字段收齐后统一注册 52。

普通任务删除的真实工具结果清理回执已接入既有返回值和历史提示条，区分已清理、等待重试和未能移除；任务行已删除的事实保持成功，不误报整体删除失败。中英文提示对齐，只做受影响 Swift 语法与资源 XML 检查；类型／对象编译、Kotlin 和界面行为等待统一验收。

## C07 数据完整性与恢复源码检查点

备份收集改为校验并暂存实际字节，拒绝变化、不可读、超限和内容冲突；只有原本缺失的引用可生成明确的部分备份回执。清单在读写两端验证引用闭合。覆盖待办、既有成果命名空间、抓包文件、安全远程／邮件／语音配置和只读 CAD 部分；凭据与信任不恢复，任务暂停标记及检查点不作为执行授权恢复。

工具结果经真实存储接口导出，并以新任务／运行／调用身份重新收纳，回读校验新引用和字节，不重放命令。全局缓存增加跨任务上限，持久副本从磁盘重载，未写成功的内存副本被逐出时如实报告。恢复的待办保留内容、时间、完成与提醒偏好，但提醒先暂停，需用户明确保存后重新启用。

Main 同时修复工具白名单被结果读取器扩大：显式白名单和空白名单保持原样，默认注册表仍包含读取器；相关回归断言已更新为保持权限边界，尚未执行。实施包有独立模块构建和小型数据／缓存行为验证，Core 的局部类型检查不完整，不能视作整 Core 或 App 编译通过。尚未进行数据库、SAF、设备或公开安装验收。

本包解决上述具体缺口，不是全应用数据收口结论。原策略仍排除独立记忆、部分草稿和用户偏好等持久内容，后续须按真实存储区分用户数据与运行授权；文件复制的描述符和目录边界也需继续收口。统一迁移 52 尚未登记，Linux 快照后端仍由 C01 提供。

## C07 应用入口源码检查点

分享／打开接入原 URI 授权、附件暂存和手记导入服务；到达时只显示选择器，选择任务后仍需用户主动发送。链接与问题／计划通知按实际标识重新读取原记录，失效目标不创建空会话，不回答或批准任何请求。初始设置可跳过和重开，不覆盖既有模型、供应商或语音选择；反馈仅经用户操作导出有界脱敏报告，提供实际字节和摘要回执。

Main 修正分享文件移交的授权生命周期：附件消费者在确认接收前同步持有原授权代理的引用，接收方可立即释放自身引用；复制早期取消也清理未使用引用，不以延迟 30 秒代替交接完成。新增宿主纯解析通道 24，但 Android 实际入口仍使用平台策略，未宣称 Kotlin 已调用该通道。

实施包的新 Kotlin 源码在包含接口替身的局部环境中编译，21 项纯 JVM 回归通过；这不是整 App／真实资源图／SAF／通知的运行证据。Main 尚未重复构建。入口格式策略与 App 已有媒体、CAD、源码及文档包入口的覆盖仍需收口，不能将未接通的格式直接视作平台不支持。

## C02 MCP 原客户端接线源码检查点

新增 stdio 适配进入原 MCP 配置、客户端工厂、发现、工具注册／调用和取消链，旧 HTTP 配置默认值保持兼容；独立 stdin/stdout/stderr 管道与 HTTP 的可用性分开判断，不把 PTY 回显当作协议响应。向导使用固定校验的项目模板与原作业／配置服务，移除尚无生成后端的输入项。Main 合并配置桥接与安装／退役接线，并修正旧代次退役清除新 MCP 向导运行时的竞争。

这仍不是本地 MCP 已可运行的结论：真实环境注册表、归属项目且不依赖模型账户的运行上下文、长服务和独立管道尚须由原服务接入；stdio 的用户配置入口与调用归属也需在绑定真实后端前核对。不能只填可用标记或虚构运行标识关闭这些缺口。模板资产等待实际 APK 打包校验，完整类型／对象编译和客户端行为尚未验收；本批只做源码语法与资源检查。

## C08 编辑域静态源码对账（33 项）

以不可变 Android 源码 `4437d379` 和固定 iOS 基线完成 Office 11、手记 9、PDF 5、IDE 8 的逐项源码链路核对：23 项已有连通源码，8 项部分缺失，2 项依赖待完成的 C01。原 183 项编号、历史状态与既定范围保持不变；这些计数不表示编译、运行或设备验收通过。原台账已附每项入口、服务、存储、结果与失败路径证据，其余条目继续据实际批次收口。

已确认的独立缺口包括保存后公式计算结果校验、Office 中断保存恢复和修订／冲突审阅。前两项已按互不重叠的写入范围进入实施。PDF／OCR 和新建 Office 的模型处理继续采用任务 Linux 通用工具与成果交付，尚需真实文件交换、手记资源暂存及既有工作区文件工具接口；不增加原生 PDF 别名。复用包中的旧技能说明和作业默认配置经实际 Android 接线核对并非活动广告，不据此修改无消费者的捐赠源码。

## C07 接收格式源码检查点

分享接收改为对照既有消费者处理格式：图片（含 HEIC／AVIF）、音视频、CAD、源文件及常用数据可交给原任务附件或手记资源导入；保留实际字节探测、大小限制、MIME 不匹配错误和 URI 引用交接，不在到达时执行、上传或安装文件。已有13份实现／回归源码及 MainActivity 类型声明完成集成，源文件和交接补丁22项摘要一致，资源 XML 可解析；尚未编译、运行测试或进行设备验收。

文档包检查／恢复入口已有源代码，但接入原数据交换所有者的最后两处主接线仍待该所有者交付；URI 读取完成回调须覆盖协程尚未启动即取消的情况并且只释放一次。此检查点仅交付普通 Task／Notes 格式覆盖和真实的缺失接线状态，不宣称文档包分享闭合；不把 `.floecad` 目录包伪装成 ZIP。

## C08 工作簿公式结果源码检查点

现有 Office AI 保存验证新增第二份独立证据：在同一个已保存 XLSX 中读取公式及依赖值，按有界规则重新计算并对照真实缓存结果。保留原有公式文本校验；缺失、陈旧或类型矛盾的结果走原失败路径，不能凭保存了公式文本就宣称计算结果正确。支持 SUM／MIN／MAX／COUNT／AVERAGE／IF／ROUND 及既定算术、范围和跨表引用；其他公式保留可用并明确结果未验证，不宣称完整 Excel 兼容。

11份 Kotlin 实现／测试源码和5份共享桥接／工具合同／测试补丁已按精确摘要集成，附25项 Kotlin 回归源码及共享工具判断用例，尚未运行。没有编译、构建、调用真实服务或验收设备；待统一检查。Office 中断保存恢复和手记按页／Markdown 导出继续独立实施，修订审阅及其他已确认缺口保留在原计划。

## C08 手记按页与 Markdown 导出源码检查点

手记导出可选择有序页面，默认全篇；以实际保存后的文档、版本和页面身份重新解析，重复、空、删除或过期选择明确失败。PDF／页面图像仍使用原有受保护渲染与手记合成规则。笔记新增真实 Markdown 文档，保留已有文字结构与已存文字／OCR；图像、墨迹等内容明确提示可保留它们的其他格式，不伪造文字或私有路径。原有思维导图大纲、纯文本、归档和打印保留。

11份实现／回归源码已按摘要核对；Main 另修正 Markdown 调用未解包文档返回值的一行类型错误。两份资源 XML 可解析，没有编译或运行测试。分享回执仅证明系统选择器成功启动，不代表接收 App 已读取或保存，设备导出重开和失败／取消仍待统一验证。

## C08 Office 保存恢复源码检查点

Office 编辑副本与引擎已验证输出进入有界恢复记录；在选择目标和实际写入之前持久化阶段，只有目标字节和摘要读回一致才记为已保存。重启后不确定的写入不会自动重试，用户可查看保留副本、重新授权检查原目标、另存或明确清理。恢复不会从旧记录取得任务、工作区或写入权限；缺失、变化和损坏内容分别处理。

集成审查后补上保存点后实际工作副本变化的核对、已完成记录的安全容量回收，以及关闭恢复窗口后的重新进入入口。保留原保存事务，不让旧保存证明覆盖后续未保存字节；仅保证已持久化工作／输出副本的恢复，不宣称能恢复未落盘的引擎内存。13份源文件与回归代码以及 Shell 主接线已按摘要集成，测试尚未运行，尚无 App 构建或设备验收。验证由 Main 统一负责，OpenCode 继续代码实施。

## C08 手记 DOCX 与跨格式页选择源码检查点

原 NOT-EXPORT 继续补齐 DOCX 和 Markdown 的页面选择。手记可生成真正的有界 OOXML：文字、标题、列表、表格和链接保持 Word 结构，图像按页面几何嵌入，墨迹／PDF 底图等视觉层沿用受保护渲染后合成，并说明版式转换边界。PDF、DOCX 与 Markdown 共用有序页面身份与版本检查，不能把所选页面悄悄扩大为全文。DOCX 通过原分享回执返回 App 自有不透明句柄，可在原只读 Office 查看器重开；回执只证明启动交接，不证明外部接收方已保存。

13份源文件／回归代码按摘要核对；Main 另在逐幅保留图片时提前执行原64MiB累计预算，避免整篇图片先入内存才检查总量。没有编译、运行测试或设备验收，后续由 Main 统一执行。

## C02／C07 配置、用户数据与文件流源码检查点

备份新增真实持久化记忆、候选与个性化文档、任务清单、模型偏好、停用的技能定义与来源引用；依赖历史只作为只读恢复证据，临时 RAM 草稿不伪造持久记录。恢复沿用原事务、计划、身份映射和精确回滚，不复制活动数据库、凭据、旧权限或运行控制。新增字段仍待统一迁移52后集中验证，未宣称全应用数据范围已销账。

MCP 原编辑器与配置服务已能保存 HTTP 和无运行绑定的 stdio 定义；独立的命令定义不携带旧任务／根／环境身份。备份使用明确的安全字段投影，恢复为新身份、停用、待重新配置的条目，可在原编辑器看到并填写；不能从恢复文件自动启动进程或取得信任。实际 stdio 使用仍依赖 C01 的可信项目／环境上下文、持久服务和独立管道，新运行绑定入口也须随该真实接口闭合。

文件流根与组件改为持有目录描述符逐级不跟随符号链接访问，仅规范化明确的受保护系统前缀；中间目录使用 mkdirat，不采用先解析整段根路径或绝对路径创建的回退。分享文档包已接回原数据交换检查／审阅服务；源 URI 引用通过幂等的真实 Job 完成回调释放，覆盖协程未启动即取消及清理抛错，不自动恢复文件包。

41份实现／桥接／回归与主接线文件经摘要和合并核对；资源 XML 可解析，旧源码与失败证据保留。新增回归尚未运行，尚未编译、构建 APK、验收设备或调用真实服务。Main 独立负责这些验证，旧组件证据不作为本批 App 通过证明。


### PDF text selection source checkpoint

The existing isolated PDF renderer now supplies source-bound page text to Notes. Region selection and a native character-selection sheet support explicit copy, with document/root/page/source/revision fences. The native context menu also revalidates at the action boundary. Unsupported or scanned pages preserve preview and use the existing honest limitation/OCR entry. This checkpoint contains 19 implementation and regression-source files; Main has not compiled, run tests or accepted device behaviour. All C01-C08 closure and unified qualification remain required before the next Android prerelease.


### C01 terminal and managed-service source checkpoint

Model interactive sessions now share the existing two interactive slots with explicit ownership and actual-release accounting. Long-running HTTP services use separate bounded service leases, the existing job lifecycle and owned-listener readiness before publishing a preview origin. Linux lifecycle tools use the real Android host. Main integrated eight central patches and corrected Android guidance to keep PDF transformations/OCR on the approved generic Linux route. This 33-file snapshot is source-only: no compilation, executed tests or device acceptance. MCP separated stdio, trusted environment/context wiring and guest workspace exchange remain explicit required code, not unsupported-platform exemptions.


### Model workspace-file source checkpoint

The original 13 workspace file tools now have real registry handlers over the existing task-root path guard and file service. The source preserves task path ceilings, temporary-chat refusal, binary-text refusal, bounded reads/search and revision-based atomic mutations. Nine feature/test-source files are selected here. Notes-resource launch/staging ownership and actual guest exchange remain distinct implementation work; neither API presence nor this source publication establishes a working PDF/OCR task pipeline. No compile, executed tests or device acceptance is claimed.


### Office review and retained-document backup source checkpoint

Writer revision actions now use observed engine state. Version review shows text read from each retained snapshot, explicitly limited to text and bounded content; it preserves the active editor. Persistent Office working/export copies participate in typed backup, with fresh restored documents reachable through the existing read-only viewer. Missing or changed sources produce counted omissions. Main replaced the restore directory creation/rollback path with held-directory-descriptor writes and exact-inode cleanup, and authored focused race/collision regressions. Source only: no compilation, executed tests, archive round-trip or device acceptance is claimed. PDF export preserves the original revision-bearing source; PDF visual markup remains to be checked.


### Notes selected-resource task input

An explicit Notes action now creates an ordinary task through the existing conversation creator, prepares a bounded selection receipt and seeds its composer. Creating this task needs no configured model. On first send, the original committed run owner stages the selected resource bytes before model execution; Notes originals and assistant state stay separate. Main completed the UI/host/Core connection after taking over implementation, required live owner admission and shared receipt synchronization, and authored bounded-receipt and ownership regressions. The 474 English/Chinese resource keys match and XML parses; Kotlin/Swift compilation, regression execution and device use remain unverified. Existing live project workspaces still need their separate safe new-input handoff; a fresh task uses the original initial import.


## 2026-11-02：执行目标、真实目录与统一迁移增量

- `34a44d2`：真实 stdin/stdout/stderr 三管道、MCP生命周期和按项目查询的运行时环境目录已源码集成。主协调者修复缺失头文件及 Swift 范围表达式；NDK ARM64 共享库在严格警告配置下编译链接通过，JNI导出和16 KiB段对齐已检查。该证据不等同于Swift/Kotlin整包构建或设备行为。
- `692cc094`：普通运行可接纳当前任务已经拥有、唯一可确定的Linux环境，并持久固定目标；显式SSH选择保留。缺少可用目标时保留普通聊天，执行入口被收窄，不猜第一项环境。模型命令经现有shell服务进入相同目标校验和操作日志，环境ID继续传给真实后端。
- MCP向导新增按实际项目复查运行时目录的适配，验证命令时不再使用定时任务留下的缓存或跨进程的Core路径散列替代运行时所有者。无上下文查询不会返回猜测的记录；旧组件缺少真实层格式信息时不虚构版本。
- 第52次迁移从三份既定且摘要匹配的声明生成并一次登记，加入执行目标／迁移／运行固定／远程派发回执、存储暂停恢复及独立待办表。历史1–51及原媒体选择修复不改写。当前定向SQLite验证覆盖创建、重复、旧值／二进制内容保留、外键拒绝和失败事务回滚；Swift/GRDB实际迁移与设备升级仍待验收。
- 前序手记任务输入与Office恢复副本代码保留：手记资源按真实任务／版本暂存，Office副本沿描述符目录事务恢复。阅读模式／封面、MCP专用运行上下文、HTTP服务适配和新stdio绑定入口仍是真实代码缺口；它们没有被记作平台限制或已完成。

下一实施顺序：补齐不依赖模型账户的MCP原作业上下文与服务适配；完成新绑定入口和活动Linux会话的新输入传递；补手记阅读／封面与183项剩余对账；冻结源码后统一编译、设备与发行验收。未完成代码收口前不发布新Release。


## 2026-11-02：MCP 原作业归属与 stdio 用户入口增量

`155deb38` 接入不调用模型的原生 MCP 安装任务：复用原会话、项目分配、运行及作业存储，不选择供应商或模型。独立管道与 Node 长服务仍在真实 Linux 运行时中执行；用户的运行停止、项目／任务删除和根退役进入原取消与释放机制，取消不等于进程已退出。新增任务分配只接纳自身 CAS 返回的新项目修订，其他项目变化仍拒绝。

后续增量在原 MCP 编辑窗口加入项目、真实环境与任务选择。选项通过原生项目目录读取，晚到回复按编辑窗口、请求代次和根代次隔离；保存新绑定时复查实际任务／项目／环境归属，未绑定的命令定义仍可单独保存。模型调用既核对任务和工作区，也核对真实管道所属运行；其他任务及不可用本地服务的命名空间从本次运行发现中移除。同一任务下一次运行按现有 MCP 客户端生命周期重新连接，不复用上一运行的进程。stdio 进程纳入原会话操作租约，开始、停止和实际释放都可被删除／退役排空路径观察。

同时修复基础地址与 `/mcp` 验证路径混用、将服务启动中误判为失败，以及浏览器预览不可用阻断真实 MCP 服务的问题。模板自身启动器仅绑定回环地址，保留原模板档案、版本和摘要，不重写第三方输入来通过校验。

当前验证事实：新增 Swift 源码语法检查通过，中英文资源281项名称一致，新增任务／运行隔离回归源码尚未运行。主协调者尝试一次集成模块定向编译，先修复原构建脚本的 MessageDigest 名称遮蔽；后续同项检查停在真实依赖解析，Haze 1.7.3 尚未缓存、Activity 与旧锁文件约束冲突，集成模块 Kotlin 尚未编译通过。保留两次原日志，锁文件未手改、组件未降级；待全代码收口时由真实解析器统一生成和核对依赖。

尚未完成：MCP 新环境的 Node/npm 自动依赖准备核对、活动 Linux 会话中新文件传递、手记封面／阅读模式、183项剩余对账、最终 Swift/Kotlin/原生生产与同源 APK／设备验收。不能从上述源码增量推断这些项目已通过，也没有发布新 Release。


## 2026-11-02: updater fallback and integrated compilation

Removed duplicate default-delta dispatch from the foreground download service. The controller owns the exact user choice (delta, explicit full fallback or resume); the service only hosts its lifecycle. Preparation publishes progress before checksum/base/network work. The selected release survives later feed refresh/failure. Installer commit uses compare-and-set so an early system callback is not overwritten; confirmation-launch failure is tied to its original session, retaining durable ownership until explicit recovery.

Actual production download-source host tests passed 69 cases, including corrupt-delta reconstruction followed by verified full bytes and no duplicate writer during preparation. This does not prove real APK signature/installation/UI/device behavior. Integrated App compilation reached application sources and exposed cross-batch integration errors now under repair. No qualified new APK or Release exists. Resolver-generated dependency candidates still need review; no new dependency metadata is selected in this source checkpoint.


### Integrated Kotlin checkpoint

Full production Kotlin and all Full test sources now compile; the targeted Full updater suite passed 89 tests with zero failures/skips. Play production Kotlin also compiled. Batch corrections align remote/desktop/SFTP DTOs, Notes resource identities, media state/actions, calendar/NFC types, Office recovery/result types and localized resource references with their real services. No assertions were removed to make tests compile.

The resolver regenerated 22 changed lockfiles and additive verification metadata. All 140 newly recorded artifacts were independently read back from their official Google Maven, Maven Central or explicitly allowlisted JitPack origin and matched the candidate hashes; all 873 previously trusted entries were preserved. This is dependency/source evidence, not binary/channel/device acceptance. OpenSSL ARM64 static production has completed; FreeRDP/core native production and the remaining code gaps still block qualified APK delivery.

## 2026-11-02：ARM64 原生集成检查点

主 Core 和 Linux 权限组件现已通过 Swift 6.4.1、Android API 28 的 release 对象编译与链接，保存了实际产物、摘要、精确输入清单和原始编译故障。主 Core 的 LOAD 段对齐为 16 KiB；此结论不代替整个 APK 的所有原生库与安装验收。

修正了共享接口、执行目标的真实组合接线、迁移回执类型、任务取消、平台文件系统接口、日历锁范围及邮件／待办／备份的跨任务值传递。Hub 投影通过序列化字节生成独立返回值，保留原有分页及字节限制。导入文档的复制结果重新核对源摘要，不接受验证后被替换的同尺寸内容。没有通过取消 Swift 并发检查、放宽授权或数据库事务来消除错误。

固定版 OpenSSL／FreeRDP 已生产为实际 ARM64 静态库，检查了全部归档成员架构及真实定义符号。修正构建脚本的编译器路径、版本标记、版本化头文件目录、PIC 和嵌入库符号可见性，保留原始来源与摘要。

当前仍不是全代码收口：新环境的 MCP 依赖自动准备、活动 Linux 环境的新输入传递、手记封面／阅读模式与剩余操作台账尚待完成。实际 APK、三星／平板及公开更新链路尚未验收；没有发布新 Release。


## 2026-11-03: stored task exports and internal Notes CAD preview

Task export now reads original persisted messages, parts, runs, usage/errors and per-run events through recorded watermarks into a bounded JSONL job. It retains stored tool summaries and artifact references, cannot reconstruct missing raw output, and does not embed artifact files. Original C07 ownership, cancellation and chunk reads remain authoritative; verified length/hash precede read-only FileProvider sharing.

Fixed Kotlin/Swift UUID case differences that created a note but falsely reported failure. Notes engineering attachments now reuse the internal C04 offline renderer with verified staged resources, rather than ACTION_VIEW importing the attachment back into Floe.

Actual checks: Swift 6.4.1 ARM64 release object compilation/linking passed; Full/Play Kotlin compilation and targeted C07/task-export regressions passed. Six host behavioral checks exercised the production redaction function. New APK export/render/install acceptance remains pending.

Prior device evidence: two independent Samsung terminals retained their output. One Ark Agent Plan / ark-code-latest activation returned stdout and exit status through interactive shell, but the original exec.shell was hidden by the environment-catalog receipt defect and is NOT accepted by that result. The repaired real catalog and cross-day chronology were observed on the following candidate without another paid call.

Still open: shared PDF/images currently use generic attachments and must reconnect to existing native Notes import; the original 183-operation ledger needs reconciliation; positive full-download, delta-fallback and installer acceptance remain required. The tablet App has no Root grant; emulator su presence is not Root acceptance. No new public Release has been published.


### Shared visual imports and honest viewport readiness

Shared PDF/images now use the original Notes resource store and the same visual-page importer as the Notes library. The original PDF renderer/image probe prepares page backgrounds; one atomic edit batch replaces the initial placeholder. Stable intake/request identities support retry, preserve later user edits and refuse modified/foreign destinations. Password/unsupported/oversized/atomic-write failures remain real failures. Existing PDF text-test helper argument order was corrected to compile its original assertions; the original compile and proxy-fixture failures were retained. Full/Play Kotlin and all 25 selected Notes tests passed.

On candidate e9755f2, Samsung exported a real JSONL through system sharing and X-plore: 10 messages, 5 runs, 12 usage records and 91 events reached every recorded run watermark. This export made zero cloud calls. The tablet first-save of a new OBJ succeeded and original OBJ/DXF hashes were unchanged. However its internal CAD ready callback preceded a visibly blank viewport; rendering was NOT accepted. The follow-up source explicitly fills the Android WebView surface, waits for nonzero layout and rejects zero-size canvas readiness. New-APK rendering and PDF/image intake acceptance remain pending. Package signature, ELF 16 KiB and actual strip-to-packaged-byte checks passed for e9755f2. This is still a private candidate, not a public Release.


### Actual CAD/PDF acceptance and entry refresh correction

Private candidate 23192a6 passed signature/native-byte/ELF-16-KiB package checks. The existing API37 16-KiB tablet displayed the real OBJ geometry, with orbit/zoom/reset controls and an internal read-only full-window viewer. Shared PDF first-save succeeded as a native two-page Notes notebook; cold reopen showed the original first-page text and switching to page two worked. The original fixture bytes remained unchanged. These samples do not establish every CAD format, Root, Office, image or upgrade acceptance.

The same device exposed two further UI defects: new-document events did not refresh the library without an existing editor session; background Activity instances could consume external navigation before the resumed instance. The library now refreshes for original document events. The shell gates external-entry/notification navigation to the resumed lifecycle, rechecks before a route commit, and leaves a paused entry request pending. A regression exercises a new document with no open session. Full/Play Kotlin and nine selected Notes tests passed; this new navigation behavior still needs APK acceptance.

The original nine CAD editing/modeling ledger IDs now explicitly retain the approved read-only scope replacement instead of pretending to implement modeling. Original identities/statuses are preserved. 138 other source-ledger entries still require reconciliation; this documentation count is not a measured missing-feature count. No new public Release exists.


## 2026-11-03: sidebar and Settings hierarchy aligned to iOS

Compared the immutable iOS App sidebar, SettingsRootView and RemoteSettingsView at a59b4d4; the public main iOS source still matches that donor. The Android sidebar had six additional feature rows plus duplicate More entries. It now keeps the original five primary destinations, project/conversation content and Settings footer. Remote hosts/VNC, RDP and desktop-assist configuration belong to Remote settings. Mail, calendar/reminders, BLE/USB devices, system services and network diagnostics are grouped under System capabilities. Linux configuration belongs to Execution environment. Voice remains in General; image/video model-role configuration belongs to Auxiliary capabilities.

Operational entries open the existing real feature in a secondary page sheet, with an explicit header dismissal slot, its own bounded scrolling and original App-owned service/permission lifecycle. They preserve the task/Notes route behind Settings. Internal notification destinations remain compatible; no feature is removed or replaced by a placeholder. The old desktop-assist section name remains a supported deep link while its ordinary entry is consolidated. Full/Play Kotlin compilation passed. New APK visual and interaction acceptance is pending.

The previous candidate ec39e26 actually accepted a fresh shared image as a one-page native notebook, displayed its gradient pixels and navigated Open Notes in the resumed Activity with two MainActivity instances present. The live library updated from 10 to 11 notes without restart. A separate PDF page-two render refusal appeared during the later reopen; page-one text, persisted two-page structure and image rendering are proven, but page-two rendering is NOT accepted and remains a repair item. No extra cloud calls were made and no new public Release has been published.


### Navigation inspection correction and profile-load repair

The first tablet inspection of f49fc89 showed the five primary sidebar entries, Settings master/detail categories, a real secondary Remote-host window and dismissal back to the same Remote category. System-service entries also opened in their own secondary window. This establishes navigation/presentation, not remote connectivity or permission/data acceptance.

A finer iOS comparison corrected the initial voice grouping: GeneralSettingsView keeps voice in General, while AuxiliarySettingsView delegates to image-generation/editing model configuration. Android now follows that placement: General retains system/cloud voice; Auxiliary shows the existing original image/video role preferences and shared/separate routing controls. A scalar-only autonomous-routing change now exposes Save through the original preferences CAS instead of being omitted from dirty state. No provider invocation or credential was needed.

The Remote host-list spinner was a real load-token defect: the independent list-load token was checked against SSH/VNC operation counters and returned without clearing loading. The load lane now uses its already-revalidated epoch for the existing profile owner; SSH/VNC operation fencing is unchanged. All 25 focused Remote/client/preferences regressions passed, and Full/Play Kotlin compilation passed. An initial test fixture accidentally initialized the native video transport on the host JVM; its original failure was retained, and the fixture now refuses unexpected video calls through the existing injectable interface.

Concise remote/OCR copy replaces implementation details in normal settings. Bounded diagnostics contain only refusal codes/page indices for the still-open PDF page-two refusal and system-service refresh refusal; they add no retry, privilege bypass or fallback. Those two actual failures remain open. The final grouping/dismissal correction still needs its same-source APK confirmation; no new public Release exists.

### Final navigation confirmation

Candidate09 from c3a61b0 passed package, existing signing identity and 16 KiB checks. Installed on the existing API37 tablet emulator and old Samsung, the actual sidebar now shows only the five primary destinations plus projects, conversations and Settings. The tablet opens Settings with category/detail columns. The Samsung opens the compact category list, then Remote detail, then the secondary host-manager sheet; dismissing that sheet returns to the original Remote detail. The real host list reaches its empty state instead of spinning. General voice and Auxiliary image/video controls were also observed on the tablet. These checks establish entry placement and navigation, not remote connectivity or blanket feature acceptance.

The original PDF page-two refusal is retained as a reproducibility issue. Candidate09 reopened the same two-page note and visibly rendered the actual second-page text; no new PDF repair is claimed from that observation alone. The System-services banner was traced further: after dismissing it, an explicit refresh succeeded and native capability diagnostics were returned. The controller swallowed refresh cancellation as failure and preserved an old refresh-failure notice even after success. Source now rethrows cancellation and clears only that obsolete notice after a successful native availability push; permission-denial and other actionable notices remain. This small correction awaits the next coherent APK batch; current device evidence belongs to c3a61b0.

Superseded candidate06/07/08 installation files and completed publication indexes were removed while retaining their build/package/failure evidence. Candidate09, one rollback package, current native products, required baseline recovery, and caches with an identified next use remain. No public Release or additional paid cloud call was made.

The follow-up controller source passed Full/Play release Kotlin compilation and 4 existing system-lane regressions (zero failures/errors). This is focused source verification, not device acceptance of the new cancellation/notice correction.

## 2026-11-03: full UI and end-to-end task closure

The user approved checking all existing operations and UI families, followed by coherent code batches and unified acceptance. Android continues from 907cb7c. The fixed active-development iOS reference is now 36f63bf400dfaa3a127259eac006b38d72516390; compared with a59b4d4 it changes 219 App/Sources files. These are changed files, not 219 missing Android features. Public-main equality with the old donor is insufficient to establish current parity. The new planning/IOS_PARITY_BASELINE.json preserves both references and the changed-file inventory; original183 operation identities and approved scope replacements remain.

One actual layout cause was corrected: Notes previously always split its library and editor on wide windows, yielding three visible columns with the App sidebar. It now retains the existing library behind a full-window document presentation, following iOS NotesRootView. The same App-owned workspace/controller/editor session remains responsible for documents, undo, assistant state and pending saves. Back uses the original assistant/linked-document/library navigation; closing presentation does not discard the tab or editor state. The document window owns safe drawing/keyboard insets. Default Notes toolbar controls use the existing compact shared glyph button with the Android touch-target floor; explicitly sized controls retain their original treatment.

Full/Play release Kotlin compilation and three Notes cold-open/library/presentation regressions passed, including returning to the same library mode/filter and reopening the same editor instance. APK visual/interaction acceptance is still pending. The other UI families and remaining operation reconciliation are not declared complete from these checks. User-authorized real Volcengine calls may use the existing Ark Plan configuration and ark-code-latest for minimal end-to-end verification; no automatic paid retry or provider switch. All required code closure still precedes a new public Android prerelease, and iOS Latest remains unchanged.

### Actual task failure and PDF ownership repair

One real Ark activation on the Samsung discovered exec.shell and the real workspace tool catalog. After explicit approval, exec.shell returned exit125/runtime_unavailable. The runtime's closed lifecycle trace independently shows that this command was actually admitted, spawned and exited; the first-use environment materialization took about27.4seconds and process execution about180milliseconds. This is a result-delivery failure, not proof that no command ran. The run was paused after the failure, with no paid retry or provider switch; any existing output must be inspected before replaying side effects.

The host had a concrete poll/settlement race: a poll could retain a live owner while the watcher closed its connection. Poll now shares the original settlement mutex and, when already settled, uses the existing retained-session read path to fetch real output at the requested cursor. A terminal ownership proof is never converted into invented command output. Three concurrency/error regressions and four original fast-exit contracts passed, as did Full/Play Kotlin compilation. Device acceptance of this repair remains pending.

Candidate10 passed package/signature/16KiB/native-byte checks. The actual tablet editor covered the whole App window, displayed PDF page two, returned to the original library and reopened the same note. The first pass exposed low-contrast system-bar icons in the separate dialog window; that window now follows the editor theme. Reopening also reproduced the original PDF failure: PdfDocumentSession inserted a bitmap into its cache but returned caller-owned metadata, so the first caller recycled the cached bitmap after encoding it. A successful cache insertion now returns cache-owned metadata; a budget-refused bitmap remains caller-owned. Nineteen existing cache/session/password/text tests and Full/Play Kotlin compilation passed; actual repeated-page and reopen acceptance of the new ownership fix is still required.

Reachability review also corrected an earlier suspicion: RETRY_ORIGINAL_CAS is a refusing reserved action, not a current viewer button. The actual Office conflict screen offers Keep Current and Save Copy. Manual original-write parity still needs its own ownership/path review; it is not counted complete, nor does removing an unreachable enum implement it. Remaining operation and UI families stay open. No new public Release exists.

### Runtime export gap reproduced without another cloud call

Candidate11 from514a73a passed package/signature/16KiB checks and was installed on the existing tablet and Samsung. The tablet displayed both PDF pages, reused page two after a page switch, returned to the library and reopened that page without the earlier cache refusal. Light system-bar icons now follow the editor window theme correctly. The Samsung displayed an existing note full-window with compact header controls and returned to its unchanged library.

The Samsung's local terminal then read the exact file created by the original Ark command, including FLOE_ANDROID_CLOSURE_OK, and printed a separate completion marker. The file therefore existed and had survived the earlier model-visible failure. However the terminal still displayed runtime_unavailable on exit; it is not accepted as repaired. Closed diagnostics identified shell.poll/AdmissionRefused while the runtime exported the workspace. The runtime deliberately removes the last process from its running census BEFORE whole-UID quiescence/export and publishes the completed receipt only afterward. The old running-or-completed read lookup therefore had a real empty interval.

RuntimeSessionReadIndex now retains the same session for read-only output lookup before that removal and drops the retention only after actual completion publication. This does not add an executing process, change admission/quiescence, release a lease early, invent output, or remove retained failed-release ownership. Three export-gap/foreign-owner/stale-release regressions and Full/Play Kotlin compilation passed. Existing shell output remains available; no paid command was replayed. Normal terminal failure copy is concise in both languages instead of exposing raw internal exception identifiers.

The next private candidate increments the shared App/runtime build code to26, retaining the unused Alpha23 release version. The separate runtime component must actually update; an installed code25 component cannot establish the new code26 readiness. No Linux root filesystem or user data is reinstalled, and no public Release is published before the remaining required closure.

### First batch device result and next source work

Candidate12 is the actual signed Full APK built from66d3b8b2f9e1c89a790ca7a37d3fb216f06a871a, build26, SHA256679a2eb5af9099121be78c1c0e923a5308a8646eb2fdfe00664b7f3ce478e89f. Package/signature/16KiB/native-byte checks passed. Its exact embedded runtime component and App both report code26 after installation on the existing Samsung and tablet. A private export helper initially retained an obsolete code25 assertion after Gradle had already succeeded; the exact successful APK was saved after correcting that assertion, without rebuilding or replaying signing.

On Samsung, the same original task's terminal read FLOE_ANDROID_CLOSURE_OK from the original Ark-created file, printed a separate local marker, and now reported process exit0 instead of runtime_unavailable. The original file also opened through the task file workbench in the full-screen text editor. This proves local execution/result settlement and file persistence/readback. It does not claim that a post-repair cloud model completed publishOutput or delivered an attachment; that separate boundary remains unverified, with no paid task replay.

The five original LNX operations now have current per-operation source chains in the original ledger, preserving original statuses and previous reviews. The actual device coverage and untested cancellation/service/recovery cases are stated individually.133 original operations still require source reconciliation; this is not133 measured missing implementations. The earlier editor33 audit is being reused by comparing its exact evidence files against current source, rather than rerunning the old audit or tests indiscriminately. Manual original Office save-back, remaining UI families, and the real online delta/full-download/install path stay open.

The closing incremental iOS check observed5af731b2 against the fixed36f63bf4 reference: only one localization file changed, adding CAD modeling/editor labels. Android's approved CAD read-only scope is unaffected; the fixed reference and original delta identities remain. Superseded candidate05/09/10 APKs, extracted runtime-install staging and finished checkpoint indexes were removed, reclaiming899985408 allocated bytes; current candidate12, immediate rollback11, producer proofs, necessary recovery and useful next-batch caches remain. The task-owned tablet emulator was shut down without deleting data, and Samsung's display timeout was restored and the device locked. No new public Release exists.

## 2026-11-03 文件、设置和浏览器增量对账

保留全部183项原编号和原状态，补记 IDE8、文件／凭据7、设置10与浏览器5的固定源码链路；已审查不等于设备通过，剩余108项仍待源码逐项核对。文件授权保留真实 SAF 持久／会话权限和撤销区别，导出只有经过目标文件实际回读才返回成功。隐私清理未为对账而执行，云端个性化生成也未调用。

新确认的实现缺口包括：压缩包 App 浏览／解压入口，设置内缓存与环境占用计量、安全清理，以及可用字体管理；已有 Linux 安装清理和诊断导出不能替代这些入口。压缩包模型工具已按原名称补回现有任务工具注册，沿用原安全引擎；新回归源码验证真实解压字节及拒绝覆盖，尚未执行。App 压缩包、Office 原件保存、Git 服务器拒绝回执按独立写域实施，后续统一集成验证。

固定 iOS 浏览器使用共享网站数据存储，Android 共享登录状态符合该基线；任务、操作、下载及成果归属继续严格隔离。不把可选多账号配置扩展为本轮新增收口条件。当前仅推送源码检查点，未发布新的公开安装包。
