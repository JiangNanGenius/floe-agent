# Floe Android GitHub 专属"ADB 增强模式"（非 Root）调研与实施契约

> 调研日期：2026-10-18。任务编号 job-47610231353843d8。
> 本文只调研、只提案：未安装、未构建、未在任何真机/模拟器上验证，未修改设备、权限、密钥或计划/工作包文件。
> 本文与现有长计划（`docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md`）互补：正式计划、工作包、feature-baseline 与台账由计划负责人（Main）统一整合，本文不改任何既有 ID、状态或数量。
> 一手来源抓取快照与 SHA-256 清单存放于 `Local/Private/android-g02-20261018/adb-privilege-research/`（私有；仅为维护者留存证据，不含任何凭据、配对码、序列号）；公开可点验来源一律以 §14 的固定修订链接为准。
> 标注约定：**[已证实]**＝有直接一手来源；**[提案]**＝本文设计建议；**[待实测]**＝需 G12/G13/OEM 设备验证；不存在"全部已验证"的默认。
> 修订：2026-10-18 按 Main 评审补充——ADB Wi-Fi 2.0（Android 17/adb 37.0.0）事实与待核查项、targetSdk 37 更正、普通 Intent 拉起与特权进程控制分行、三类死亡/重启的生命周期分列、卸载≠Forget 语义更正、环回选择降格为"最小暴露面"而非免权限承诺、AVF/adb 模块来源补核。
> 修订二（同日，deep 复核）：AVF 三项 VM 权限的 `<permission>` 定义点已定位并跨版本对账（android13→17/main，定义随 Virtualization 模块资源 APK——部署于 AVF APEX——而非 frameworks core/res，protectionLevel 漂移已钉源）；补齐"development 旗标→adb pm grant"的框架级授予门源码链（PermissionManagerServiceImpl/Permission.java）与服务端强制点（virtualizationservice aidl.rs check_permission）；新增 full 变体 uses-permission 白名单的渠道隔离含义（§3.2/§9）。

## 1 需求与结论摘要

用户 2026-10-18 明确要求："非root设备也可以通过adb获得更大权限，此功能仅github版本提供。" 该要求取代此前由文档推导的"不得发行任何可选 ADB 能力"的强约束，但保留三条既有边界：

1. ADB 增强是**可选、默认关闭**的 GitHub `full` 专属模式；不是聊天、IDE、Office、Linux、文件、网络等基本功能的前提（计划第 3 章"不把 root、解锁 bootloader、Shizuku 或系统虚拟机权限作为普通用户基本使用前提"一节继续成立——本模式只增强，不成为前提）。
2. 它与普通运行时权限和 Root 是**三种不同授权面**，互不冒充：普通权限走系统授权流程；ADB 模式给 shell（UID 2000）身份；Root（UID 0）继续走既有默认关闭的 Root 开关（计划"GitHub Root 增强"一节）。
3. Play 构建**物理排除**全部 ADB/Shizuku 客户端、daemon、依赖、Manifest 组件、原生库、入口与工具注册（见第 8 节），不依赖布尔开关或字符串 grep。

结论建议（第 5、6 节展开）：

- **首选：复用 Shizuku 外部管理器**（客户端只依赖 MIT 许可的官方 `dev.rikka.shizuku:api/provider`，不打包 Shizuku 本体）。零协议实现成本、授权与生命周期由成熟管理器承担；代价是用户需自行安装 Shizuku、非 Root 设备每次重启需再次启动。
- **备选/后续子项：内嵌无线 ADB 配对客户端 + Floe 自有 shell 助手**（候选 `libadb-android` 3.1.1，GPL-3.0+ **或** Apache-2.0 双许可，可走 Apache 路径；须独立安全评审）。单 App 体验、不依赖第三方，但需自担 TLS 配对协议维护、密钥存储、Conscrypt 体积/ABI 与 OS 演进成本。
- **不推荐作默认**：Bundling 整个 Shizuku App；Dadb（仅明文 TCP 5555，需 `adb tcpip` 引导、有 LAN 暴露面）；LADB（许可附加"禁止非原作者上传 Google Play"条款，且为整机 App 集成）；要求 Termux 或其他第三方终端。
- 能力必须分层表述：**一次性 ADB 持久授权（关掉服务后仍生效、部分跨重启）** 与 **活体 shell 能力（服务断开即失效）** 不同，二者的持久性逐项待实测，不得宣称"ADB 授权全部跨重启保留"或"重启即全部消失"。

## 2 边界与既有事实核对

- 当前唯一活动目标仍是 G02；本模式实现归 **G08**，行为验收归 **G12**（三星真机）与 **G13**（最新平板/新系统/OEM），打包渠道验收归 **G15**。本轮不开始 G08 编码。
- 现有测试事实：Samsung SM-G9810（Android 13 / API 33，非 Root）此前仅做过有界合件测试；产品内未安装/配置任何真实 ADB 模块。Mac 开发主机已授权的 USB 调试是 QA 通道，**不是**发行 App 具备特权 UID 或能自主配对的证明；验收必须走 App 内自足路径（无 PC）。
- 既有 P1.11"手机操作不靠开发主机 ADB"、第 17 章"不利用 ADB 设置替代正常用户授权路径"仍然有效：普通 SAF/权限/辅助功能验收继续按普通用户流程；本文新增的是**用户显式选择**的可选 ADB 模式，二者并存不混淆。
- 本文档不含任何设备授权、密钥生成、重启、设置项修改；上述均在后续按各自授权执行。

## 3 机制事实（全部一手来源，检索日 2026-10-18）

### 3.1 ADB/adbd 的身份与边界

- 生产（user）构建上 `adb shell` 以 **shell 用户（UID 2000）**、SELinux `shell` 域运行。AOSP `system/sepolicy` main 分支：`public/shell.te` 定义 shell 域；`private/shell.te` 101 条 allow 规则仅覆盖 shell 自有数据与受限系统面；`private/adbd.te` 明确 "we never want to see a transition from adbd to su (aka 'adb root')"，`adbd→su` 转换由 `userdebug_or_eng` 门控——**零售设备不可用 `adb root` 提权为 UID 0**。[已证实]（android.googlesource.com platform/system/sepolicy refs/heads/main，快照含哈希）
- Shizuku 项目文档同样直述："ADB 能做的与 ROOT 显著不同……Shell（ADB）无法访问其他应用的数据文件 `/data/user/0/<package>`。"[已证实]（Shizuku-API README，master@a27f6e4151ba）
- 用户同意不改变内核边界：UID 2000 仍受 SELinux、scoped storage、加密状态与只读分区限制；不得以"ADB 模式"宣称全文件系统/所有应用私有数据可达。

### 3.2 shell UID 的权限集（AOSP main 实况）与可授予性

`com.android.shell`（sharedUserId `android.uid.shell`）的 AOSP main 清单（[packages/Shell/AndroidManifest.xml 固定版链接见 §14]）声明 **536 项权限**（计数与全表见本目录私有快照，公开核对以 §14 permalink 为准），节选与本模式相关的代表：

