# Floe Linux 环境后端（TinyEMU RV64）/ Floe Linux Environment Backend

日期 / Dated: 2026-09-20 · 状态 / Status: host 消费侧已接线并通过轻量真链路检查（见 §5）；
完整 App 编译与合格 guest 镜像仍待云端执行。无合格镜像时 Linux 启动诚实失败，不回落 2018 demo。
/Source wired and lightly verified (host consumers + real-stdio guest runner checks, §5); the full App build and a
qualified guest image remain. Without a qualified image, Linux start fails honestly and never falls back to the 2018 demo.

## 1. 接线范围 / What is wired

| 层 / Layer | 位置 / Location | 说明 / Notes |
|---|---|---|
| 环境执行后端 | `FloeEnvironments/ContainerRecord.swift` | `executionBackend: native(默认) \| linuxVM` 可选字段；旧记录缺省即 native |
| 环境注册表 | `FloeEnvironments/EnvironmentRegistry.swift` | `setExecutionBackend(id:backend:)`；会话/项目可显式传 backend |
| 后端协议 | `FloeExecution/Linux/LinuxGuestService.swift` | 描述符、镜像清单、限制、错误、`ownsLinuxEnvironment`（停止中仍为 true）、`LinuxGuestPathMap` |
| 控制台通道 | `FloeExecution/Linux/LinuxGuestCommandChannel.swift` | EXEC 小载荷 inline / 大载荷分块、逐段限流、超时/取消 → Ctrl-C + 毒化；单一长驻 console reader（连续命令共用，见 §5 修复） |
| 后台服务协议 | 同上 | `SPAWN` 分块 envelope → `PID`+END，`KILL`/`ALIVE` 仅认 guest 自建 pid；`ControlParser` 解析 `FLOE-PID <token> <pid>` |
| guest 运行时 | `FloeExecution/Linux/TinyEMUGuestRuntime.swift` | 单线程 `floe_vm_run_slice`、9p shares、`floe_vm_hostfwd_add/remove`、可恢复创建失败；cmdline 缺省补 `init=/usr/local/bin/floe-exec` |
| 注册表/服务 | `FloeExecution/Linux/LinuxGuestRegistry.swift` | 每环境一个 guest、全进程同时一个 guest（slirp 单例）、start/stop/delete、task 所有权、转发上限 16、`LinuxGuestLocalServiceHosting` |
| localService | `FloeExecution/Linux/LinuxGuestLocalService.swift` | `exec.localService` 在 guest 内 detach 运行：`env PORT=… <venv python|node> entry`、日志写环境层 `services/<job>.log`（9p 同文件读取，有界 tail + 脱敏）、hostfwd 发布端口、snapshot/stop |
| shell 路由 | `FloeExecution/Linux/LinuxGuestShellBackend.swift` + `FloeApp/Execution/LinuxGuestBackend.swift` | `exec.shell` 在 Linux 环境交 guest `/bin/sh -c` 原样执行；`shell.*` 交互会话走 guest PTY（`FLOE-OPEN/IN/SIGNAL/CLOSE`）；命令前缀仅做受保护的 venv 激活 |
| localPython 路由 | `FloeApp/Execution/CPythonLocalRuntime.swift` | Linux 环境里 `exec.localPython`、pip 命令、托管安装器与包 UI 都执行该 guest 的**同一个 venv**（`/floe/env/python/venv`，`--system-site-packages`），host 路径经 9p 映射；非 Linux 环境仍走内置 CPython，`ArchiveCompressedBridge` 等 host 内部调用不变 |
| 共享解释器 | `FloeExecution/Linux/LinuxGuestPythonEnvironment.swift` | Debian PEP 668 下不在系统解释器安装：首次按需 `apt-get install python3 python3-venv python3-pip` → `python3 -m venv`；半成品 venv 用 venv 内 `ensurepip` 修复；per-environment in-flight 合并，stop/delete/换后端即失效缓存 |
| 镜像校验/导入 | `FloeExecution/Linux/LinuxGuestImageStore.swift` | 镜像必须在镜像目录内、非符号链接、大小与 SHA-512 与 `artifacts` 一致且清单记录资格 run；zip 导入拒绝 `..`/绝对路径/符号链接/超限；只在全部通过后原子替换 |
| 镜像入口 | `FloeApp/Execution/FloePlatformServices.swift` + `FloeApp/Execution/LinuxGuestImageDownloader.swift` | `floe-env image status\|import\|install\|remove`；`install` 只下载本 build 固定（pinned）archive，当前 catalog 为空 → 诚实不可用；HTTPS→HTTPS 有界重定向，字节仍强校验 |
| 环境 UI | `FloeApp/Settings/EnvironmentManagerView.swift` | 环境详情提供 native/Linux 后端选择、真实 guest 状态（运行/停止/启动时间/镜像+资格原因），不依赖手输 `floe-env` |
| 注入 | `FloeApp/App/AppEnvironment.swift` | 构建唯一 `TinyEMULinuxCommandService` 与 `LinuxGuestImageInstallationService`，经 `setLinuxCommandService` / `setLinuxImageService` 注入；非 `executionBackend == .linuxVM` 时零行为变化 |

