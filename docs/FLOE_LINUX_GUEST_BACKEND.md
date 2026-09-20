# Floe Linux 环境后端（TinyEMU RV64）/ Floe Linux Environment Backend

日期 / Dated: 2026-09-20 · 状态 / Status: 源码已接线并通过轻量校验（C 目标编译 + 20 项行为检查 + 测试文件类型检查）；
guest 执行端已实现（`FloeAgent/LinuxGuest/`，含跨 chunk 输出丢字节的 host parser 修复与 13 项/66 个原生真链路断言）；
主 App 完整编译、Cloud CI 镜像注入/交叉编译与合格 guest 镜像仍待执行。无合格镜像前，Linux 启动会诚实失败，不回落 2018 demo。
/Source wired and lightly verified (C target build + 20 behavioral checks + test typecheck); the guest runner is now
implemented (`FloeAgent/LinuxGuest/`, plus a host parser fix for output lost across console chunks, verified by 66
native real-stdio assertions); the full App build, Cloud CI image injection/cross build and a qualified guest image
remain. Without a qualified image, Linux start fails honestly and never falls back to the 2018 demo.

## 1. 接线范围 / What is wired

| 层 / Layer | 位置 / Location | 说明 / Notes |
|---|---|---|
| 环境运行类型 | `FloeEnvironments/ContainerRecord.swift` | `runtime: posix(默认) \| linux`，可选字段；旧记录缺省即 native，编码不再写回 `runtime` |
| 环境注册表 | `FloeEnvironments/EnvironmentRegistry.swift` | `setRuntime(id:runtime:)`；`ensureProjectContainer/ensureSessionContainer` 可显式传 runtime，会话继承项目 |
| 后端协议 | `FloeExecution/Linux/LinuxGuestService.swift` | 描述符、镜像清单、限制、错误、`ownsLinuxEnvironment` 语义（停止中仍为 true） |
| 控制台通道 | `FloeExecution/Linux/LinuxGuestCommandChannel.swift` | 分帧协议、逐段限流、超时/取消 → Ctrl-C + 毒化并停止 guest |
| guest 运行时 | `FloeExecution/Linux/TinyEMUGuestRuntime.swift` | 单线程 `floe_vm_run_slice`、9p shares、`floe_vm_hostfwd_add/remove`、可恢复创建失败 |
| 注册表/服务 | `FloeExecution/Linux/LinuxGuestRegistry.swift` | 每环境一个 guest、全进程同时只运行一个 guest（slirp 单例）、start/stop/delete、task 所有权、转发上限 16 |
| shell 路由 | `FloeExecution/Linux/LinuxGuestShellBackend.swift` + `FloeApp/Execution/LinuxGuestBackend.swift` | `exec.shell` 在 Linux 环境交 guest `/bin/sh -c` 原样执行；其它环境保持 ios_system；交互式 guest 终端未接线（诚实报错） |
| 注入 | `FloeApp/App/AppEnvironment.swift` | 构建唯一 `TinyEMULinuxCommandService`，经现有 `FloePlatformServices.setLinuxCommandService` 注入；无 `runtime .linux` 时零行为变化 |
| 生命周期 | `FloePlatformServices.resumeEnvironment/stopEnvironment` + `ContainerLifecycle.Hooks` | 启动环境 → 启动 guest（失败回滚为 stopped 并抛出真实原因）；停止/删除 → 停止 guest；`terminateWorkers` 校验 guest 已退出 |
| apt/dpkg 入口 | 包 UI worker 的 `LinuxCommandService.swift`（协议，未改） | `registerLinuxPackageCommands` 经 `LinuxShellCommandRouter` 把 argv 原样送入本后端；owned 未运行时禁止宿主层回写 |
| guest 执行端 | `FloeAgent/LinuxGuest/`（runner/、image/、tests/） | 静态 C runner：inline/分块 EXEC、PTY 会话、SPAWN/KILL/ALIVE、取消/回收；启动挂载脚本与镜像注入脚本；镜像注入与交叉编译待资格 CI |

共享 guest / Shared guest: `TinyEMULinuxGuestRegistry` 是每个 `runtime == .linux` 环境 guest 的唯一所有者
（一个环境一个 guest，命令在通道内串行）。当前已接消费方：`exec.shell` 与 apt/dpkg/包 UI；guest 内
localService 守护进程将复用同一会话与 hostfwd（其消费方尚未接线）。`exec.localPython` 等显式原生工具
**按设计不静默重路由**；Linux shell 内的 `python3`/`node` 是 guest 程序。

9p 共享 / 9p shares：环境写层挂 `floe-env`，工作区挂 `workspace`（最多 4 个，engine `FLOE_VM_MAX_SHARES`）。
服务转发 / service forwarding：`floe_vm_hostfwd_add/remove`（adapter `aeccdf1b`），IPv4 主机字节序，
guest 地址 0 = DHCP 10.0.2.15，表上限 16，仅 `networkEnabled` 的 guest 可用。

## 2. 诚实状态：guest 镜像未合格 / Honest status: no qualified guest image

- 本仓库**不随包提供任何 guest 镜像**；镜像清单从 App 数据目录 `LinuxGuest/images/<id>/manifest.json`
  读取，`qualified` 必须为 true 且 BIOS/kernel/initrd/disk 路径都存在，否则 `startGuest` 抛
  `imageNotQualified`（附原因）。绝不使用 2018 demo 冒充完整 Linux。
- 现有证据（核心 job 整理，2026-09-20）：Debian 13（kernel 6.12）配 2018 bbl **无控制台输出**；
  4.15 回退内核 + Debian13 userland 因 2018 demo 内核无 EFI/GPT 解析而 panic（GPT 盘只被
  protective MBR 看到，`root=/dev/vda1` VFS 失败）；整盘 ext4（无分区表，`root=/dev/vda`）重跑尚未出结果。