| 权限 | AOSP `core/res/AndroidManifest.xml` protectionLevel | 对普通 App 的可授予性 |
| --- | --- | --- |
| READ_LOGS | signature\|privileged\|development | 含 development 旗标 → 存在 `adb shell pm grant` 通道 [待实测逐OS确认] |
| DUMP | signature\|privileged\|development | 同上 |
| WRITE_SECURE_SETTINGS | signature\|privileged\|development\|role\|installer | 同上；官方 AVF 文档即示范 `adb shell pm grant <测试应用> android.permission.MANAGE_VIRTUAL_MACHINE`，证明 adb 可为测试包授予非 runtime 类权限 [已证实文档，本机行为待实测] |
| PACKAGE_USAGE_STATS | signature\|privileged\|development\|appop\|retailDemo | appop/development 双通道 |
| SYSTEM_ALERT_WINDOW | signature\|setup\|appop\|installer\|pre23\|development | 普通设置页本就可达；ADB 只是另一条路 |
| INJECT_EVENTS | signature | **不可授予普通 UID**：仅活体 shell 能力 |
| READ_FRAME_BUFFER | signature\|recents | 同上 |
| ACCESS_SURFACE_FLINGER | signature | 同上 |
| INSTALL_PACKAGES | signature\|privileged | 同上（普通路径仍是系统安装器） |
| FORCE_STOP_PACKAGES / CLEAR_APP_USER_DATA | signature\|privileged / signature\|installer | 同上 |
| GRANT_RUNTIME_PERMISSIONS | signature | shell 持有它，才能在设备上执行"一次性授权批" |
| REBOOT / DEVICE_POWER | signature\|privileged | 活体 shell；每次显式确认 |
| QUERY_ALL_PACKAGES | normal | App 自行声明即可，与 ADB 无关（渠道政策另计） |
| MANAGE/USE_CUSTOM/DEBUG_VIRTUAL_MACHINE | **定义已定位**：Virtualization 模块 `android/android.system.virtualmachine.res/AndroidManifest.xml`@main（模块内资源 APK 携带 `<permission>` 定义）：MANAGE=signature\|preinstalled\|development、USE_CUSTOM=signature\|development、DEBUG=signature；跨版本漂移：13-release=javalib 清单 MANAGE=signature\|development（无 USE_CUSTOM），14/15-release=MANAGE=signature\|privileged\|development [已证实，见 §11/§14] | shell 清单亦声明三者。可授予/可用的**五项设备条件相互独立**：①清单定义随 Virtualization 模块资源 APK 安装（其宿主通常是 AVF APEX）；②设备声明 AVF 系统特性（PackageManager 特性/`uses-feature`）；③pKVM/hypervisor 硬件支持；④非 SDK 客户端调用路径可行；⑤实际 VM 创建成功。任一条件不能由其余推断 [待实测] |

**"development 旗标→adb 可授予"的框架级证明**（本轮补齐，非猜测）：frameworks/base@main `PermissionManagerServiceImpl.java`——授予前置检查 `if (isRuntimePermission || bp.isDevelopment()) { // Good. }`（L1405/L1592），调用方需持有 `GRANT_RUNTIME_PERMISSIONS`（L1358/L4241，shell 清单持有该权限），且目标包必须已在自身 manifest `uses-permission` 声明该权限（"isn't requested by package"即拒绝）；`Permission.isDevelopment() = isSignature() && PROTECTION_FLAG_DEVELOPMENT`（`Permission.java`）。另有注释直述 development 授权"不是普通 runtime 权限……对所有用户生效"。[已证实] 对本模式的含义：**一次性授权批只能作用于 Floe full 变体已声明的 uses-permission 白名单**；该白名单声明本身必须 full-only（见 §8/§9），play 合并清单不得出现这些特权声明。

**注意版本与 OEM 漂移**：Shizuku README 与 AOSP 文档均提示不同 Android 版本下 Shell 权限集会变；上述为 AOSP main 快照，三星 One UI 与其他厂商需按 G12/G13 实测修正。[待实测]

### 3.3 无线调试配对与连接（Android 11+ 官方路径）

来自 developer.android.com/tools/adb（当日抓取）：[已证实]

- Android 11+ 的"无线调试"要求先**配对**（QR 或 6 位配对码 + 显示的一次性端口），再经 **mDNS**（`_adb-tls-connect._tcp`）自动发现/连接；网络不支持 mDNS 时需手动 `adb connect ip:port`。
- 配对持久性："一次配对即可。设备将保持已配对状态，直到你显式 Forget 或在系统里 Revoke adb debugging authorizations"；解除＝Paired devices→Forget，或全局撤销所有授权。**配对≠服务在跑**：重启后无线调试开关/守护连接需再次操作（Shizuku 手册直述"由于系统限制，每次重启后需重新执行启动步骤"；配对关系本身按官方文档保留到被 Forget/Revoke）。
- 旧式 `adb tcpip 5555` 走**明文 TCP**且监听面是全网络，本模式不将其设为默认路径（见第 9 节）。
- 会话与保活：无线调试会话可被省电策略/OEM 管理杀掉；Android 11+ 开发者选项存在 "Disable adb authorization timeout" 一类项——本文只**提示**用户相关选项存在，产品不自动改厂商安全设置、不自动关闭 adb 超时。
- **ADB Wi-Fi 2.0（当日官方页面已更新，非旧文假设）**：developer.android.com/tools/adb（2026-10-18 快照）明载 "Android 17, alongside adb 37.0.0 introduces adb Wi-Fi 2.0"——勾选 "always allow on this network" 使网络成为**受信无线调试网络**，设备接入该网络后自动连回工作站；支持性判定为 `adb mdns track-services --proto-text` 输出 `mdns_service_version: "2.0"`；工作站 `adb server-status` 核验 version 37.0.0+、`mdns_enabled: true`、`mdns_backend: LIBADBMDNS`；手机前提为 Android 11（API 30）及以上（TV/WearOS 为 13+）。
  对本模式的窄含义[提案]：Wi-Fi 2.0 描述的是**工作站↔设备**模型（含 QR 码）；Floe 的同机自配对不因此获得"免重启/免启动"保证——配对关系、无线调试开关/守护服务、Floe 助手进程仍是三条独立生命周期；**不得假设**三星 API33 或既有 Shizuku 管理器版本自动支持全部新客户端特性；嵌入候选客户端对 A_STLS 与新 mDNS 元数据的兼容性列为 G08 核查项，不预设结论。官方"一次配对直到 Forget/Revoke"表述当日仍在，继续按原文引用。

### 3.4 Shizuku 复用机制

来源：Shizuku 仓库（Apache-2.0，v13.6.0 2025-05-25 发布，master 最后提交 2025-06-18=b844bc49）、Shizuku-API（MIT，master 最后提交 2025-05-29=a27f6e41，客户端 13.1.5）、官方手册（shizuku.rikka.app，页面标注 2023-06-21 更新）。[已证实]

