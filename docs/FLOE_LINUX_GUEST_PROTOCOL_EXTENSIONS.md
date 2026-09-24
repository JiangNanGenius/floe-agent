# Floe Linux guest 控制台协议扩展（分块 / PTY / 后台服务 / 可选宿主桥）

Dated: 2026-09-24 · Status: 分块信封、PTY 会话、后台服务与可选 `floe-host`
桥的 **host runner 侧与 host 端接线均已实现**；仓库 `host_protocol_check.sh`
覆盖帧与路由行为，真机/镜像内的闭环仍由镜像资格任务完成（见 §5 与 §6）。

本文是 `docs/FLOE_LINUX_GUEST_BACKEND.md` 的补充：一次性 `FLOE-EXEC` 之外的
分块信封、交互式 PTY 会话、后台服务帧与可选的 guest → host 控制请求。
实现位于 `FloeAgent/LinuxGuest/runner/floe_exec.c`（guest 端）；host 端帧构造
与路由在 `FloeExecution/Linux/LinuxGuestCommandChannel.swift`，宿主处理器由
App 层注册（`ArchiveCompressedBridge.swift` / `AppEnvironment.swift`）。

## 0. 通用约定 / Frame rules

- 每个 host→guest 帧以 `0x1e` + `FLOE-` 开头。
- 帧结束：首个 `\n`，或（帧体不含 0x1e 时）闭合 `0x1e`（后面可有可无 `\n`）。
  guest runner 两种终止都接受，便于 host 用行语义或标记语义发送。
- guest→host 仍是标记流：`\x1eFLOE-<NAME> <token>[\x1e 或 空格参数]`；输出段
  `OUT`/`ERR` 的原始字节一直持续到下一个标记。
- 命令/会话并发：protocol 3 的 host 通道按 token 解复用，允许同时最多
  `LinuxGuestLimits.maxConcurrentCommands` 个命令与
  `maxConcurrentSessions` 个 PTY 会话；guest runner 用同一张 token 表路由。
  （pre-protocol-3 的旧 runner 只按串行服务，host 在 runner 升级路径上显式
  进入 legacy 串行模式，不会假定扩展可用。）
- 所有载荷有界：单信封 ≤ 256 KiB（host 侧另有更小上限），字段数 ≤ 4096。

## 1. 分块信封 / Chunked envelope (EXEC/OPEN/SPAWN)

小信封（整行 < ~3.8 kB，保证 tty 行缓冲安全）继续走 inline：

```
\x1eFLOE-EXEC <token> <base64 payload>\n
```

大信封走分块（canonical）：

```
\x1eFLOE-EXEC <token> <payloadBytes> <chunkCount>\x1e\n
\x1eFLOE-CHUNK <token> <index> <base64>\x1e\n      × chunkCount（index 0..N-1 顺序）
\x1eFLOE-RUN <token>\x1e\n
```

- 判别：`token` 之后若恰为两个十进制整数则为分块头，否则按 inline base64。
- 每个 CHUNK 是独立 base64（≤3000 字符，避免超过 tty 4096 缓冲）；guest 逐块
  解码后顺序拼接，`RUN` 时校验 `chunkCount` 与 `payloadBytes` 完全匹配。
- `OPEN`/`SPAWN` 用同样的分块头，仅帧名不同；字段布局见下。
- 越界、乱序、重复块：重复块忽略，乱序/超界放弃该组装并在 `RUN` 时回
  `ERR` + `END 125`。

## 2. PTY 会话 / Interactive session

```
host: \x1eFLOE-OPEN <token> <payloadBytes> <chunkCount>\x1e\n + CHUNK… + RUN
payload 字段 = [mode="pty", cwd, cols, rows, argv0, argv1, …]

host 输入: \x1eFLOE-IN <token> <base64 bytes>\n
信号:      \x1eFLOE-SIGNAL <token> INT|TERM|WINCH <rows> <cols>\x1e
关闭:      \x1eFLOE-CLOSE <token>\x1e

guest: \x1eFLOE-BEGIN <token>\x1e
       \x1eFLOE-OUT <token>\x1e <pty 合并输出原始字节…>
       \x1eFLOE-END <token> <exit>\x1e
```

