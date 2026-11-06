# Main接入桥接

这些是模块预研发的可收取源码，不自动改变Main的依赖、App或权限。保持Main现有服务为唯一的凭据、模型、环境、任务、挂载和审批所有者。

1. `Citadel/FloeFileChannels.swift`编入固定Citadel `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`：在已经认证的session上开独立无PTY的SFTP subsystem或结构化SCP exec子通道，限时/取消只关闭子通道。不要编辑共享SwiftPM缓存；通过既有vendor/patch流程固定来源与补丁。
2. `FloeSSH/FloeSSHFileChannels.swift`编入FloeSSH，公开现有SSHSessionHandle的该能力。`temporary-hosts.patch`基于当时Main源生成；收取时先`git apply --check`，按最新Main局部移植。`connectTemporary`不持久化机器、不新增/触碰known-host记录；已有key校验、人工首次确认和更改拒绝仍保留。常规`connect`行为保持原有策略。
3. `FloeToolboxSSH/SSHRemoteFileByteChannel.swift`编入独立适配目标（依赖Core/RemoteFiles/NIOCore/NIOSSH），限制缓冲、stderr、读取与取消，EOF前已收到的字节可以读完。它不关闭宿主SSH客户端。
4. `FloeToolboxHost/SSHFileBridge.swift`依赖FloeSSH、Citadel、上述适配目标及FileTransports。会话lease/machine不可重绑定；关闭终端或切换机器时由原owner关闭文件session/队列任务。
5. `BluetoothBridge.swift`依赖Main的FloeExecution。复用BluetoothSerialServicing，捕获不可变runID/sessionID/peripheral；用20字节保守ATT分块。`HostBluetoothSerialConnection`保留写操作顺带读出的RX数据，避免Main组合exchange接口丢消息。系统权限仍在原服务；无硬件兼容性声明。
6. `WorkspaceMountBridge.swift`依赖FloeWorkspace，绑定已有resolved adapter/相对根，复用凭据；分页缓存有界，关闭只释放本引用。它只宣告真实只读能力，不替宿主承诺覆盖CAS/随机写。完整上传可使用原生WebDAV条件上传或宿主File Provider能力。

现有Main SMBClient0.2.1的Connection接收假设首次TCP数据至少含4字节NetBIOS头，Session.queryDirectory会无界聚合；因此不能把返回后限额当作上游修复。SMB先使用系统File Provider或经独立修复的既有adapter。没有在这里引入第二个SMB SDK、复制凭据或静默启用旧实现。该缺口不影响SFTP/SCP/FTP/FTPS/WebDAV已经通过的互通证据。

资格使用真实固定Citadel/NIOSSH/NIO、真实Main Core/Models/Security/Tools/Persistence/SSH源码快照，以及实际NetworkWorkspaceMount与BluetoothSerialService（含SessionExpiryScheduler）组件；不以同名空壳替代接口。文件子通道检查覆盖二进制/EOF/stderr、取消、独立生命周期；临时连接检查使用实际GRDB内存数据库。完整App接线、真实SSH认证/跳板、SMB服务、蓝牙附件和真实模型留给主线/用户验收。

## Existing native tool registration

`NativeToolboxTools.register(in:enabledNames:resolve:)` adds eight concrete operations to the existing FloeTools catalog/runner: `toolbox.capture.read`, `toolbox.serial.send`, `toolbox.modbus.read/write`, `toolbox.mqtt.publish/subscription`, `toolbox.http.read/write`. The adapter target also depends on FloeCore/FloeTools/CryptoKit. `ToolboxAIHostContext` is an immutable value with runID/lease, existing journal/client references, required redactor and `isCurrent` closure; it is not a service registry. Its `availableToolNames` must be frozen into this task's allowed/effective tool catalog. Resolve from the native run binding, never the current global UI or model-provided session/endpoint.

The callable boundary checks the actual execution name, task capability ceiling, run identity, temporary/child restrictions and host generation. Mutations require the existing runtime approvalGrantID and continue through the original session authorization callback. Structured Modbus and MQTT actions cannot use raw serial send. Unconfirmed mutation outcomes use the runtime's existing `ToolExecutionOutcomeUnknownError`, without internal replay. Read-only Modbus/HTTP tools reject write arguments before transport. Captures are again redacted, bounded to64KiB output, and marked untrusted.

Terminal AI continues to use the existing `exec.shell`/resolved-environment tool chain and `TerminalAssistant` host; no duplicate terminal execution alias is registered. Diagnostics reuse existing `network.*` tools. Real provider calls/approval UI and task binding persistence are Main acceptance boundaries.
