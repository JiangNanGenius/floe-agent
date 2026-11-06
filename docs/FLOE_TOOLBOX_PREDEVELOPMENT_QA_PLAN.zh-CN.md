# 工具箱与串口助手：QA 和独立模块预研发

日期：2026-11-06。状态：用户确认界面方向并完成本轮 QA，已授权独立模块预研发；尚未接入正式 App、构建发布版本或进行真实设备验收。

## 已确认的产品决定

| ID | 决定 |
| --- | --- |
| TBQA01 | 空间导航为“概览｜手记｜文件｜工具箱”，工具箱位于文件之后。保留原 Agent 外壳与作品入口。 |
| TBQA02 | 终端支持内置 Linux、系统远端环境、工具箱保存机器和临时机器，可跳转系统设置添加运行环境。临时机器不自动保存，工具箱机器不自动成为运行环境。 |
| TBQA03 | 终端提供绑定当前会话的 AI 助手；VNC 保持直接操作，不加入 AI。工具箱包含“浏览器”入口，名称不加“内置”。 |
| TBQA04（后续修订） | 工具箱只有一个“串口助手”入口，进入后选择 TCP、UDP、蓝牙或 USB 连接方式，再选择通用收发或 Modbus 协议；Modbus 的 MBAP/RTU 封装明确选择。HTTP/API、WebSocket、MQTT 是与串口助手同级的独立入口，归“通信工具”组。原传输与协议能力完整保留，不再拆成主页工具行。 |
| TBQA05 | 串口助手的 AI 支持捕获和分析当前工具的收发数据，并导入 PCAP/PCAPNG。首版不自动扩成设备级、其他 App 或远端系统流量捕获。应用收发记录、协议消息和真实链路包分别标注。 |
| TBQA06 | AI 可在用户授权范围内自动诊断和收发；写入沿用现有审批和权限服务。收到的数据、导入文件、模型建议不能授予权限或改变目标。 |
| TBQA07 | 终端与通信记录默认自动保留，设滚动上限，支持手动保存和导出。滚动截断必须可见；明确保存的快照不随活动缓冲滚动删除。凭据不进入记录或分析提示。 |
| TBQA08 | USB 驱动扩为常见可支持芯片的独立代码预研。用户承担硬件兼容性测试，不保证芯片可用，也不以硬件实测作为本阶段等待项。本阶段完成代码/编译、边界及失败路径验证，重点防止异常拖垮宿主；不能把静态验证表述为绝对不会闪退。尚未授权修改正式 App 签名、提交新权限或发布。 |
| TBQA09（新增） | 网络诊断增加“漫游追踪”，按 Wi-Fi 接入点变化、连通性延迟和丢包记录；与路由跟踪分开。未知 BSSID、信号、未执行探测和观察中断均明确标注，不把延迟上升当成漫游，不推算精确切换时长。 |
| TBQA10（追加） | 终端增加文件管理。SFTP为SSH默认文件方式，SCP、FTP/FTPS、WebDAV、SMB纳入预研，rsync归同步；内置环境直用现有环境文件。文件与AI共用终端的一个可切换右面板，可展开双栏/窄屏两端切换，带队列、冲突、取消与恢复。各协议的目录、续传和原子操作按实际能力提供。 |
| TBQA11（交互参考） | SSH/文件参考Termius，VNC参考RealVNC，传输队列参考WinSCP等常见习惯。VNC仍不增加AI。参考公开文档，不引入其他软件的账号/付费门槛或复制商业资源。 |

## R4 QA结果与当前实现

R4已从连接合同补到实际客户端：原生TCP/UDP/WS、HTTP请求、MQTT3.1.1/5连接与QoS0/1/2、Modbus读写；网络诊断/漫游、校验/JSON/编码/二维码；SCP/FTP/FTPS/WebDAV、持久队列与编辑回传；USB service/user client/IPC及现有SSH/BLE/挂载桥接。根package增加对应products，Core仍复用同一会话、记录和授权边界。