- guest 用 `posix_openpt`/`grantpt`/`unlockpt` + 子进程 `setsid()` +
  `TIOCSCTTY` 建立会话；`cols/rows` 通过 `TIOCSWINSZ` 生效，
  `SIGNAL … WINCH <rows> <cols>` 更新 winsize 并向会话进程组发 `SIGWINCH`。
- host→guest 的输入必须是 base64 分帧（`FLOE-IN`）：串口上无法可靠传原始
  字节，裸 `0x1e`/`0x03` 会撞帧或被 tty 解释。
- `SIGNAL INT/TERM` 与 `CLOSE`：只杀本会话进程组（SIGTERM，750 ms 后
  SIGKILL）；`END` 用 128+首个信号（INT=130，TERM=143）。会话正常退出时用
  真实 wait 状态。
- 控制台裸 `0x03` 在会话期间等价于对该会话进程组发 `SIGINT`。
- 会话输入缓冲上限 1 MiB，超出丢弃而不增长内存。

## 3. 后台服务 / Background services

```
host: \x1eFLOE-SPAWN <token> <payloadBytes> <chunkCount>\x1e\n + CHUNK… + RUN
payload 字段 = [cwd, logPath, argv0, argv1, …]

guest 成功: \x1eFLOE-PID <token> <pid>\x1e + \x1eFLOE-END <token> 0\x1e
guest 失败: \x1eFLOE-ERR <token>\x1e <text> + \x1eFLOE-END <token> 125|126|127\x1e

控制:  \x1eFLOE-KILL <token> <pid>\x1e   → END 0（自有 pid）/ END 3（未知）
       \x1eFLOE-ALIVE <token> <pid>\x1e  → END 0（自有且存活）/ END 3
```

- guest 侧 `fork`+`setsid`，stdin=`/dev/null`，stdout/stderr 以
  `O_APPEND|O_CREAT` 打开 `logPath` 后 `dup2`，再 `execvp`；**不等待进程结束**
  就回 `PID`+`END 0`。
- `logPath` 由 host 传 9p 可读路径（约定 `/floe/env/services/<job>.log`）；
  host 从同一 9p 文件读日志。runner 会尽力创建父目录。
- pid 表容量 32，只认本 runner `SPAWN` 出的 pid；`KILL`/`ALIVE` 对未知 pid
  返回 END 3 且绝不发送信号。`KILL` 先 SIGTERM，750 ms 后 SIGKILL。
- SPAWN/KILL/ALIVE 不阻塞后续 EXEC：每个 guest 仍需自己 `waitpid` 回收
  （SIGCHLD wake-up + 主循环），死掉的 pid 从表中移除，`ALIVE` 因此反映真实
  存在性。
- 一次性 `EXEC` 里 `sh -c 'daemon &'` 的后台进程会在命令 END 后失去输出
  管道：需要长期存活并被收集日志/端口的服务必须走 `SPAWN`。

## 4. 可选宿主桥 `floe-host archive`（协商后才可用）

Guest 内的 `floe-host archive create|extract|list|decompress` 不调用 guest
工具链，而是把有界控制消息交给宿主原生归档引擎（`FloeWorkspace.ArchiveEngine`）。
字节始终留在 9p 共享目录里，控制台只走小消息。

```
HELLO:   host → guest  \x1eFLOE-HELLO <token> archive=create,extract,list,decompress\x1e
CAPS:    guest → host  \x1eFLOE-CAPS <token> … hostArchive=create,extract,list,decompress\x1e
请求:    guest → host  \x1eFLOE-HOSTREQ <token> <base64 payload>\x1e
回复:    host → guest  \x1eFLOE-HOSTREPLY <token> <base64 reply>\x1e\n
```

