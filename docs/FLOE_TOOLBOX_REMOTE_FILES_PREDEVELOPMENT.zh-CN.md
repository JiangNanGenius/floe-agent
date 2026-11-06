# 工具箱：终端文件管理与常用软件交互预研

日期：2026-11-06。追加项 **TB26**；TB01–25（含 USB、漫游追踪）和原升级收件身份不变。本轮仍是独立模块预研发，未接入正式 App、修改签名/权限或发布。

## R4当前交付

远程文件已追加实际SCP二进制流、原生FTP/显式与隐式FTPS、WebDAV范围读取及条件文件上传，不再只有连接计划。SCP对接专用已认证SSH exec子通道，SFTP对接无PTY subsystem；Citadel/FloeSSH/临时机器“不保存”补丁及二进制适配器见[Integration](../FloeAgent/Modules/FloeToolbox/Integration/README.md)。关闭文件子通道不关闭终端SSH父连接。

原生传输队列先CAS保存再执行，绑定owner/machine/lease；中断中的写操作恢复为待复核，禁止无条件重放。编辑器保存回传检查远端修订与摘要，64KiB写入独占暂存文件，复核后提交；远端变化拒绝覆盖，本地文本/半成品仍可恢复。确认提交后会话迟失效与提交回执丢失分别回报。

独立互通：系统OpenSSH SCP上传/下载200KiB及恶意文件名拒绝；pyftpdlib普通FTP和显式FTPS；WsgiDAV/Cheroot范围读、条件上传、ETag冲突、默认不覆盖与MOVE。隐式FTPS已实现/编译，未在该服务矩阵单独实测。SFTP继续保留本机OpenSSH sftp-server管道证据，不等于真实SSH认证或跳板互通。

挂载复用Main的真实WorkspaceMountAdapter或File Provider，不新增凭据/挂载注册。桥接只声明已实现能力，缺少随机写、远端原子条件提交时拒绝对应通用续传/覆盖。现有SMBClient0.2.1的帧分片与无界目录聚合问题已定位，优先系统File Provider或修复后的现有adapter；未宣称原SMB库通过畸形服务器/真实SMB网络验收。

主App仍需收取路由、Keychain/数据库、jobs队列、文件选择/分享和实际编辑器owner；内置Linux文件与rsync使用原有解析环境/exec.shell服务。此后各节保留R3设计与审阅背景，其中早期“尚未编入”的状态已由本节R4实现取代。

## 界面与用户习惯

终端工具栏并列“文件”“AI 助手”。iPad 的右侧面板一次显示其中一个，避免终端被两个窄面板挤压；文件面板可展开为“我的文件 / 远端文件”双栏。iPhone、分屏窄窗口采用同一位置切换两端，返回时保留各自目录和选择。外层空间导航不改变。

SSH 文件默认使用当前机器的 SFTP；不要求再次填写主机或创建运行环境。内置 Linux 直接使用对应环境的文件服务。FTP、FTPS、WebDAV、SMB 是文件服务连接方式，切换后需要明确连接，界面始终显示文件服务目标；终端仍属于原 SSH 会话。临时机器和临时文件连接不默认保存，密码不进入配置草稿。工具箱保存机器、系统运行环境、已有网络挂载各自继续由原服务管理。

文件列表沿用文件夹、路径/上一级、名称、大小、修改时间、选择和操作菜单。基础范围包括目录浏览、上传/下载、新建文件夹、改名/移动、删除、文件信息，以及下载到现有编辑器后保存回传。回传绑定原机器、文件路径和下载时版本；源文件变化时先处理冲突，不能直接用本地旧副本覆盖。

传输队列位于展开界面下方，显示方向、两端、真实字节进度或未知总量、取消/重试和失败原因。冲突提供“跳过 / 替换 / 保留两者”；批量选择才提供“应用到本批”。目录任务逐层枚举，设置文件数、深度与总量上限，不自动跟随符号链接循环。传输与恢复归现有 jobs/service 生命周期所有，关面板不取消，换目标不能把旧回调写入新会话。

