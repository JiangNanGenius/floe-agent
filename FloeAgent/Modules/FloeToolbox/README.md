# FloeToolbox 工具箱模块

工具箱 TB01–26 的源码包：终端/远程文件、VNC、浏览器、串口助手、独立 HTTP/WS/MQTT、网络诊断与漫游、记录/AI、USB 和实用工具。当前源码已接入主 App 的空间工具箱；版本、签名和分发仍由主线管理，USB 驱动包尚未随 App 接入。空间入口为 **概览｜手记｜文件｜工具箱**，VNC 不带 AI。

## 代码与运行边界

| Product / source | 已实现 |
| --- | --- |
| `FloeToolboxCore` | 18入口、机器来源/临时连接计划；会话代次、既有审批回调、终端AI；原子CAS滚动记录、快照/JSONL、凭据过滤；PCAP/PCAPNG、Modbus/MQTT解码；USB芯片配置计划。 |
| `FloeToolboxClients` | 原生TCP流、保留报文边界的UDP客户端（可绑定本地地址/端口）、WS文本/二进制/Ping/TLS；HTTP请求/有界响应/同源重定向/文件上传；MQTT3.1.1/5连接、订阅、QoS0/1/2、keepalive；Modbus01–06/15/16的MBAP/RTU请求、响应关联、CRC、异常、广播。接收服务及原有BLE服务的MTU分块桥接。 |
| `FloeToolboxDiagnostics` | 实际IPv4 ICMP Ping/路由、DNS-SD记录查询、显式端口检测、Bonjour发现、公开Wi-Fi信息；AP身份和延迟探测独立采样的漫游服务。iPadOS无法取得的数据留空，不伪造RSSI或漫游。 |
| `FloeToolboxUtilities` | 流式SHA256/512/SHA1/MD5/CRC32、JSON整理、UTF-8/Base64/URL编码、二维码PNG生成/图片识别。选文件和保存由宿主提供。 |
| `FloeToolboxRemoteFiles` | 已认证独立SSH子通道上的有界SFTPv3；路径/根目录/会话/审批检查；64KiB暂存传输、修订和摘要续传、协商后的原子改名；rsync结构化计划。 |
| `FloeToolboxFileTransports` | SCP二进制传输、FTP/显式和隐式FTPS、WebDAV范围读取和条件流式上传；复用挂载/File Provider的有界接口；持久队列CAS/中断恢复复核；编辑保存回传、冲突与提交结果不确定处理。 |
| `FloeToolboxUSB` + `FloeToolboxUSBWire` | 版本化IPC、描述符/端点验证、IOKit异步客户端、请求代次、短写及断开；CDC-ACM、FTDI、CP210x、CH34x、按修订判断的PL2303候选。 |
| `DriverKit/` | 原创driver service、独占user client、严格ExternalMethod、实际USB控制/批量后端；真实iig生成和DriverKit对象编译。尚非已签名/可安装的dext。 |
| `FloeToolboxUI` | 首页/连接及协议选择、机器来源、终端文件/AI互斥inspector、双栏与窄屏文件面板、队列/冲突、VNC控制、收发和漫游时间线。 |
| `FloeToolboxWorkbenches` | 原生HTTP、WS、MQTT、Modbus操作、记录/AI、诊断及实用工具面板，含忙碌、取消、错误反馈与中英文文案。 |
| `Integration/` | 固定Citadel版本的独立文件子通道、现有FloeSSH接入及临时机器不保存补丁；真实Main蓝牙/挂载接口桥接。为避免依赖环，这些源文件由主线按目标分别收取，未自动加入根package。 |

## 已确认的产品规则

- 串口助手内部先选 **TCP / UDP / 蓝牙 / USB**，再选通用收发或Modbus（MBAP/RTU）。HTTP/API、WebSocket、MQTT在主页独立；普通iOS蓝牙采用兼容GATT附件，不能当作任意经典蓝牙SPP。
- 终端可选内置Linux、系统环境、工具箱机器或不保存的临时机器，也可转到系统设置新增环境。复用现有SSH、VNC、浏览器、文件、jobs、模型和凭据服务；SSH/VNC配置各自独立。
- 记录默认自动滚动：10,000条/8MiB，单条256KiB；手动快照不参与滚动。PCAP导入默认64MiB/100,000包。JSONL为应用记录，不伪装成网络PCAP；不提供设备级抓包、TLS解密、乱序TCP/IP分片重组。
- AI读取有界脱敏上下文，区分事实/推断；建议收发仍走当前会话审批。Modbus写与MQTT PUBLISH按实际报文判断；HTTP带方法和脱敏路径供审批。数据、终端输出和导入包不能更换目标或授予权限。
- 不能用通用字符串扫描识别任意二进制秘密。宿主必须提供已知凭据redactor及其专有敏感字段策略。记录请求已发起不代表设备已收到或写入成功。
- SFTP检查+rename不是远端CAS；仅协商POSIX rename开放覆盖。SCP/FTP/WebDAV/挂载各用真实能力，不假造通用随机写入或续传。中断的队列写入恢复为待复核，不自动重放。
- SMB复用现有挂载/File Provider。`Integration`明确记录现有SMBClient0.2.1的帧分片与目录聚合缺口；适配器返回后的限额不能约束上游内部内存。优先使用系统File Provider或经修复的宿主适配器，不能直接把旧库标成安全可用。
- USB只进行代码、对象编译及错误路径验证，硬件由用户测试；芯片匹配是候选，不保证兼容。按Apple公开DriverKit路线分发，App/driver团队权限、实际USB匹配和系统启用另行接入；不复制他人权限、不下载额外可执行驱动、不用音频保活。