- 因此：Linux 后端只在环境显式选择 `runtime == .linux` 后启用，**默认不启用**；工具发现与界面
  不得宣称 Linux/apt 可用；有硬阻塞时报告 unavailable。

## 3. 未接线 / Not yet wired

- 交互式 guest 终端（`shell.*` 会话）：guest runner 已实现 `FLOE-OPEN`/`FLOE-IN`/
  `FLOE-SIGNAL`/`FLOE-CLOSE`（见
  [协议扩展](FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md)），但 host 侧会话 API 尚未接线，
  `LinuxGuestShellBackend.openSession` 仍诚实报 `consoleUnavailable`；`exec.shell`
  一次性命令可用。
- guest runner 的镜像注入（`/usr/local/bin/floe-exec`，cmdline
  `init=/usr/local/bin/floe-exec`）与 riscv64 交叉编译由核心资格 CI 执行；
  本仓库只提交源码、构建与注入脚本及 host 侧真链路检查。
- 完整 App 编译与真机/模拟器验收由云端与主代理执行；本文件不声称设备结果。

## 4. Guest 镜像契约 / Guest image contract

镜像清单 `manifest.json`（`LinuxGuestImage`）：

```json
{
  "id": "floe-linux-base",
  "biosPath": "…/bbl64.bin",
  "kernelPath": "…/vmlinux",
  "initrdPath": null,
  "diskPath": "…/rootfs.ext4",
  "diskReadWrite": true,
  "cmdline": "console=hvc0 root=/dev/vda rw",
  "qualified": true,
  "qualificationEvidence": "run <id> <date>: console + apt/dpkg + reboot"
}
```

guest 控制台 runner 协议（行 = `\x1eFLOE-…\x1e` 分帧，串口上 `E` 为回显需关闭或由解析器丢弃）：

1. 读入 `\x1eFLOE-EXEC <token> <base64>\n`（小信封）或
   `\x1eFLOE-EXEC <token> <payloadBytes> <chunkCount>\x1e\n` +
   `\x1eFLOE-CHUNK <token> <index> <base64>\x1e\n` ×N + `\x1eFLOE-RUN <token>\x1e\n`
   （大信封，单块 ≤3000 base64 字符）；payload = u32 字段数，随后每字段 u32 长度 + 原始字节，
   顺序为 `[cwd, stdin, argv0, argv1, …]`。
2. 输出 `\x1eFLOE-BEGIN <token>\x1e`，用 `\x1eFLOE-OUT <token>\x1e` / `\x1eFLOE-ERR <token>\x1e`
   分段 stdout/stderr（argv 必须原样 exec，不经 shell 重解析）。
3. 以 `\x1eFLOE-END <token> <exit>\x1e` 结束；收到 Ctrl-C（0x03）时只杀当前命令进程组并返回 130。
4. runner 必须先把 9p 挂载点准备好（或由 init 脚本挂载），并在启动后即进入读循环；
   命令之间不得输出未分帧文本。
5. 镜像 cmdline：`console=hvc0 root=/dev/vda rw init=/usr/local/bin/floe-exec`
   （runner 作为 PID 1 自挂载 proc/sys/devtmpfs/devpts/tmp 与存在的 9p tag；
   init= 不能带参数，故不做 `/bin/bash` 兜底——bash 会抢控制台输入并吃掉 FLOE-EXEC 帧）。
6. PTY 会话与后台服务帧见 [协议扩展](FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md)；
   字段布局、分块与取消语义以该文为准。

## 5. 验证 / Verification

- `bash FloeAgent/ThirdParty/TinyEMU/vendor_swift_sources.sh [pristine]` + `--check`：pristine + 0001–0004
  补丁 + `floe_slirp_` 重命名一致（含 `iomem.c`/`riscv_machine.c` 的 0002 顺序）。
- `swift build --target FloeTinyEMU`（FloeAgent）：通过；`nm` 确认 `floe_vm_hostfwd_add/remove` 符号存在。
- 轻量行为检查（CommandLineTools，XCTest 不可用时的 scratch runner，与
  `FloeAgent/Tests/FloeExecutionTests/LinuxGuestBackendTests.swift` 同场景）：20/20 通过 —— 分帧/分段/
  截断、超时毒化 + Ctrl-C、取消、owns/supports、未合格镜像拒绝、启动/运行/按 task 停止、
  单 guest 限制、未启动报 notRunning、shell 路由诚实失败。
- `LinuxGuestBackendTests.swift` 以 XCTest 桩模块类型检查通过；真实 XCTest 运行留给云端 CI。
- guest 执行端：`bash FloeAgent/LinuxGuest/tests/host_protocol_check.sh` 在 macOS 原生编译 runner，
  并抽取仓库真实 `LinuxGuestFraming` 驱动真实子进程；13 项检查 / 66 个断言全部通过（inline 与分块
  EXEC 的 argv/stdin/cwd/stdout/stderr/exit、0x1e 与二进制输出、Ctrl-C 进程组取消与 SIGKILL 升级、
  多次复用不挂死、PTY 输入/WINCH/CLOSE、SPAWN/PID/日志/ALIVE/KILL）。该检查抓出并修复了 host
  parser 跨 chunk 丢输出（commit 见 git log `fix(execution): stream guest output across console chunks
  without loss`）。riscv64 静态交叉编译与镜像内启动由核心资格 CI 验证，尚未执行。
- 该 runner 检查不启动 TinyEMU、不下载镜像、不构成镜像资格证据。