累计完成87项组件测试（整包84项，加新增3项及受影响检查）包含原Core39/RemoteFiles15和新客户端、诊断、USB、实用工具、传输检查。独立服务互通使用Mosquitto2.1.2、pymodbus3.6.9、pyftpdlib2.1.0、WsgiDAV4.3.3/Cheroot10.0.1以及系统OpenSSH；不是本模块自回环假协议服务器。新增桥接与格式检查、iOS26对象编译和7项接入检查均已通过，详见最终资格记录。

原生AI适配器复用现有FloeTools目录/runner，绑定原生runID、会话代次及实际可用工具集；8项操作覆盖记录、原始收发、Modbus读写、MQTT发布/订阅、HTTP读写。写入要求已有审批grant并继续通过原授权回调；临时/子任务、错误run、缺失grant、只读伪装写、记录指令和不确定提交不重发均有边界检查。终端仍走现有exec.shell/解析环境链，不注册重复执行入口。

保留的首轮问题与修正：URLSession WS握手超时后改为原生Network WS并通过互通；Darwin ICMP包含IPv4头导致原解析假设错误，已规范化两种交付方式；TCP最后一块数据伴随EOF须先交付数据；FTPS测试证书必须为正确CA签发的serverAuth/SAN leaf；WebDAV测试采用HTTP1.1 Cheroot，原HTTP1.0失败保留。没有关闭TLS校验或放宽失败断言。

USB真实iig与DriverKit27对象编译通过，IPC/描述符150,000次ASan/UBSan随机输入通过。现有SMB库缺少接收分片/目录聚合边界，已在Integration交接，不以返回后的泛型适配限额冒充上游修复。未运行实体USB、BLE、Wi-Fi漫游、外部账号或正式App验收；这些不作为本轮独立预研发等待门槛。

## 独立预研发范围

独立 Swift package 位于 `FloeAgent/Modules/FloeToolbox/`，不添加到正式 App 工程，不更改版本、标签、签名或渠道状态。

早期实现基线覆盖：连接/会话身份、可取消的生命周期、带真实层级与来源的有界记录、滚动持久记录与显式快照、PCAP/PCAPNG 导入、TCP/UDP/蓝牙的传输合同、Modbus 与 MQTT 字节解析、WS 消息层记录，以及绑定目标与授权回调的 AI 上下文/动作接口。已有 SSH、VNC、浏览器、HTTP、蓝牙和原始 TCP 服务通过宿主适配复用，避免另建主机、凭据、模型、审批或执行环境体系。传输合同和可打开的设计页不代表这些客户端已经在正式 App 中接通。

Modbus 的传输与线格式独立：TCP 的 MBAP 和 RTU 的 CRC 帧分别处理；UDP、蓝牙、USB 桥接的封装由设备配置明确选择，不把自定义桥接声称为统一的标准 Modbus UDP 协议。USB 已增加芯片请求适配、连接错误边界和公开 USBDriverKit C++ 后端，不把尚未接入的硬件报告为可用；R4已增加真实service/user client与版本化IPC；完整dext打包、签名、团队权限及App接线另行收取。

AI 输入按用户选择的会话、记录范围和字节上限提取；只有当前目标的真实记录可被引用。解析事实和模型推断分开，错误、缺包、未知协议及加密载荷保持可见；不承诺自动解密任意导入流量。发送、重发和写入前沿用当前宿主授权检查，异步审批后再次核对会话身份与代次。

## 验证与后续接入

- 使用真实字节夹具验证分片、粘包、超限、截断、错误帧、CRC、PCAP 字节序和 PCAPNG 块边界；不以演示字符串代替解析。
- 验证滚动上限、重启恢复、快照独立保留、损坏记录保护、并发修订与旧会话迟到结果。
- 验证 AI 上下文隔离、授权拒绝、审批期间切换目标、取消与恢复；不伪造真实模型回答。
- 本地 Swift 6 测试与 iOS arm64 对象编译分别保存证据。组件编译不代表正式 App、实体设备或所有协议互通验收。
- 首版与R2的浏览器截图验证当时受工作设置限制。R3重新检查后浏览器已可用，完成真实浏览器布局与交互抽查，保留截图；原生App/Simulator与浏览器预览分别验收。