- 原理：Shizuku 引导用户以 **ADB 或 Root** 启动一个常驻进程，App 经 Binder 获得以该身份执行 Java/JNI 代码与转发系统服务调用的能力（"normal apps use system APIs directly with adb/root privileges with a Java process started with app_process"）。
- 客户端面：`dev.rikka.shizuku:api` + `:provider`（ContentProvider authority 方式拿 binder，provider 以 `INTERACT_ACROSS_USERS_FULL` 权限自我保护）；`Shizuku.requestPermission/checkSelfPermission` 是**管理器自有同意**（类似 runtime 权限弹窗，独立于 Android 权限）；`getUid()` 0=Root、2000=ADB；`isPreV11` 不再支持；binderReceived/binderDead 监听；min API 23 需 desugaring。
- `UserService`：在**独立进程以 shell 或 root UID** 跑自有代码，非 SDK 接口在该进程不受限；但非合法应用进程，`Context` 多数 API 不可用；`Shizuku#unbindUserService` **不会**自动杀死服务进程——须自己实现 destroy（固定事务码 16777115/16777114）并 `System.exit()`；`peekUserService` 可查存活；`UserServiceArgs#daemon` 有常驻语义（本模式**不得**将其用作保活手段）。
- 启动方式：Android 11+ 可**纯手机端**经无线调试启动（配对一次即可，Shizuku 通知里输入系统显示的配对码；每次重启需重新启动服务）；Android 10 及以下需电脑执行手册给出的 `adb shell sh /sdcard/Android/data/moe.shizuku.privileged.api/start.sh` 类命令；Root 设备直接启动（该路径属 UID 0，见下）。
- OEM 已知限制（官方 FAQ 直述）：MIUI 需 "USB debugging (Security settings)" 独立开关、通知样式改 Android 制式；ColorOS 需关 "权限监控"；Flyme 支付保护、EMUI 仅限充电模式 ADB、GrapheneOS 安全应用生成；配对服务搜索要求 Shizuku 有**后台网络**（省电杀后台会失败）。这些是"管理器级"限制，Floe 只能检测+引导，不能代改。
- **共享管理器规则**[提案，按 Main 2026-10-18 架构补充]：Shizuku 服务可能被其他 App 共用。Floe 停用/取消只允许 `unbind`/destroy **自己 tag 的 UserService 与自有任务**，绝不全局 kill/重配置管理器；若 `getUid()==0` 而用户只开了 ADB 增强（未开独立 Root 开关），必须**拒绝使用并要求按 Root 模式重新显式授权**，绝不静默按 Root 特权运行；优先按 shell 后端运行可运行部分。

### 3.5 Android 16 / Android 17（target 36/37）本地网络权限

来源：developer.android.com/about/versions/16/behavior-changes-16 与 /17/behavior-changes-17（当日抓取）。[已证实]

- Android 17（API 37）引入 **ACCESS_LOCAL_NETWORK** runtime 权限（归入 NEARBY_DEVICES 组），对 **targetSdk 37** 应用**强制**；Android 16（API 36）阶段为 opt-in；限制实施于网络栈深处，覆盖托管与原生 socket：对本地网段（RFC1918、IPv6 link-local、直连路由）的 TCP 出站/入站、UDP 单播/组播/广播都需要该权限；mDNS/SSDP/NsdManager 均在影响面内。
- 对本模式的设计含义[提案]：嵌入客户端与配对/连接**仅对 127.0.0.1 本机环回**发起（同机自我配对，LADB 实测文档路径），不自动发现或连接局域网其他设备。选环回是把作用域限定为"本机自我增强"并将 LAN 暴露面压到最小，**不构成免除权限同意的承诺**：若实测显示环回亦受管控，按真实需要请求 ACCESS_LOCAL_NETWORK，并正确处理拒绝与被撤销后的重检。
- **环回是否豁免于本地网络管控，官方两页均未直述 → [待实测]**（G13 在 API 36 opt-in 与 targetSdk 37 强制两种姿态下验证 loopback pair/connect 与 mDNS 关闭网络的回退）。若环回受限，回退顺序：请求 ACCESS_LOCAL_NETWORK（含被拒处理与撤销重检）→ PC/USB bootstrap（Android ≤10 设计路径，11+ 作为显式高级选项）。

## 4 能力矩阵（普通App / 普通已授权 / 一次性ADB持久授权 / 活体shell UID2000 / UID0参考）

列义：**A** 无任何特殊授权；**B** 普通用户流程授予的声明权限；**C** 经一次 ADB 会话写入、断开服务后仍生效的持久授权/配置（持久性逐项 [待实测]，不承诺跨重启一致，也不承诺重启即消失）；**D** 需服务活体（Shizuku 运行且已授权，或嵌入客户端已连接）的 shell UID 能力；**E** UID 0（归 Root 模式，本模式不提供）。

| 能力 | A | B | C（一次性持久） | D（活体 shell） | E 证据/待实测 |
| --- | --- | --- | --- | --- | --- |
| 全包清单与深信息 | ✗ | QUERY_ALL_PACKAGES 可达基本清单 | 亦可（若以 pm grant 方式给自身授予含 development 旗标权限，[待实测]） | ✓ pm/dumpsys package | 来源：两份 AOSP 清单 [已证实] |
| 静默安装/卸载/清数据 | ✗ | ✗（普通路径=系统安装器） | ✗（INSTALL_PACKAGES 为 signature\|privileged，不可 pm grant）[已证实] | ✓ adb install 语义、pm clear | D 每次显式意图+读回 |
| 普通前台拉起（公开 Intent/深链/可见可启动包） | ✓（公开 API 语义；受系统后台启动限制） | ✓ | ——不需要也不应经 ADB—— | ✓（am 亦可） | 普通用户基线按平台允许做全；与特权面分开呈现，不与 force-stop 混列 [提案] |
| 特权进程控制（force-stop/清数据/跨应用管理） | ✗ | ✗ | ✗（FORCE_STOP_PACKAGES=signature\|privileged；CLEAR_APP_USER_DATA=signature\|installer，均不可 pm grant）[已证实] | ✓ am force-stop / pm clear | 归 D 面 |
| 向 Floe/白名单应用批量授予 runtime 权限 | 普通弹窗 | 普通弹窗 | ✓ 由 shell 的一次性 pm grant 写入后持久生效 | ✓ 执行通道本身 | GRANT_RUNTIME_PERMISSIONS 在 shell 清单 [已证实]；逐项确认、非静默 |
| 特殊 appop 授予（如后台运行、悬浮窗） | ✗ | 部分走设置页 | ✓ appops set 写入后持久 | ✓ 执行通道 | 持久性（重启/更新/重装）逐项 [待实测] |
| 安全设置写入（settings put secure/global） | ✗ | ✗ | ✓（WRITE_SECURE_SETTINGS 含 development，可试 pm grant）[待实测] | ✓ 直接 | **禁止**用于静默开启无障碍服务/改厂商安全项；仅任务白名单键值、可读回 [提案] |
| 系统日志（logcat/READ_LOGS） | ✗ | ✗ | ✓（development 旗标）[待实测] | ✓ | READ_LOGS level [已证实] |
| dumpsys 诊断 | ✗ | ✗ | ✓（development 旗标）[待实测] | ✓ | DUMP level [已证实] |
| 截屏 | ✗ | MediaProjection 用户同意路径 | ✗（READ_FRAME_BUFFER=signature\|recents 不可 grant）[已证实] | ✓ screencap（安全窗/锁屏仍受限）| 与 Accessibility 截图路径并行不互斥 |
| 输入注入/跨应用操控 | ✗ | ✓ Accessibility（既有 P1.11） | ✗（INJECT_EVENTS=signature）[已证实] | ✓ input events | 不把 ADB 设为手机操作前提；两者独立授权 |
| 其他 App 私有 CE 数据 | ✗ | ✗ | ✗ | ✗ SELinux 仍拦截 [已证实：API README+shell.te] | △ 条件性：仍受 su 后端实现、SELinux 上下文/enforcing、解锁与 FBE 状态、版本差异约束——不承诺全量私有数据/锁屏绕过；UID0 永远属于独立 Root 显式授权，ADB-only 模式检测到 UID0 也只提示不静默用 [提案，延续 §20 Root 纪律] |
| 原始抓包/接口层网络 | ✗ | VPN 捕获（§19 既有） | ✗ | user 构建 tcpdump 多数不可 [待实测] | ✓ |
| 电池优化白名单/待机批 | ✗ | REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 引导页 | ✓（appops/cmd 写入，持久性 [待实测]） | ✓ 执行通道 | 供调度模块"待重新配置"状态用 |
| AVF/受保护 VM | 公开 SDK 无该包（客户端为 @hide @SystemApi） | ✗ | ✓* 条件成立：MANAGE 含 development 旗标→adb pm grant 通道存在（官方 TryAVF 演示即此，Cuttlefish 限定），**前提是设备已安装定义该权限的 Virtualization 模块资源 APK**且应用已声明 uses-permission；**特性声明、硬件支持、非 SDK 调用与建 VM 成功另为独立条件**；零售三星可用性 [待实测] | ✓ `vm` 调试命令；服务端 `check_permission`（uid0 直通，否则 IPermissionController 校验，失败抛 SECURITY）[已证实 aidl.rs] | E：仅 Root 面直通 uid0 短路；其余按 su 后端条件性，见矩阵纪律 |
| 重启/电源动作 | ✗ | ✗ | ✗ | ✓ 经用户逐次确认 [提案] | REBOOT=signature\|privileged [已证实]；重启后本模式进入 requiresRestart |