共享 guest / Shared guest: `TinyEMULinuxGuestRegistry` 是每个 `executionBackend == .linuxVM` 环境 guest 的唯一所有者
（一个环境一个 guest，命令在通道内串行）。同一 guest 同时服务 `exec.shell`、apt/dpkg 与包 UI、`exec.localPython`（共享
venv）、`exec.localService` 与 `shell.*` PTY 会话。

9p 共享 / 9p shares：环境写层挂 `floe-env` → `/floe/env`，工作区挂 `workspace` → `/workspace`（最多 4 个）。
guest runner（`FloeAgent/LinuxGuest/`）在启动时挂载这些 tag；host 的 cwd/entry/log/Python target 全部经
`LinuxGuestPathMap` 映射，越出共享的路径直接报配置错误，不静默回落。
服务转发 / service forwarding：`floe_vm_hostfwd_add/remove`（adapter `aeccdf1b`），IPv4 主机字节序，
guest 地址 0 = DHCP 10.0.2.15，表上限 16，仅 `networkEnabled` 的 guest 可用。

## 2. 诚实状态：guest 镜像未合格 / Honest status: no qualified guest image

- 本仓库**不随包提供任何 guest 镜像**。镜像清单从 App 数据目录 `LinuxGuest/images/<id>/manifest.json`
  读取；`qualified: true` 本身**不可信**：清单还必须带 `qualificationRun` 与每个 artifact 的 `sha512`/`bytes`，
  host 在启动前重新哈希实际字节；不一致、缺失或路径越出镜像目录都报 `imageNotQualified`（附原因）。
- 可运行证据（核心 worker，2026-09-20，run 35497742193）：Debian 13 riscv64 用户态在 2018 demo 的 4.15 内核上
  真实启动，bash/glibc/python3 3.13.5/dpkg/9p/fork/管道/信号/pty 实测通过，断电重启后文件持久化。
  规格：`bbl64.bin` + 4.15 `kernel-riscv64.bin` + Debian13 rootfs 整盘 ext4，`root=/dev/vda`（2018 内核无 GPT 解析，
  不能 `root=/dev/vda1`），RAM 512–768MB，`console=hvc0 root=/dev/vda rw init=/usr/local/bin/floe-exec`。
- 后续定向云端结果（run 35500083112）：修正 FENCE.TSO 处理并设置 guest 时钟后，默认 HTTPS 源的
  apt update/install 返回 0，NumPy 2.2.4、Node v20.19.2 与 Python HTTPS 200 均有真实输出。
  独立指令探针因脚本缩进错误未产出结果，修正后由最终镜像检查补验。App 启动时钟与安装归属仍在收口。