- **能力先注册、后广告**：host 只有在该环境的 App 侧处理器已安装时才在
  `FLOE-HELLO` 里附带 `archive=…`；未安装时不带该字段，guest 的
  `floe-host` 命令按“未协商”显式失败（END 126），绝不出现“广告了但没人答”。
- **按环境与命令 token 绑定**：payload 是 canonical 单行
  `v1 token=… action=… format=… source=… [destination=…]`（percent 编码），
  其中的 token 必须等于发起请求的 guest 命令 token（HOSTREQ 帧头 token）。
  处理器只为该环境声明的 9p 共享目录解析 guest 路径，共享目录之外的路径在
  任何文件系统访问之前被拒绝。
- **有界与不阻塞**：payload 上限 2048 B（runner 的
  `FLOE_HOST_PAYLOAD_MAX`），回复上限 2048 B；host 侧回复上限 1024 B，
  超出时回 `status=error code=reply-too-large` 而不是截断或静默。宿主处理器
  在控制台 router 之外执行，不占用 VM/pool 槽位，guest 等待回复不会造成
  guest 自我死锁；host 侧另有 `LinuxGuestLimits.hostRequestTimeout`
  （默认 240 s，短于 runner 的 300 s `HOST_ARCHIVE_TIMEOUT_MS`）收尾。
- **取消与重启边界**：guest 命令 END/FAILED、定向中断（SIGNAL INT）、
  host 端超时、router reset（guest 重启）与通道关闭都会取消在途宿主工作；
  重启后到达的旧 token 回复会被丢弃（generation 校验），不会写入新 boot。
- **未协商/旧 guest**：旧 runner 忽略 `archive=` 参数（HELLO 的未知键被忽略），
  也没有 `floe-host` 内建命令，因此旧镜像上该能力自然不可用且失败显式；
  反过来，只有已协商动作会被 runner 放行，未广告动作在 runner 内直接 END 126。
- **`list` 不回大清单**：清单写入共享目录（`.floe-host-archive/listing-*.txt`）
  并在回复里只回该 guest 路径，回复体保持有界。

## 5. 兼容性 / Compatibility

- 旧 host（仅 inline EXEC）继续可用；guest 对两种 EXEC 都支持。
- 扩展帧对旧 guest 是不可识别行，会被丢弃并使 host 超时——host 应按可用性
  探测（例如 `ALIVE` 无响应）或按需启用，不在旧镜像上假定扩展可用。
- 帧级真链路检查（host 侧原始字节）由 host/核心任务在镜像内跑；仓库内的
  `FloeAgent/LinuxGuest/tests/host_protocol_check.sh` 已覆盖 guest 端行为
  （chunked、PTY、SPAWN/KILL/ALIVE）与 host 通道/路由。§4 的可选桥在仓库
  侧由 host 通道单元测试（`Tests/FloeExecutionTests`）与 runner 的
  `check-host-archive` 覆盖；**尚未**取得真机镜像内 `floe-host` 端到端证据，
  也未在真实设备上验证宿主引擎写共享目录时的并发表现。

## 6. 证据状态 / Evidence status

- 已实现并验证（仓库侧）：guest runner 的全部帧（`floe_exec.c` +
  `floe_host_archive.h`，`make -C FloeAgent/LinuxGuest/runner check-host-archive`）、
  host 通道/路由与可选桥接线（`LinuxGuestCommandChannelTests` 及
  `FloeExecutionTests` 的 host-channel 用例）、真实 stdio 桥回归
  （`Local/Scratch/archive-engine/guest_bridge_check.py`）。
- 未取得：云端 App 编译/签名、真机/镜像内 `floe-host` 往返、Linux GNU tar
  与设备归档的互操作、以及镜像内 host 桥的并发压力证据。这些完成前不得
  对外宣称“镜像内已闭环”。