矩阵纪律：任何 ✗ 不得宣传为可用；任何 [待实测] 在文档/工具描述中显示为"需设备确认"；不以 userdebug AVD 或开发 Mac 的 adb 结果冒充零售设备 SDK 行为；`adb root`、Magisk 授权路径不混入本矩阵。

## 5 候选对比（许可证/维护/成本；只读元数据，未构建）

| 候选 | 许可（当日核验） | 维护信号 | 能力面 | 体积/ABI | 结论 [提案] |
| --- | --- | --- | --- | --- | --- |
| RikkaApps/Shizuku（App 本体） | Apache-2.0 | v13.6.0（2025-05-25）；最后提交 2025-06-18；未归档 | 管理器/daemon，全启动方式 | 不由 Floe 分发 | **不打包**；作为外部依赖由用户自装（下载入口按官方渠道说明，不引导第三方盗版源） |
| RikkaApps/Shizuku-API | MIT | 最后提交 2025-05-29；changelog 至 13.1.5 | binder 获取、UserService、getUid/checkPermission/binder death | 纯 JVM（AAR 小），无原生 | **首选客户端**；provider 需声明（full-only） |
| MuntashirAkon/libadb-android | 双许可 GPL-3.0+ 或 Apache-2.0（取 Apache 路径） | tag 3.1.1=c849886ebc6d（2025-12-08）；2026-06 仍有推送；自述"从未通过安全审计" | App 内 TLS **pairing**+connect（SDK16+）、自动发现、RSA 密钥对生成，存储留给集成方 | 依赖 org.conscrypt:conscrypt-android 2.5.3（原生多 ABI，尺寸未实测 [待实测]）或平台隐藏 API 绕过 | **备选**：嵌入配对路径的首选库，实施前需安全评审与锁源 |
| mobile-dev-inc/dadb | Apache-2.0 | v2.0.0；2026-06-22 活跃 | 纯 TCP 的 adb 协议客户端（含 RSA auth、sync、forward），**无无线配对/TLS** | Kotlin/Java，无原生 | 仅适用于已有明文 tcpip 的场景 → 不作默认（LAN 暴露面） |
| tytydraco/LADB | BSD-3 式+条款3"非原作者不得上传 Google Play"（GitHub 报 NOASSERTION） | 2026-07-26 活跃 | 整机 App：自我配对+shell（含分屏保配对弹窗教程） | 打包内嵌 adb 组件 | **不集成**；作为"自我配对可行"与"配对弹窗易失效"的实践证据引用 |
| AOSP adb 模块（**现址已核实**：platform/packages/modules/adb @main=1cf2f017d312…，system/core/adb 旧路径已迁出） | MODULE_LICENSE_APACHE2/NOTICE 在场 → Apache-2.0 [已证实] | AOSP main（上游协议权威） | docs/dev/ 提供一手文档：adb_wifi.md（配对写入设备 `/data/misc/adb/adb_keys` 或 `/adb_keys` keystore；配对服务器用 RSA 2048-bit（x509 证书），信任以六位配对码或十位 QR 数的共享秘密做 bootstrap（具体密码套件见模块 pairing_auth/pairing_connection 源码，docs 未展开）；无线调试连接以 A_STLS 全程 TLS、随机端口，与 legacy 明文 tcpip 明确区分）、root.md（adbd 恒以 root 启动、user 构建**必然**降权为 shell，`adb root` 仅 eng/userdebug）、protocol.md/services.md/sync.md 等 | 不适合直接嵌入 | 作**协议与边界事实一手参考**，不作依赖；候选嵌入客户端须逐项对照这些语义核兼容性 |
| topjohnwu/libsu | （§20 已定） | — | Root 专用 | — | 与本模式无关，保持 Root 开关独立 |

## 6 方案与推荐（默认 + 回退）

**分层产品姿态**[提案]：

1. **基础层（永久无 ADB）**：全部**普通基础功能**保持非 Root、非 ADB 可用——这是硬约束（指普通用户基线，不含 Root/ADB 专属能力集）。
2. **持久增强层（一次性 ADB 授权批）**：服务活体时按用户**逐项勾选**执行 pm grant/appops/settings 白名单操作；此后断开服务、重启后系统仍保留者继续可用。调度等模块必须**每次运行重检实际权限**（recheck），用持久授权即可运行的任务不必等待服务；需 shell 活体的操作显示"等待 ADB 激活"，不伪造自动恢复。
3. **活体 shell 层**：输入注入辅助（可选）、截屏辅助、dumpsys/logcat、pm/am/cmd 受控操作、进程/服务等第 4 节 D 列能力——仅在管理器服务连接存活且用户已授权时可用，binder death/撤销即围栏。

**默认路径 = 复用 Shizuku**：Floe 只声明客户端库与 provider（full-only），检测未安装/未启动/未授权状态并给官方手册一致的引导（Android 11+ 纯手机端；≤10 电脑引导；重启需重启服务的提示）。优点：不实现协议、不承担安全审计面、生命周期与共享管理语义有社区实践；代价：外部 App 安装、OEM 兼容清单（3.4）、用户须理解两层授权。