## 主 App 接入与普通聊天工具

当前首页采用横向展示与完整工具列表，宽屏列表为两列。诊断结果绑定本次请求；漫游默认取当前网关并保留手输，SSID/BSSID 取决于系统权限和有效签名。导出使用实际文件与系统分享入口。通信分析由连接服务持有，有进度、停止、超时和晚结果隔离。

普通任务可先调用 `toolbox.session` 的 `open`，再使用实际会话的 `toolbox.websocket.send`／`receive`、`toolbox.mqtt.subscription`／`publish` 和 `toolbox.capture.read`，最后 `close`。当前普通入口支持无认证 ws/wss 和匿名 MQTT；认证连接仍从原生界面配置并打开其助手。目标不可在会话中静默改变，仍使用现有运行授权；不要求工作区或 Linux。会话随本轮运行取消、结束或任务删除而关闭，临时聊天不提供此链路。通信记录是本会话的脱敏收发，不是系统抓包。

The App uses a horizontal showcase and the complete tool list, with two columns on wide screens. Diagnostics retain request identity; roaming uses the current gateway when available. Wi-Fi identity requires system authorization and valid signing. Export uses actual files and system sharing. Analysis belongs to the connection service and supports progress, Stop, deadlines and late-result fencing.

Ordinary tasks open a native connection through `toolbox.session`, use the applicable WebSocket or MQTT actions and `toolbox.capture.read`, then close it. This entry supports unauthenticated ws/wss and anonymous MQTT; authenticated connections use the native configuration and its assistant. Existing runtime authority binds the exact target, task and run without requiring a Linux workspace. Cancellation, run termination and task deletion close the owned connection. Temporary chat does not expose this chain. Captures contain redacted session traffic, not system packet capture. USB still requires a separately packaged and authorized DriverKit extension.

## 验证与复现

另有7项真实Main接口/SSH子通道/原生AI工具边界测试通过，包含真实GRDB临时主机不落库及拒绝越权、脱敏、结果不确定隔离。

当前工具链为Xcode27.2（27B52）/Swift6.4.2，部署目标iOS26。资格脚本在取得项目原生构建锁后记录输入摘要，并在结束时核对没有源码变化：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 FloeAgent/Modules/FloeToolbox/Scripts/qualify.py ios \
  --output Local/Private/toolbox-qualification/ios \
  --scratch "$HOME/Library/Caches/CodexBuild/Floe/main/Xcode27.2/Toolbox-iOS"
```

测试模式把`ios`改成`test`。macOS网络互通测试需要独立loopback fixtures：Mosquitto2.1.2（`FLOE_TOOLBOX_MQTT_BROKER`）；Python环境内pyftpdlib2.1.0、pyOpenSSL25.3.0、WsgiDAV4.3.3、Cheroot10.0.1、pymodbus3.6.9（`FLOE_TOOLBOX_FTP_PYTHON`）。FTPS测试需新生成、含serverAuth/SAN的服务器证书+独立CA：`FLOE_TOOLBOX_FTP_CERT`、`FLOE_TOOLBOX_FTP_KEY`为服务端文件，`FLOE_TOOLBOX_FTP_DER`为受信CA DER。这些只属于测试环境，不进入App依赖或发布；缺少fixture会明确失败。SFTP/SCP使用系统OpenSSH测试进程，不需要真实账号。测试服务均由fixture结束时关闭。

R4累计87项组件测试通过（整包84项与新增/受影响检查），包括本机OpenSSH、独立FTP/FTPS、WsgiDAV/Cheroot、Mosquitto3.1.1/5与pymodbus互通；另有7项接入/原生AI边界检查、iOS26全部产品及宿主适配器对象编译通过，按最终收件记录核对。USB另有150,000次ASan/UBSan随机IPC/描述符检查及真实DriverKit27对象编译。R3的54项及iOS26对象编译、109项DOM检查和1024/736/320真实浏览器检查作为历史证据保留；原始失败也保留，未用重试掩盖。

以上 R3/R4 是独立预研阶段的历史证据。主线现已连接 App 入口、任务/模型/授权、数据库、文件选择/分享与 jobs；当前内部候选的相关 App 测试和 UI 结果另行记录。USB 驱动包、外部服务账号和硬件行为保留各自实际边界；独立组件测试、浏览器示例和对象编译不代表 App 发行或设备验收。

相关约定：[全部功能清单](../../../docs/FLOE_TOOLBOX_PREDEVELOPMENT_INVENTORY.zh-CN.md)、[QA决定与检查](../../../docs/FLOE_TOOLBOX_PREDEVELOPMENT_QA_PLAN.zh-CN.md)、[远程文件](../../../docs/FLOE_TOOLBOX_REMOTE_FILES_PREDEVELOPMENT.zh-CN.md)、[USB许可与Apple规则](../../../docs/FLOE_USB_SERIAL_REUSE_RESEARCH.zh-CN.md)、[Integration接入说明](Integration/README.md)。第三方MIT移植保留完整[许可证与归属](ThirdParty/NOTICE.md)。商业TP-Link安装包、拆包材料均不在交付内。