- 现代 Debian13 6.12 内核在 2018 bbl 上仍无控制台输出（需 FDT+OpenSBI）；当前可用组合限于 4.15 内核
  与 Debian13 用户态。RAM OOM 创建失败是可恢复 NULL，不是致命错误。
- 分发是**另一个**决定：`LinuxGuestImageDistributionCatalog` 目前为空（没有已发布的 guest 来源/许可记录），
  所以 `floe-env image install` 与 UI 只报不可用；本地构建的镜像只能经
  `floe-env image import <id> <zip> <sha512>` 导入并标记为本地导入（永不自动成为可下载镜像）。
  guest 来源/许可缺口见 [guest 镜像清单](FLOE_LINUX_GUEST_IMAGE_MANIFEST.md)。
- 因此：Linux 后端只在环境显式选择 `executionBackend == .linuxVM` 后启用，**默认不启用**；工具发现与界面
  不宣称 Linux/apt 可用，有硬阻塞时报 unavailable。

## 3. 可达入口 / Reachable selection

- 设置 UI：环境详情 → “执行后端” 选择 native/Linux，显示真实状态、镜像 id 与无法启动的原因
  （`FloePlatformServices.setEnvironmentExecutionBackend(id:backend:)` + `linuxEnvironmentStatus(id:)`）。
- shell：`floe-env backend <id|owner-id> native|linux`；切到 linux 会尝试启动 guest，失败返回真实原因（exit 3，
  环境保持 linuxVM 选择，apt/dpkg 不回写宿主层）。
- 镜像：`floe-env image status|import|install|remove`（见 §1/§2）。
- 无持久 artifact 根时后端与镜像存储整体不可用（不回落临时目录），日志给出原因。

## 4. Guest 镜像契约 / Guest image contract

镜像清单 `manifest.json`（`LinuxGuestImage`）：artifact 路径**相对镜像目录**（可移植形式；绝对路径仅限本地镜像且必须
仍在镜像目录内解析）：

```json
{
  "id": "floe-linux-base",
  "biosPath": "bbl64.bin",
  "kernelPath": "kernel-riscv64.bin",
  "initrdPath": null,
  "diskPath": "rootfs.ext4",
  "diskReadWrite": true,
  "cmdline": "console=hvc0 root=/dev/vda rw",
  "qualified": true,
  "qualificationEvidence": "run 35497742193: console + apt/dpkg + python3 + reboot",
  "qualificationRun": "35497742193",
  "artifacts": [
    {"role": "bios", "path": "bbl64.bin", "sha512": "<128 hex>", "bytes": 123456},
    {"role": "kernel", "path": "kernel-riscv64.bin", "sha512": "<128 hex>", "bytes": 123456},
    {"role": "disk", "path": "rootfs.ext4", "sha512": "<128 hex>", "bytes": 12345678}
  ],
  "provenance": {
    "sourceURL": "https://…/guest-image-sources",
    "buildConfigurationURL": "https://…/guest-image-sources/build.md",
    "license": "GPL-2.0-or-later (guest userland) · BSD-3 (bbl)",
    "distributionAllowed": false
  }
}
```

校验顺序：清单结构（qualified + run id + 完整 digest 列表）→ 路径解析在 `<root>/<id>` 内且非符号链接 →
文件大小 → SHA-512 实际哈希 → 才允许创建 VM。`effectiveCmdline` 在清单未写 `init=` 时补
`init=/usr/local/bin/floe-exec`，保证有资格镜像一定进入 FLOE-EXEC 通道。

guest 控制台 runner 协议（行首 `\x1e`，末尾接受 `\n` 或闭合 `\x1e`）：

1. 命令载荷：inline `\x1eFLOE-EXEC <token> <base64>\n`（小信封）或分块
   `\x1eFLOE-EXEC <token> <payloadBytes> <chunkCount>\x1e\n` + `\x1eFLOE-CHUNK <token> <index> <b64>\x1e\n` ×N +
   `\x1eFLOE-RUN <token>\x1e\n`；payload = u32 字段数，随后每字段 u32 长度 + 原始字节，
   顺序为 `[cwd, stdin, argv0, argv1, …]`。