**回退/演进路径 = 内嵌配对客户端**（G08 子项、独立决策）：libadb-android（Apache 路径、锁 3.1.1/c849886ebc6d）+ Conscrypt 锁定版本，自我配对仅打 127.0.0.1，密钥交 Floe 自有凭据存储；先做安全评审与 API37 环回权限实测，再决定是否默认。优点：单 App、免安装第三方；代价：协议/OS 演进自持、审计成本、体积/ABI。

**引导路径（Android ≤10/配对不可用）**：沿用"连接电脑"式 USB bootstrap（官方手册命令），明确告知重启后需重来；不提供也不宣传明文 5555 常开模式。任何路径都不把"电脑已授权 USB"当作 App 能力证明。

## 7 状态机与生命周期 [提案]

```
disabled(默认)
 → enabling/precheck（渠道=full、设备API/OEM能力探测、模块可用性）
 → managerAbsent | managerIdle(未启动) | managerPairingRequired | managerNotAuthorized(用户未同意Shizuku授权)
 → transportPaired(配对关系存在)            ← 与"服务活着"分离显示
 → active(uid=2000) | activeRootBlocked(uid=0且Root模式未开 → 拒绝并引导)
 → grantsApplied(一次性授权批: 逐项成功/失败/跳过)      ← 与 active 分离的持久子状态
 → serviceDied(binder死亡/进程被杀 → 围栏: 取消自有操作, 持久授权继续可用/重检)
 → requiresRestart(重启后: 提示重新启用+启动; 显示哪些持久授权重检后仍有效)
 → revoked(用户撤销管理器授权/Forget配对/关开关) | oemBlocked(命中3.4清单) | disabled
```

不变式：

- **三层分离显示**：传输已配对 ≠ 特权服务可用 ≠ 单个操作成功；UI 分别呈现，操作成功以读回为准。
- 停用/取消只停止 **Floe 自有**任务与 UserService（3.4 规则）；绝不影响管理器其他用户。
- 不自动弹配对、不自动请求提权、不自动关闭 adb 超时/厂商安全选项；重连有界退避+可取消；无保活滥用（daemon 标志不用作常驻借口）。
- 每次运行绑定 taskID/runID/revision/grantID + 类型化目标与执行后端（kind=SHIZUKU|EMBEDDED|PC_BOOTSTRAP、effectiveUID、设备与系统版本证据），输出有界、可停止、可核对；受控宿主系统操作是**显式后端/工具契约**——普通模型代码继续走既定 Linux `exec.shell`，不因 ADB 模式把宿主当解释器回退，也不复活任何已移除的执行别名。
- **三类"死亡/重启"分别处理，不写一条概括规则**：
  ① **Floe 进程死亡**：管理器、其 UserService、配对与持久授权完全可能仍活着。Floe 重启后应**重新发现/重绑**——先复查管理器授权、`getUid()`、逐项 recheck 持久授权，然后才恢复 active 呈现；既**不得盲目恢复 ACTIVE 旗标**，也**不得仅因 Floe 重启过**就要求用户重新配对或重新激活。
  ② **管理器/助手死亡**（binder death、进程被杀/OEM 省电）：serviceDied 围栏只取消 Floe 自有在途操作；依赖持久授权的增强继续可用（重检后）；待管理器恢复后按①流程重绑，绝不自动重启他人拥有的管理器配置。
  ③ **设备重启**：requiresRestart——配对关系按官方文档可保留，但无线调试/服务须用户重新启用与启动；持久授权逐项重检、不预设保留与否。
  即：**用户 opt-in 配置、配对/传输状态、活体服务、逐操作授权**四类生命周期各自独立建模（进 G08 测试，§12）。
- 失败路径保留普通功能与用户数据；进程死亡不自动恢复"增强中"的显示。

UI 状态词（中英双语、面向用户简洁文案）：关闭 / 未安装管理器 / 需配对 / 等待管理器授权 / 已激活（ADB 身份） / 需要重启后重新启用 / 服务已断开 / 已撤销 / 受系统限制（OEM） / 仅部分可用。

## 8 渠道隔离与打包验证（G15）[提案]

Play 构建必须物理排除：`:adb-system`（或最终定名）模块源码与资源、Shizuku api/provider AAR 及其传递依赖、libadb-android/conscrypt（若演进启用）、provider 声明（`${applicationId}.shizuku` authority）、任何 ADB 入口页面/设置项/模型工具注册/Skills 过滤项、配对引导文案与 native 库；同名接口在 play 仅提供"不可用"实现。

验证手段（不接受布尔旗标或 grep "adb" 字样充数，也警惕 AndroidX 中泛用词误报）：

1. Gradle `play*` 依赖图解析无上述构件；
2. merged manifest 无 provider/service/receiver/permission 相关项；
3. 最终 DEX 类清单扫描（`rikka.shizuku.*`、`muntashirakon.*`、配对/daemon 类）与资源/asset 比对；
4. APK/AAB 解包核验 native libs 集合；
5. 运行时能力目录发现：play 实例的工具枚举无 ADB 类能力；
6. full 构建的上述入口与能力真实可用（与 Root 模块分别核验，延续 P6.12 双渠道纪律）。

开发者 QA 在 play APK 上使用开发 Mac 的 USB/ADB 安装与调试是允许的 QA 通道，不构成任何发行特权，也不得写进验收证据链的"App 能力"栏。

## 9 安全与密钥边界 [提案，含未决]

- **传输面**：仅支持官方 TLS 无线配对（配对码 6 位、一次性端口、系统 UI 显示），环回连接；无明文 5555 默认路径；不硬编码任何手机序列号/IP；mDNS 不可用走用户手输，失败即报告。
- **配对码/授权瞬态**：配对码仅短暂驻留 RAM，用后即弃，不写日志、不进备份、不进 Git、不显示在诊断导出。
- **客户端密钥**：ADB 协议密钥为 RSA。已核验参考事实：Dadb 读取/生成 PEM 文件密钥（`~/.android/adbkey` 语义）；libadb-android 用 JCA 生成 RSA+自签 X509，README 明示存储留给集成方（源码处 "TODO: Store the key pair"）。**Android Keystore 不可导出私钥与该协议对私钥任意签名需求的兼容性未解**——Conscrypt/BoringSSL 直接消费 Keystore 句柄是否可行是嵌入路径的第一评审项，不预设任何结论。过渡建议：应用私有加密存储（复用 core/credentials 既有加密域与备份排除策略，实施由 G08 按届时契约执行）、文件权限 600、审计日志脱敏。
- **授权面**：一次性授权批逐项列给用户"权限名/含义/是否可撤销/撤销路径"；不批量打包授予；settings 白名单不含无障碍服务开启、不含厂商安全项；READ_LOGS/DUMP 等含 development 旗标权限是否可授予与授予后系统行为按 G12/G13 实测，未实测前 UI 显示"待设备确认"。
- **uses-permission 白名单（新增，由 §3.2 授予门推导）**：pm grant 只作用于应用已声明的权限——Floe `full` 变体须显式声明拟支持的 development 旗标权限白名单（如 READ_LOGS/DUMP/WRITE_SECURE_SETTINGS/PACKAGE_USAGE_STATS，若评估 AVF 再加 MANAGE_VIRTUAL_MACHINE），且这些声明与对应能力实现**只存在于 full 变体**；play 合并清单出现任何一项即渠道核验失败。声明≠授予≠可用：运行时仍需一次 ADB 授权批成功且逐项 recheck。
- **撤销与恢复**：用户 Forget 配对/撤销管理器授权/关闭开关 → 立即围栏并降级；持久授权项提供"查看当前实际状态"的 recheck 入口；重启后不伪造"自动恢复"。
- **数据面**：网页/文件/他 App 屏幕/工具输出仍是不受信内容，不能授予任何权限；日志诊断不含配对码、密钥、设备序列号原文。