| 参考软件 | 采用的习惯 | Floe 的落点 |
| --- | --- | --- |
| [Termius iPad](https://www.termius.com/free-ssh-client-for-ipad) | 主机、终端和 SFTP 在同一工作上下文；文件传输与编辑后回传；外接键盘、额外按键和会话切换 | 机器选择沿用环境/工具箱/临时三种来源；终端内打开文件；AI 绑定当前会话。此处将用户所说的 Terminus 理解为 Termius |
| [RealVNC Viewer Mobile](https://help.realvnc.com/hc/en-us/articles/360018541231-Using-RealVNC-Viewer-for-Mobile-to-control-a-remote-device) | 鼠标相对移动与触控直接点击分开；双指缩放/滚动；键盘和辅助按键 | VNC 工具栏提供交互方式、适应窗口/实际大小、键盘、重连/断开；模式切换后显示对应手势说明；不增加 AI |
| [WinSCP](https://winscp.net/eng/docs/protocols) / [续传说明](https://winscp.net/eng/docs/resume) | 两端文件、传输队列、同名冲突、临时文件上传完成后提交 | iPad 展开双栏；窄屏切换两端；保留半成品；按实际适配器能力展示续传，不能给所有协议统一“断点续传”承诺 |
| [Postman](https://learning.postman.com/docs/use/send-requests/requests/) | 方法/URL、参数/请求头/请求体/认证与响应分开 | HTTP/API 保持外层独立；WebSocket 与 MQTT 也独立，不能重新混入串口助手 |

参考公开文档中的工作方式，不复制品牌、商业 UI 资源、账号/订阅体系或未要求的产品功能。

## 协议与复用矩阵

| 协议/入口 | 连接与操作范围 | 续传/提交边界 | 本轮实现或确定的接入点 |
| --- | --- | --- | --- |
| SFTP | 当前 SSH 的独立 `sftp` subsystem；列表、分块读写、建目录、改名、删除、符号链接信息/显式解析 | offset 读写；只在服务器协商支持时使用 OpenSSH POSIX rename；没有跨客户端条件替换/CAS 保证 | `FloeToolboxRemoteFiles` 有界 v3 客户端。SSH 身份验证、跳板机、host key、凭据仍由 `FloeSSH` 负责；正式接入需开放专用 subsystem 字节通道 |
| SCP | 同一 SSH 认证下的文件上传/下载 | 不虚构目录 API 或通用随机访问续传；取消需要关闭它自己的 exec/subsystem 通道 | 文件面板中的传输方式；后续接现有 SSH exec 服务的受控原生传输，不能在 App native host 运行 shell。现代 OpenSSH 的 scp 与旧 SCP wire mode 必须区分，不自动降级 |
| FTP / FTPS | 独立文件连接。FTPS 明确 TLS 模式（显式默认21，隐式默认990），两者均不同于 SFTP；FTP 由用户明确选择 | 被动数据通道；续传取决于服务端 REST/实际后端；FTPS 同时保护控制和数据连接，拒绝静默降成明文 | 当前主线未发现现成 FTP/FTPS adapter。可复用 libcurl 的库接口，先限定所需协议，接取消/有界流与现有信任/凭据服务；尚未编入 iOS 库或完成真实互通 |
| WebDAV | 复用已有 `WebDAVWorkspaceMountAdapter` 与挂载注册，不复制账号/文件入口 | ETag/If-Match 可用时保留；不能将一般 PUT 宣称为分块续传；MOVE 当前为不覆盖 | 现有读接口可能收到忽略 Range 的200整文件，且 `data(for:)` 先聚合响应。大文件接入前必须在底层落实范围验证、长度与流式上限，不能只在 UI 截断 |
| SMB | 复用已有 `SMBWorkspaceMountAdapter` / SMBClient | 实际 offset/写入/改名能力按接口确认；不把预先 stat 校验说成服务器原子 CAS，不承诺 SMB3 加密已通过实测 | 现有 Workspace 挂载服务与 Keychain credentialRef；当前整块写 API 需补流式适配后才能对外标为大文件续传可用 |
| 内置 Linux / 已解析运行环境文件 | 复用环境文件读写；显式 environmentID 与所有者 | 使用已有文件修订/提交机制；不绕一圈 SSH 到内置虚拟机 | `MachineReference.builtIn` → 现有环境文件服务，不另建环境注册中心 |
| rsync | 归“同步”，不作为目录浏览协议 | 先 dry-run 预览变更；删除/覆盖沿用现有审批；支持能力取决于已解析环境中实际命令 | 必须走该环境的 `exec.shell` / jobs，携带明确 environmentID。模型输出和远端文件名不能直接拼接 shell；不在 iOS native host 执行 rsync，不新增语言/宿主执行别名 |

libcurl 的 [TLS选项](https://curl.se/libcurl/c/CURLOPT_USE_SSL.html) 中 `CURLUSESSL_ALL` 要求全部连接使用 TLS；不能用允许降级的 TRY 或只保护控制连接的 CONTROL 作为 FTPS 默认。其 [证书说明](https://curl.se/docs/sslcerts.html) 要求验证证书链及主机名；Apple SecTrust 支持取决于所选 TLS backend，不能假定任意构建自动使用系统信任。若后续采用，应固定源码/构建配置并保留 [curl许可证](https://curl.se/docs/copyright.html) 及实际 TLS 依赖的通知；这里尚未新增该二进制依赖。

## 组件合同与失败语义

`RemoteFileSession` 绑定明确的 machine、root、owner/session/generation。每次读写复用宿主授权回调；等待授权后和异步结果返回后再次检查代次。后端按实际能力声明操作，未知协议/缺少能力明确报错。文件内容不自动送给 AI，文件名、目录项和服务端返回内容都不能授予权限。

路径进行组件级规范化和范围判断，服务端列表不能返回目录外的子项。SFTP 读取/写入前解析已有路径或父目录以拒绝已观察到的越界链接；显式跟随链接同样检查范围。远端账号权限仍是服务器边界，客户端路径检查不能充当服务器 jail，也不能消除另一个客户端同时改符号链接的竞争。

SFTP 使用 [v3 wire draft](https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02) 与 [OpenSSH扩展](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL)。该 v3 文档是历史 Internet-Draft，不能称为现行 IETF RFC。只协商 v3；请求ID必须匹配；帧1 MiB、单次接收64 KiB、列表10,000项/1,024批且路径元数据最多8 MiB；逐字段检查长度、属性和文件名，重复路径报错；不使用 whole-file read。所有变更检查 STATUS，目录/文件 handle 在成功与失败路径关闭，关闭失败即隔离通道。畸形帧、错配ID和取消会关闭专用文件通道；宿主必须让 close 中断阻塞的收发、提供连接超时，并保证关闭的是文件通道而非整个PTY/终端。

`RemoteFileTransfer` 以64 KiB流复制到目标目录下独占创建的 `.floe-<id>.part`，完成后才改名提交。默认不覆盖；用户明确替换时，先复核原目标版本，再使用真实支持的原子替换。SFTP 的版本复核与 rename 是两个操作，不宣称条件原子提交。上传权限不足、源变化、目标变化、取消或断线保留可恢复半成品，原目标在提交前保持原内容。

续传必须匹配原任务、两端机器、路径、源版本、半成品大小，并分块重算源前缀和半成品 SHA-256，与已保存 checkpoint 一致才继续，不能仅按文件长度拼接。checkpoint 和队列交给宿主现有持久层。提交已确认但会话刚失效，回传“已完成”的明确状态；提交响应丢失则要求核对，禁止自动当成没发生后重试覆盖。

## R3时的主线审阅背景与收件

主线审阅基于2026-11-06实际文件，后续收取需对最新 main 复核，不能整树覆盖：

- `FloeSSH/SSHConnectionService.swift` 当前公共 handle 有 PTY/direct TCP，没有文件 subsystem；底层 Citadel client 为模块内访问。需要在同一 SSH 服务增加专用文件通道、超时和关闭句柄，保留现有 host-key/credentialResolver 链。
- 当前 SSH connect 路径会先持久化 profile。工具箱“临时机器”接入前要加入明确的“不保存”策略；不能调用后再删除来模拟临时连接。
- 当前固定 Citadel revision `ae8562f895de06ccb86fdb1cbb65fd99c8976e12` 的高层列表会累计目录、无数量上限，变更辅助方法未全部检查 STATUS；不能原样对不可信响应宣称满足本组件合同。本轮有界 wire 层不替换 SSH 加密/认证实现。
- `FloeWorkspace/NetworkWorkspaceMount.swift` 已有 SMB/WebDAV 真实 adapter。优先适配现有服务，并修正上述范围/聚合/流式缺口；接线前不能只套一个泛型 closure 就把协议标成已完成互通。
- Native `RemoteFilesPanel`、连接协议选择、终端 inspector 和队列视图留在独立 UI target；文件选择器/分享、编辑保存回传、真实 jobs持久化和 App 路由由后续集成收取。VNC手势与终端额外按键使用已有会话，不因参考软件新增执行权限。

R3的54项Swift Testing、Core/RemoteFiles/UI iOS arm64对象编译、109项DOM状态检查通过；真实浏览器在1024/736/320宽度完成布局/交互抽查并保留截图。SFTP完成本机OpenSSH管道互通，未建立远程SSH认证；其余协议保留上表的真实接入状态。原始失败和修正后结果分别保留，详见[QA记录](FLOE_TOOLBOX_PREDEVELOPMENT_QA_PLAN.zh-CN.md)。没有正式App安装、真实外部服务器、USB硬件或分发验收，未修改现有App Store/TestFlight任务。