2. 输出 `\x1eFLOE-BEGIN <token>\x1e`，用 `\x1eFLOE-OUT <token>\x1e` / `\x1eFLOE-ERR <token>\x1e`
   分段 stdout/stderr（argv 原样 exec，不经 shell 重解析）。
3. 以 `\x1eFLOE-END <token> <exit>\x1e` 结束；Ctrl-C（0x03）只杀当前命令进程组并返回 130。
4. 交互会话：OPEN（payload 首字段 `pty`，随后 cwd/cols/rows/argv…）分块 envelope；host 输入
   `\x1eFLOE-IN <token> <b64>\x1e`，信号 `\x1eFLOE-SIGNAL <token> INT|TERM|WINCH <rows> <cols>\x1e`，
   关闭 `\x1eFLOE-CLOSE <token>\x1e`；guest 用 `\x1eFLOE-OUT <token>\x1e` 原始流 + END。
5. 后台服务：`\x1eFLOE-SPAWN <token> <payloadBytes> <chunkCount>` + CHUNK + RUN（payload `[cwd, logPath, argv…]`）
   → `\x1eFLOE-PID <token> <pid>\x1e` + END 0（不等待进程）；`\x1eFLOE-KILL <token> <pid>\x1e` /
   `\x1eFLOE-ALIVE <token> <pid>\x1e` → END 0/3，仅认 runner 自建 pid。
6. runner 启动即挂载 9p 并进入读循环；命令之间不得输出未分帧文本。OPEN/SPAWN 固定分块（不适用 inline 快路径）。

## 5. 验证 / Verification

- `bash FloeAgent/ThirdParty/TinyEMU/vendor_swift_sources.sh [pristine]` + `--check`：pristine + 0001–0004 补丁一致。
- `swift build --target FloeTinyEMU` 通过；`nm` 确认 `floe_vm_hostfwd_add/remove`。
- guest runner（`FloeAgent/LinuxGuest/`，commit a9396dc0）：`tests/host_protocol_check.sh` 13 项/66 断言全过
  （inline/分块 EXEC、PTY 输入/信号/关闭、SPAWN/PID/ALIVE/KILL），驱动字节取自本文件的 `LinuxGuestFraming`。
- host 侧 scratch 行为检查（本机 CommandLineTools，archived 于 `Local/Private/floe-linux-host-checks-20260920/`）：
  34/34 通过 —— 路径映射/越界拒绝、镜像导入+digest+篡改检测+空 catalog 拒绝、supervisor spawn/env/共享 venv/
  hostfwd/日志 tail/停止，以及**真实 guest runner 进程**经 `LinuxGuestCommandChannel` 的连续 inline/chunked
  EXEC、SPAWN+日志+ALIVE+KILL、PTY 会话。
- 该检查修掉的真实缺陷：镜像校验误把平台符号链接祖先（macOS `/var`）当越界；channel 每条命令取消 reader 会终止
  AsyncStream（guest 只能服务一条命令）；`ControlParser` 的 PID marker 格式错误。修复后顺序命令与 SPAWN 均通过。
- `FloeAgent/Tests/FloeExecutionTests/LinuxGuestBackendTests.swift`（含路径映射/镜像/控制帧/supervisor/顺序命令回归）
  以 XCTest 桩类型检查通过；真实 XCTest 与完整 App 编译留给云端 CI。
- NOT run：完整 package/App 构建、真机/模拟器、riscv64 镜像资格（核心 CI：交叉编译/注入/`FLOE_RUNNER_OK`）。

## Guest runner protocol evidence

The actual C execution endpoint, build and image injection scripts live in
`FloeAgent/LinuxGuest/`. Its native host protocol harness passed 13 checks /
66 assertions using the real framing parser, including byte-exact argv, large
chunked input/output, exit status, cancellation, PTY and owned background
services. See [the frame contract](FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md).
These are native process checks, not proof of a qualified riscv64 guest image.