## 10 与既有计划/工作包的映射提案（不改 ID/状态/数量）

| 既有行 | 映射建议 |
| --- | --- |
| 第 3 章"不把 root/Shizuku 作前提"（line 173 一带） | 保留原文：它约束**普通功能前提**；本模式是可选增强，不构成前提。建议 Main 加一句交叉引用本文。（该行明载的仍是 root、bootloader 解锁、Shizuku 与系统虚拟机权限四种，不因本文新增 adb。） |
| P1.11 手机操作（"不靠开发主机 ADB"） | 保留：普通 Accessibility 验收不变。ADB 模式的截屏/输入辅助为**独立可选后端**，其验收另立（见 G12 正例）。 |
| 第 17 章"受限设置"与"不用 ADB 替代正常授权路径" | 保留：普通用户路径优先级不变；"用户显式选择 ADB 增强"是该句所区分的例外面，建议按本文措辞显式化。 |
| P0.9 Root服务设计 / P2.12 Root开关 / P3.11 深度系统工作流 / P5.9·P5.10 / P6.12 双渠道 / P6.5 更新与安装 | 各行的 Root 专属语义不动；ADB 模式作为**平行模块**复用其开关/撤销/读回/渠道排除纪律：开关默认关、检测有效 UID、逐项确认、双渠道排除清单（第 8 节）。P6.5 补充（按状态寿命分列，不用"一律保留/一律失效"）：**包升级**保留应用数据，Floe 侧密钥/选择与持久授权原则上延续 [待实测]；**数据重置或 Floe 卸载**只意味着 Floe 侧凭据/私钥丢失＝该客户端此后无法再认证——**不等于**设备端已配对记录或外部管理器配对状态被自动 Forget（陈旧条目须用户显式清理；嵌入客户端卸载残留设备侧 key 的处理是 G08 设计项）；Keystore 丢失仅影响嵌入路径；**卸载 Shizuku**＝管理器侧状态随其消失；**Forget/Revoke** 是设备/管理器端独立动作。 |
| G08 行（现为手机操作+Root） | 建议 Main 将其扩展为"手机操作、Root 增强与可选 GitHub ADB 增强"：实现=第 6/7/9 节；Play 排除并入 G08 既有物理裁剪验收。 |
| G12 行 | 增加"非 Root 三星 ADB 模式正反例（第 12 节）"；SM-G9810 属 Android 13，无线调试自足启动在范围内。 |
| G13 行 | 增加"target36 opt-in 与 target37 ACCESS_LOCAL_NETWORK 强制姿态下的环回配对/连接实测、mDNS 缺失回退、OEM 清单（3.4）、新 Shell 权限集漂移核对"。 |
| G15 行 | 双渠道 ADB 排除核验（第 8 节四项产物级证据）。 |
| 调度（c87368f0d2dc443f 研究线） | 交接口径：重启/撤销后调度可显示"等待 ADB 激活"或凭持久授权重检后继续；无伪自动恢复、无 Root 依赖。该文档由调度线自持，本文不写其文件。 |
| 更新器 | 普通更新走正式 PackageInstaller 路径不变；ADB 模式不作为更新前置；仅当用户显式选择受控高级动作且 OS 合法路径允许时才作为可选执行面。 |
| G03/Linux | 无前提关系（第 11 节）；exec.shell 语义不变。 |
| 新 operation 族（供 Main 定 ID） | 建议 G08 下增设：模式开关与前置检查、管理器检测与引导、配对/连接、管理器授权、有效 UID 判定、能力探测、一次性授权批预览/执行/重检、受控操作执行与读回、服务断开围栏、重启再激活、撤销与恢复。本文不写入 feature-baseline/work-packages。 |

## 11 AVF 与终端/VM 效率简评（Main 指定，不重设计 G03）

一手结论：AVF 的 VirtualizationService 以 AIDL 暴露给"系统服务或应用"；Java API（VirtualMachineManager）**不在公开 SDK 包**（android.system.virtualmachine 引用页 404），文档自述"仅存在于支持 AVF 的设备、非 boot classpath"；官方 Try-AVF 演示用 `adb shell pm grant … MANAGE_VIRTUAL_MACHINE` 把 VM 权限授予测试 App，且注明"只在 Cuttlefish 上工作"；`vm` 调试命令可"从 shell 启动/查看/终止 VM"；生产级"Linux 开发环境"用例自述"仅在部分设备可用"、运行于**非受保护** VM。[已证实（各文档原文）]

推论 [待实测/待查证]：技术上，获授权 shell 通道（本模式 D 列，或文档示意的 C 列一次性授予）在**硬件支持 AVF 的设备**上可能解锁受保护 VM 类 Linux 后端；但 SM-G9810(API33) 与本地平板 AVD 的 AVF 可用性均**不得承诺**（pKVM/crosvm 与厂商 HAL 依赖）。

**权限定义已定位并跨版本对账（本轮完成，替代上一稿的"未定位"）**：

| 分支 | 定义文件 | MANAGE_VIRTUAL_MACHINE | USE_CUSTOM | DEBUG |
| --- | --- | --- | --- | --- |
| android13-release | `javalib/AndroidManifest.xml` | signature\|development | （尚未定义） | signature |
| android14-release | `javalib/AndroidManifest.xml` | signature\|privileged\|development | signature\|development | signature |
| android15-release | `java/AndroidManifest.xml` | signature\|privileged\|development | signature\|development | signature |
| android16-qpr2-release | `android/android.system.virtualmachine.res/AndroidManifest.xml` | signature\|preinstalled\|development | signature\|development | signature |
| android17-release / main@175a51b301… | 同上路径 | signature\|preinstalled\|development | signature\|development | signature |