规范来源：[Apple Network WebSocket API](https://developer.apple.com/documentation/network/nwprotocolwebsocket)、[Modbus 规范](https://www.modbus.org/modbus-specifications)、[MQTT 5.0](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html)。抓包文件格式实现以 IETF/pcap 文件格式原始文档为依据，最终支持的链路类型及限制在模块交接中逐项说明。

抓包格式对照：[PCAP draft-09](https://datatracker.ietf.org/doc/html/draft-ietf-opsawg-pcap-09)、[PCAPNG draft-06](https://datatracker.ietf.org/doc/html/draft-ietf-opsawg-pcapng-06)（均为进行中的 Internet-Draft）。

## R3与更早收件（历史，当前实现见R4）

**R3终端文件追加：** TB26、TBQA10–11已纳入收件。54项Swift Testing通过（Core39、RemoteFiles15），Core/RemoteFiles/UI完成iOS arm64真实对象编译。SFTP与macOS自带OpenSSH sftp-server完成管道互通和实际文件内容读回；支持协商后的POSIX替换。没有建立远程SSH认证连接，也没有以此结算FTP/FTPS/SCP/SMB/WebDAV互通。109项预览DOM状态检查通过；另以真实浏览器核验1024/736/320宽度及文件两端切换、上传冲突、队列和返回终端，无横向溢出/控制台错误，保留4张截图。

远程文件覆盖路径/解码边界、授权拒绝与代次、已观察的越界链接、分块上限、取消保留原文件、摘要验证续传、同长度半成品篡改、目标并发修改、确认提交后会话失效、提交回复丢失需核对、服务器STATUS失败、错配ID/超限、句柄关闭失败、取消解除阻塞和真实OpenSSH内容校验。初次缺失try导致的编译错误、一次测试夹具管道阻塞（已中断）及一次预览测试初态错误均保留原记录；修正后以当前源码重新通过，不把中断当通过。

主线SSH临时连接当前会持久化profile、缺少公共文件subsystem、现有WebDAV范围/响应聚合与SMB整块写等接入缺口，已在[专项预研](FLOE_TOOLBOX_REMOTE_FILES_PREDEVELOPMENT.zh-CN.md)明确。队列持久化、编辑保存回传、批量目录、真实宿主接线及完整USB extension/IPC仍按对应服务合同收取；本阶段不以接口存在宣称正式App可用。

**R2结构修订（历史）：** 主页 **18 个入口**。TCP/UDP/蓝牙/USB/Modbus 的五个旧入口合为一个串口助手，另增漫游追踪；HTTP/WS/MQTT 仍独立。原能力和先前27个统筹条目未删除。38项Swift Testing、Core/UI iOS arm64对象编译、87项预览DOM状态检查通过。AP观察与Ping分开采样，未采集AP与信息不可用分别记录；真实系统采集、任务生命周期与正式存储仍由后续宿主适配。

**首批快照记录（修订前，保留原始数值）：**

- 30 项 Swift Testing 通过，覆盖协议真实字节、文件格式、记录/CAS/恢复、审批和会话切换、上下文边界及 USB 异常返回。
- Core 与 SwiftUI 已完成 iPhoneOS 27.1 SDK、`arm64-apple-ios26.0` 的真实对象编译；不是仅 typecheck。
- USB C++ 后端以 DriverKit 27.0 SDK/target、arm64 和严格警告完成对象编译，本轮复用未改源码的产物并读回 Mach-O。26.0 target 被编译器改为 27.0 后在 Werror 下失败，保留失败记录，不声称较早 driver target 已通过。
- 更新预览保留原 20 工具并追加 USB，共 21 项；79 项本地 DOM 状态检查通过。它是交互示例，没有真实连接、模型调用、抓包导入或浏览器截图证据。
- 主 App 路由、现有服务/模型/正式存储适配、完整 USB extension/IPC/签名和真实网络/设备行为仍待接入；不以工具目录或接口存在结算为全部功能可用。

可收取的代码与边界见 [模块 README](../FloeAgent/Modules/FloeToolbox/README.md)。