要点：① 定义一直随 **Virtualization 模块**的资源 APK 走（现有布局为 `android.system.virtualmachine.res`），而非 frameworks/base core/res（13→17 各分支 core/res 均无此三项，已逐一核验）；未安装该资源 APK 的设备上该权限不存在，`pm grant MANAGE_VIRTUAL_MACHINE` 无从谈起（"Unknown permission"）。② protectionLevel 存在真实版本漂移（privileged→preinstalled；USE_CUSTOM 自 14 引入），任何逐权限结论必须钉分支。③ 官方 TryAVF 的 `adb shell pm grant` 示例与 development 旗标 + §3.2 授予门（GRANT_RUNTIME_PERMISSIONS 调用方 + 目标包须声明）完全自洽——该示例是 **Cuttlefish** 上的测试流程，不得读作零售三星可行。④ 服务端强制点：virtualizationservice `aidl.rs` 的 `check_permission`（uid0 直通；否则经 IPermissionController 按调用 pid/uid 校验，失败抛 `ExceptionCode::SECURITY`）。⑤ 客户端 `VirtualMachineManager` 为 `@hide @SystemApi`（不在公开 SDK），普通 App 即便获授权也需非 SDK 接口/平台库路径。
**条件分层纪律（勿合并推断）**：模块/资源 APK 的存在与清单定义＝源码/打包事实；PackageManager 的 AVF 特性声明（`android.software.virtualization_framework`）、pKVM/hypervisor 硬件支持、非 SDK 客户端可调用性、实际 VM 创建成功分别是**独立测量条件**——安装 APEX 不等于声明特性，声明特性不等于硬件可用，硬件可用不等于客户端路径可行，更不等于建 VM 成功。以上本轮均为源码事实核对，不构成任何设备授予或 AVF 可用性证明。

G03 的 PRoot 基线、Linux 环境所有权与"模型代码走 exec.shell"全部不变；AVF 仅作为 G13 设备探测项与自愿用户反馈通道登记。

## 12 验收场景 [提案]

**G08（实现门槛，无设备也须可编译证明）**：模块仅挂 full flavor；play 依赖图/manifest/DEX 四项核验（第 8 节）通过；后端契约接口含 kind/effectiveUID/capability 探测与有界 IO；单测覆盖状态机迁移与 binder-death 围栏（可用假 binder/接口替身，无需真机），并**必须包含 §7 三类死亡的独立用例**：Floe 进程重启后对仍存活管理器的重绑（复查授权/UID/逐项 grant，且不强迫重配对）、管理器死亡围栏与复活重绑、设备重启的 requiresRestart 路径；文案双语且无内部协议术语外露。

**G12（三星 SM-G9810, Android 13, 非 Root）**

- 正例：App 内引导完成无线调试自我配对与管理器启动（无 PC）→ active(2000) → 能力探测矩阵落盘 → 逐项一次性授权批 → 停服务后重检持久项仍在 → 活体项在 serviceDied 围栏后不可用但普通功能全部正常 → 重启 → requiresRestart 引导 → 再激活成功；调度任务显示真实的"等待激活/凭持久授权继续"两种路径；操作停止与人工接管即时生效；Floe 停用只终止自有 UserService（管理器与另一共存测试 App 的服务不受扰）。
- 反例：拒绝管理器授权→全程普通功能无损；getUid()=0 且 Root 模式关闭→拒绝并引导独立开关；Forget 配对/系统撤销→REVOKED 且不自动重弹；省电策略杀后台→降级显示与重试上限；配对弹窗超时→可取消的有界重试；任何场景不自动改厂商安全选项、不自动关超时、不静默开无障碍服务。
- 证据纪律：开发 Mac 的 USB adb 仅记为 QA；AVD/userdebug 结果分列，不混入零售证据。

**G13（最新平板 AVD / API 36、37）**：3.5 的 loopback 与 ACCESS_LOCAL_NETWORK 两姿态实测；mDNS 缺失网络手输回退；OEM 清单外新系统回归；Shell 权限集漂移 diff；16KB 页与（若启用嵌入路径）Conscrypt 原生库核验；AVD 的 AVF 可用性如实标注模拟器/无 GMS 环境差异。

**G15**：双渠道 APK/AAB 产物级排除核验（第 8 节四项），full 安装升级保留配对语义，Play 候选无 ADB 死入口。

**硬件反馈缺口**：真实 Root 管理器与 OEM（HyperOS/ColorOS/EMUI/GrapheneOS）行为不在本轮设备清单——按既有纪律登记自愿用户反馈，不冒充已验证。

## 13 未决清单（诚实登记）

1. ~~MANAGE/USE_CUSTOM/DEBUG_VIRTUAL_MACHINE 定义点~~ **已解决**（§11 跨版本表，定义随 Virtualization 模块资源 APK，13→17 漂移已钉源）。仍待实测的是**互相独立的设备条件项**（不得合并推断）：①目标设备是否安装该资源 APK（权限是否存在）；②是否声明 AVF 系统特性；③pKVM/hypervisor 硬件是否支持；④非 SDK 客户端调用路径的工程可行性；⑤实际 VM 创建是否成功；外加 development 授权在零售机上的重启/更新持久性。
2. development 旗标权限（READ_LOGS/DUMP/WRITE_SECURE_SETTINGS）经 pm grant 授予第三方包在 API33/37/One UI 的真实行为与持久性矩阵（重启/更新/卸载/数据重置）。
3. Android 16→17 各版本"无线调试"配对码/弹窗时效（LADB 文档示"弹窗关闭即作废"、Shizuku FAQ 示通知式输入）——逐版本实测。
4. 环回 socket 是否被 ACCESS_LOCAL_NETWORK 管控（官方两页未直述）；受管控时授权被拒/撤销后的降级路径。
5. 嵌入路径的 Keystore 不可导出私钥与 A_STLS/RSA 认证协议兼容性；Conscrypt 体积/ABI/16KB 页实测。
6. libadb-android/Dadb 与 Shizuku 服务并存冲突根因（LADB README 称与 Shizuku 互斥；疑与 5555 端口/单一连接语义相关 [待查证]）。
7. **ADB Wi-Fi 2.0（Android 17 + adb 37.0.0：受信无线调试网络、自动回连、`mdns_service_version 2.0`、LIBADBMDNS 后端、QR）对候选嵌入客户端与既有 Shizuku 管理器版本的兼容性**；同机自配对场景下这些工作站向特性是否/如何生效——G08 核查 + G13 实测，不预设任何一侧自动支持。
8. 各 OEM 后台网络限制对"配对服务搜索"的影响面（3.4 FAQ 为社区一手，需 G13 复核）。
9. QUERY_ALL_PACKAGES 等两渠道共用普通权限的取舍不得"盲目移除"（保留给 UI/功能需求决策）。
10. AOSP 各发布分支（33/34/35/36/37）间 Shell 权限清单与 protectionLevel 漂移 diff（本轮快照为 main 单分支）。

## 14 关键引用（公开可点验的一手链接；固定修订版）

私有目录内的抓取快照与 SHA-256 仅是维护者留存证据；公开核对一律以下列链接为准。均于 2026-10-18 访问。

**AOSP（googlesource，permalink 到当日 main 分支提交）**

- Shell 权限全集：[frameworks/base@1cdfff555f…/packages/Shell/AndroidManifest.xml](https://android.googlesource.com/platform/frameworks/base/+/1cdfff555f4a21f71ccc978290e2e212e2f8b168/packages/Shell/AndroidManifest.xml)
- protectionLevel 源：[frameworks/base@1cdfff555f…/core/res/AndroidManifest.xml](https://android.googlesource.com/platform/frameworks/base/+/1cdfff555f4a21f71ccc978290e2e212e2f8b168/core/res/AndroidManifest.xml)
- SELinux：[sepolicy@4571ddd944…/private/adbd.te](https://android.googlesource.com/platform/system/sepolicy/+/4571ddd9440721fec583c906a337de949a77749e/private/adbd.te)（L218-232 adbd→su 门控）、[…/public/shell.te](https://android.googlesource.com/platform/system/sepolicy/+/4571ddd9440721fec583c906a337de949a77749e/public/shell.te)、[…/private/shell.te](https://android.googlesource.com/platform/system/sepolicy/+/4571ddd9440721fec583c906a337de949a77749e/private/shell.te)
- adb 模块（现址）：[packages/modules/adb@1cf2f017d3…/README.md](https://android.googlesource.com/platform/packages/modules/adb/+/1cf2f017d312f73b3dc53bda85ef2610e35a80e9/README.md)、[docs/dev/adb_wifi.md](https://android.googlesource.com/platform/packages/modules/adb/+/1cf2f017d312f73b3dc53bda85ef2610e35a80e9/docs/dev/adb_wifi.md)（配对/adb_keys/TLS/A_STLS/mDNS 语义）、[docs/dev/root.md](https://android.googlesource.com/platform/packages/modules/adb/+/1cf2f017d312f73b3dc53bda85ef2610e35a80e9/docs/dev/root.md)（adbd root→shell 降权规则）、[MODULE_LICENSE_APACHE2](https://android.googlesource.com/platform/packages/modules/adb/+/1cf2f017d312f73b3dc53bda85ef2610e35a80e9/MODULE_LICENSE_APACHE2)
- AVF 权限定义（跨版本）：[main/android17-release：android/android.system.virtualmachine.res/AndroidManifest.xml](https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/android/android.system.virtualmachine.res/AndroidManifest.xml)、[android16-qpr2-release 同路径](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/heads/android16-qpr2-release/android/android.system.virtualmachine.res/AndroidManifest.xml)、[android15-release：java/AndroidManifest.xml](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/heads/android15-release/java/AndroidManifest.xml)、[android14-release：javalib/AndroidManifest.xml](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/heads/android14-release/javalib/AndroidManifest.xml)、[android13-release：javalib/AndroidManifest.xml](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/heads/android13-release/javalib/AndroidManifest.xml)
- AVF 强制点与客户端：[virtualizationservice/src/aidl.rs@main（check_permission：uid0 直通/IPermissionController/SECURITY）](https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/android/virtualizationservice/src/aidl.rs)、[libs/framework-virtualization/.../VirtualMachineManager.java（@hide @SystemApi @RequiresPermission）](https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/libs/framework-virtualization/src/android/system/virtualmachine/VirtualMachineManager.java)
- 授予门（development 旗标）：[PermissionManagerServiceImpl.java@1cdfff555f…（L1358 调用方 GRANT_RUNTIME_PERMISSIONS；L1405/L1592 isRuntime||isDevelopment→Good；目标包须已声明）](https://android.googlesource.com/platform/frameworks/base/+/1cdfff555f4a21f71ccc978290e2e212e2f8b168/services/core/java/com/android/server/pm/permission/PermissionManagerServiceImpl.java)、[Permission.java（isDevelopment=isSignature&&DEVELOPMENT 旗标）](https://android.googlesource.com/platform/frameworks/base/+/1cdfff555f4a21f71ccc978290e2e212e2f8b168/services/core/java/com/android/server/pm/permission/Permission.java)
- AVF 使用面参考：[TerminalApp/AndroidManifest.xml](https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/android/TerminalApp/AndroidManifest.xml)、[MicrodroidDemoApp/AndroidManifest.xml](https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/android/MicrodroidDemoApp/AndroidManifest.xml)

**Shizuku（GitHub permalink）**

- 管理器：[RikkaApps/Shizuku@b844bc49…（Apache-2.0 LICENSE）](https://github.com/RikkaApps/Shizuku/blob/b844bc491f1790c72328e1a8e5b2349f8978f0ea/LICENSE)、发布 [v13.6.0](https://github.com/RikkaApps/Shizuku/releases/tag/v13.6.0)
- 客户端 API：[RikkaApps/Shizuku-API@a27f6e41…/README.md](https://github.com/RikkaApps/Shizuku-API/blob/a27f6e4151ba7b39965ca47edb2bf0aeed7102e5/README.md)（UID 0/2000、UserService 语义）、[LICENSE（MIT）](https://github.com/RikkaApps/Shizuku-API/blob/a27f6e4151ba7b39965ca47edb2bf0aeed7102e5/LICENSE)
- 用户手册：[shizuku.rikka.app/guide/setup/](https://shizuku.rikka.app/guide/setup/)（页面自注 2023-06-21 更新）、[shizuku.rikka.app/introduction/](https://shizuku.rikka.app/introduction/)

**官方产品文档（developer/source.android.com）**

- [developer.android.com/tools/adb](https://developer.android.com/tools/adb)（含当日已见的 ADB Wi-Fi 2.0 章节与 "Android 17, alongside adb 37.0.0" 表述；"一次配对直到 Forget/Revoke"）
- [behavior-changes-16](https://developer.android.com/about/versions/16/behavior-changes-16)、[behavior-changes-17](https://developer.android.com/about/versions/17/behavior-changes-17)（ACCESS_LOCAL_NETWORK）
- [source.android.com AVF 概览](https://source.android.com/docs/core/virtualization)、[VirtualizationService](https://source.android.com/docs/core/virtualization/virtualization-service)、[Try AVF](https://source.android.com/docs/core/virtualization/tryavf)、[Write an AVF app](https://source.android.com/docs/core/virtualization/writeavfapp)、[Use cases](https://source.android.com/docs/core/virtualization/usecases)

**候选嵌入库（permalink 到锁定提交）**

- [MuntashirAkon/libadb-android@c849886ebc…（tag 3.1.1；双许可声明在 COPYING，另有 LICENSES/Apache-2.0 与 LICENSES/GPL-3.0-or-later）](https://github.com/MuntashirAkon/libadb-android/blob/c849886ebc6d48e7b46d967e78a6bb65c90c3b74/COPYING)、[README@同修订](https://github.com/MuntashirAkon/libadb-android/blob/c849886ebc6d48e7b46d967e78a6bb65c90c3b74/README.md)
- [mobile-dev-inc/dadb@55cb08849b…（master HEAD；v2.0.0；Apache-2.0 README）](https://github.com/mobile-dev-inc/dadb/blob/55cb08849b9b17c1e627156a0de11d91d36034de/README.md)
- [tytydraco/LADB@60f48029cf…（LICENSE 含"非原作者不得上传 Google Play"条款）](https://github.com/tytydraco/LADB/blob/60f48029cf9d8e0bc848ca41a7bd76694d4ab796/LICENSE)

**仓库内锚点（只引用未修改）**：`docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md` 第 3、9、17、20、21 章与 G08/G12/G13/G15、P0.9/P1.11/P2.12/P3.11/P5.9/P5.10/P6.5/P6.12 行。
