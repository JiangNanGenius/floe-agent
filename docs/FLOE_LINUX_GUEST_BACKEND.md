# Floe Linux 环境后端（TinyEMU RV64）/ Floe Linux Environment Backend

日期 / Dated: 2026-09-20（Build 215 复核 2026-09-21；Build 219 增补 2026-09-22）· 状态 / Status: host 消费侧已接线并通过轻量真链路检查（见 §5）；
最终 guest 镜像已完成云端组件验证并公开分发（组件 `floe-linux-guest-20260920.1`）；TinyEMU/Linux 现为主要本地运行时，Build 219 已构建并上传。
/Source wired and lightly verified (§5). The final guest image passed cloud component qualification and is publicly
distributed (component `floe-linux-guest-20260920.1`); TinyEMU/Linux is now the primary local runtime and build 219
has been built and uploaded. Device acceptance remains with the user.

> **Build 219 增补 / Build 219 update (2026-09-22):** 所有依赖 Linux 的入口现在共用同一套自动准备流程（`activateLinuxGuestWithPreparation`），
> 设置 → 执行环境提供下载/更新/启动/停止与网络状态；客体启动时配置 eth0、默认路由、解析器与 git `safe.directory`
> 并上报 `net=up|partial|down`（云端证据 run 35652797196，`netStatus=up`、`failures=0`）；9p 对 `xattrwalk` 返回兼容结果，
> `ls -l` 不再报 524。**App 已不再内置 CPython/nodejs-mobile 等原生运行时载荷**：下表与 §4.1 中描述“内置解释器”
> 的旧文字属于该日期前的实现记录，现行非 Linux 环境只有 POSIX shell 兼容子集，语言与包统一在 Linux 客体安装；
> 见 [Build 219 版本说明](RELEASE_NOTES_1.7.0_BUILD_219.md) 与 [实施状态](FLOE_1_7_IMPLEMENTATION_STATUS.md)。
> Every Linux-required entry point now shares one automatic preparation flow; Settings → Execution Environments exposes
> download/update/start/stop plus the guest network state; the guest configures and reports its own network
> (`net=up|partial|down`, cloud evidence run 35652797196), and 9p answers `xattrwalk` so `ls -l` no longer reports 524.
> The App no longer bundles native CPython/nodejs-mobile payloads: older "bundled interpreter" text below is a record of
> the pre-Phase-2 implementation; non-Linux environments keep only the POSIX shell compatibility subset.

## 1. 接线范围 / What is wired

| 层 / Layer | 位置 / Location | 说明 / Notes |
|---|---|---|
| 环境执行后端 | `FloeEnvironments/ContainerRecord.swift` | `executionBackend: native(默认) \| linuxVM` 可选字段；旧记录缺省即 native |
| 环境注册表 | `FloeEnvironments/EnvironmentRegistry.swift` | `setExecutionBackend(id:backend:)`；会话/项目可显式传 backend |
| 后端协议 | `FloeExecution/Linux/LinuxGuestService.swift` | 描述符、镜像清单、限制、错误、`ownsLinuxEnvironment`（停止中仍为 true）、`LinuxGuestPathMap` |
| 控制台通道 | `FloeExecution/Linux/LinuxGuestCommandChannel.swift` | EXEC 小载荷 inline / 大载荷分块、逐段限流、超时/取消 → Ctrl-C + 毒化；单一长驻 console reader（连续命令共用，见 §5 修复） |
| 后台服务协议 | 同上 | `SPAWN` 分块 envelope → `PID`+END，`KILL`/`ALIVE` 仅认 guest 自建 pid；`ControlParser` 解析 `FLOE-PID <token> <pid>` |
| guest 运行时 | `FloeExecution/Linux/TinyEMUGuestRuntime.swift` | 单线程 `floe_vm_run_slice`、9p shares、`floe_vm_hostfwd_add/remove`、可恢复创建失败；cmdline 缺省补 `init=/usr/local/bin/floe-exec` |
| 注册表/服务 | `FloeExecution/Linux/LinuxGuestRegistry.swift` | 每环境一个 guest；**无全局执行锁**——引擎补丁 0006 起 slirp 为每 VM 实例，不同环境的 guest 可并行运行，各自可停止/超时/取消/回收，卡死只隔离自身（`quarantinedEnvironments`）；准入由 `guestReservations` 限量（默认 ≤4 guest、≤1536 MB）、start/stop/delete、task 所有权、转发上限 16、`LinuxGuestLocalServiceHosting` |
| localService | `FloeExecution/Linux/LinuxGuestLocalService.swift` | `exec.localService` 在 guest 内 detach 运行：`env PORT=… <venv python|node> entry`、日志写环境层 `services/<job>.log`（9p 同文件读取，有界 tail + 脱敏）、hostfwd 发布端口、snapshot/stop |
| shell 路由 | `FloeExecution/Linux/LinuxGuestShellBackend.swift` + `FloeApp/Execution/LinuxGuestBackend.swift` | `exec.shell` 在 Linux 环境交 guest `/bin/sh -c` 原样执行；`shell.*` 交互会话走 guest PTY（`FLOE-OPEN/IN/SIGNAL/CLOSE`）；命令前缀仅做受保护的 venv 激活 |
| localPython 路由 | `FloeApp/Execution/CPythonLocalRuntime.swift` | Linux 环境里 `exec.localPython`、pip 命令、托管安装器与包 UI 都执行该 guest 的**同一个 venv**（`/floe/env/python/venv`，`--system-site-packages`），host 路径经 9p 映射；非 Linux 环境只有 POSIX shell 兼容子集（Phase 2 后 App 不再内置 CPython），`ArchiveCompressedBridge` 等 host 内部调用不变 |
| Python 包归属 | `FloeExecution/Linux/LinuxGuestLanguagePackages.swift` | Linux 环境用 guest venv 的真实 `python3 -m pip`（用户源配置、guest 缓存，不套 iOS 纯 Python wheel 限制、不用 host staging）；`exec.localPython`/`python.packages`/pip 命令/包 UI 读回同一 venv；停止时诚实报错，不回退 host |
| Node 包归属 | 同上 + `FloeExecution/Linux/LinuxGuestNodeEnvironment.swift` | guest 自己的 npm/pnpm 在 `/floe/env/var/floe-node-transaction` 暂存并原子替换 `<layer>/usr/lib/node_modules`；保留安装脚本、bin 链接与 riscv64 原生扩展；顶层 CLI 链接到 `<layer>/usr/bin`（guest PATH） |
| 共享解释器 | `FloeExecution/Linux/LinuxGuestPythonEnvironment.swift` | Debian PEP 668 下不在系统解释器安装：首次按需 `apt-get install python3 python3-venv python3-pip` → `python3 -m venv`；半成品 venv 用 venv 内 `ensurepip` 修复；per-environment in-flight 合并，stop/delete/换后端即失效缓存，forget 后旧任务不会回填 |
| Node 运行时 | `FloeExecution/Linux/LinuxGuestNodeEnvironment.swift` | guest 内探测 node/npm（缺失才 `apt-get install nodejs npm`）；pnpm 只探测、绝不隐式安装；per-environment 缓存与失效规则同 Python |
| 镜像校验/导入 | `FloeExecution/Linux/LinuxGuestImageStore.swift` | 镜像必须在镜像目录内、非符号链接、大小与 SHA-512 与 `artifacts` 一致且清单记录资格 run；zip 导入拒绝 `..`/绝对路径/符号链接/超限；只在全部通过后原子替换 |
| 镜像入口 | `FloeApp/Execution/FloePlatformServices.swift` + `FloeApp/Execution/LinuxGuestImageDownloader.swift` | `floe-env image status\|import\|install\|remove`；`install` 只下载本 build 固定（pinned）archive，catalog 固定组件版本及 SHA-512；HTTPS→HTTPS 有界重定向，字节仍强校验 |
| 环境 UI | `FloeApp/Settings/EnvironmentManagerView.swift` | 环境详情提供 native/Linux 后端选择、真实 guest 状态（运行/停止/启动时间/镜像+资格原因），不依赖手输 `floe-env` |
| 注入 | `FloeApp/App/AppEnvironment.swift` | 构建唯一 `TinyEMULinuxCommandService` 与 `LinuxGuestImageInstallationService`，经 `setLinuxCommandService` / `setLinuxImageService` 注入；非 `executionBackend == .linuxVM` 时零行为变化 |

共享 guest / Shared guest: `TinyEMULinuxGuestRegistry` 是每个 `executionBackend == .linuxVM` 环境 guest 的唯一所有者
（一个环境一个 guest，命令在通道内串行；不同环境的 guest 互不阻塞、可并行）。同一 guest 同时服务 `exec.shell`、
apt/dpkg 与包 UI、`exec.localPython`（共享 venv）、`exec.localService` 与 `shell.*` PTY 会话。

9p 共享 / 9p shares：环境写层挂 `floe-env` → `/floe/env`，工作区挂 `workspace` → `/workspace`（最多 4 个）。
guest runner（`FloeAgent/LinuxGuest/`）在启动时挂载这些 tag；host 的 cwd/entry/log/Python target 全部经
`LinuxGuestPathMap` 映射，越出共享的路径直接报配置错误，不静默回落。
服务转发 / service forwarding：`floe_vm_hostfwd_add/remove`（adapter `aeccdf1b`），IPv4 主机字节序，
guest 地址 0 = DHCP 10.0.2.15，表上限 16，仅 `networkEnabled` 的 guest 可用。

## 2. 镜像验证与分发状态 / Image qualification and distribution

- 本仓库**不随包提供任何 guest 镜像**。镜像清单从 App 数据目录 `LinuxGuest/images/<id>/manifest.json`
  读取；`qualified: true` 本身**不可信**：清单还必须带 `qualificationRun` 与每个 artifact 的 `sha512`/`bytes`，
  host 在启动前重新哈希实际字节；不一致、缺失或路径越出镜像目录都报 `imageNotQualified`（附原因）。
- 可运行证据（核心 worker，2026-09-20，run 35497742193）：Debian 13 riscv64 用户态在 2018 demo 的 4.15 内核上
  真实启动，bash/glibc/python3 3.13.5/dpkg/9p/fork/管道/信号/pty 实测通过，断电重启后文件持久化。
  规格：`bbl64.bin` + 4.15 `kernel-riscv64.bin` + Debian13 rootfs 整盘 ext4，`root=/dev/vda`（2018 内核无 GPT 解析，
  不能 `root=/dev/vda1`），RAM 512–768MB，`console=hvc0 root=/dev/vda rw init=/usr/local/bin/floe-exec`。
- 后续定向云端结果（run 35500083112）：修正 FENCE.TSO 处理并设置 guest 时钟后，默认 HTTPS 源的
  apt update/install 返回 0，NumPy 2.2.4、Node v20.19.2 与 Python HTTPS 200 均有真实输出。
  最终镜像 run 35501535251 已通过两次真实启动、PID1 floe.epoch 时钟、HTTPS APT/Python、
  11 项命令操作与 6 项 FENCE 指令检查；SSH 仅验证版本，SCP 仅验证失败连接，尚无实际传输验收。
  App 启动时钟及 Python/Node 安装归属修复已接线，完整 App 编译及 iPad 验收另行记录。
- 现代 Debian13 6.12 内核在 2018 bbl 上仍无控制台输出（需 FDT+OpenSBI）；当前可用组合限于 4.15 内核
  与 Debian13 用户态。RAM OOM 创建失败是可恢复 NULL，不是致命错误。
- `LinuxGuestImageDistributionCatalog` 固定组件 `floe-linux-guest-20260920.1` 的镜像 URL 与 SHA-512。
  镜像、对应源码与版权材料已于 2026-09-20 10:37:28 UTC 在该组件发布页公开；
  公开镜像 URL 返回 HTTP 200，大小 572643214 字节，源码说明可直接读取。
  本地构建的镜像可经
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
- 无持久 artifact 根时镜像存储不可用，Linux 环境归属仍然保留并报出缺失原因；不会改在原生解释器执行。

## 4. Guest 镜像契约 / Guest image contract

镜像清单 `manifest.json`（`LinuxGuestImage`）：artifact 路径**相对镜像目录**（可移植形式；绝对路径仅限本地镜像且必须
仍在镜像目录内解析）：

```json
{
  "id": "floe-debian13-riscv64-202609202607",
  "biosPath": "bbl64.bin",
  "kernelPath": "kernel-riscv64.bin",
  "initrdPath": null,
  "diskPath": "disk.img",
  "diskReadWrite": true,
  "cmdline": "console=hvc0 root=/dev/vda rw",
  "qualified": true,
  "qualificationEvidence": "run 35501535251: two boots, HTTPS APT/Python and instruction checks",
  "qualificationRun": "35501535251",
  "artifacts": [
    {"role": "bios", "path": "bbl64.bin", "sha512": "<128 hex>", "bytes": 123456},
    {"role": "kernel", "path": "kernel-riscv64.bin", "sha512": "<128 hex>", "bytes": 123456},
    {"role": "disk", "path": "disk.img", "sha512": "<128 hex>", "bytes": 12345678}
  ],
  "provenance": {
    "sourceURL": "https://…/guest-image-sources",
    "buildConfigurationURL": "https://…/guest-image-sources/build.md",
    "license": "GPL-2.0 kernel; BSD-3-Clause bbl; MPL-2.0 runner; LGPL-2.1 glibc; per-package Debian licenses",
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

## 4.1 Linux 语言包归属（Python/Node）/ Language package ownership

`executionBackend == .linuxVM` 的环境，其 Python/Node 包状态完全属于 guest。本节写于 Phase 2 迁移之前，其中的
“原生 iOS 路径（内置 CPython 的纯 Python wheel 事务、nodejs-mobile 托管安装）”描述的是当时的 non-Linux 实现，
现已随原生载荷一起退役；非 Linux 环境不提供 Python 运行时，语言包统一在 Linux 客体安装。

- Python：唯一安装是共享 venv（guest `/floe/env/python/venv`，host `<layer>/python/venv`）。安装/卸载/查询/列表
  在 guest 内执行真实 `venv/bin/python3 -m pip`（`PIP_INDEX_URL` 取环境自身 `var/language-package-sources.json`，
  `PIP_CACHE_DIR=<layer>/var/pip-cache`）：不套 iOS 的 `--only-binary/--platform any/--abi none` 纯 Python wheel
  限制，不使用 host staging/transaction，riscv64 wheel 按 pip 自身规则解析；`pip install` 的生命周期由 pip 决定。
  `exec.localPython`（含其 `packages`）、`exec.shell` 的 `packages`、`python.packages` 与包 UI 都读回同一个
  venv（`importlib.metadata`：venv 条目可写，`--system-site-packages` 的 guest 系统条目为继承只读）。
  `exec.localPython` 的 pip/subprocess 静态拒绝只对 non-Linux 环境生效（`ManagedPythonInstallService.isLinuxGuestEnvironment`）。
- Node：在 guest 内用 guest 自己的 npm/pnpm 安装，沿用原生托管安装的 staged/recoverable 事务语义
  （`/floe/env/var/floe-node-transaction` 暂存 → guest 内校验/写 metadata → 原子替换 `<layer>/usr/lib/node_modules`），
  但保留真实 Linux 语义：允许 lifecycle 脚本、bin 链接与 riscv64 原生扩展；安装完成后把顶层包 CLI 链接到
  `<layer>/usr/bin`（guest `/floe/env/usr/bin`，host 侧同一目录），shell/`exec.localService` 的 PATH、NODE_PATH
  由激活前缀指向该环境前缀。标准项目安装（guest 内 `npm install` 无 `-g`）仍写项目 `./node_modules`，语义不变。
- 停止/未启动的 guest：安装、卸载、列表全部返回"先启动 Linux 环境"的诚实错误，绝不回退 host 层目录或 host Node；
  `stopGuest`/删除/切换后端会同时失效 Python 与 Node 按环境缓存，`forget` 之后旧 provisioning 任务不会回填缓存。
- 源/manager 配置仍保存在环境层（`var/language-package-sources.json`、`var/node-package-manager.json`），guest 与
  UI 读到同一份；manager 选择先探测 guest 实际拥有的 npm/pnpm，缺失的 pnpm 只报清楚缺失，绝不隐式安装。

镜像制作要求（供 image/source 任务对齐；本仓库不制作镜像）：guest 至少提供 `python3`（可用 `venv`/`ensurepip`，
即 `python3-venv`/`python3-pip`）、`nodejs` + `npm`、`base64`（coreutils）、可用 APT 源与 `ca-certificates`；
`pnpm` 存在即被采用。

## 5. 验证 / Verification

- `bash FloeAgent/ThirdParty/TinyEMU/vendor_swift_sources.sh [pristine]` + `--check`：pristine + 0001–0008 补丁一致
  （0005 FENCE.TSO、0006 每 VM slirp 实例、0007 9p 出口根 fd 隔离、0008 可恢复 guest 故障路径）。
- `swift build --target FloeTinyEMU` 通过；`nm` 确认 `floe_vm_hostfwd_add/remove`。
- guest runner（`FloeAgent/LinuxGuest/`，commit a9396dc0）：`tests/host_protocol_check.sh` 13 项/66 断言全过
  （inline/分块 EXEC、PTY 输入/信号/关闭、SPAWN/PID/ALIVE/KILL），驱动字节取自本文件的 `LinuxGuestFraming`。
- host 侧 scratch 行为检查（本机 CommandLineTools，日志归档于私有工作区，不随仓库分发）：
  34/34 通过 —— 路径映射/越界拒绝、镜像导入+digest+篡改检测+空 catalog 拒绝、supervisor spawn/env/共享 venv/
  hostfwd/日志 tail/停止，以及**真实 guest runner 进程**经 `LinuxGuestCommandChannel` 的连续 inline/chunked
  EXEC、SPAWN+日志+ALIVE+KILL、PTY 会话。
- 该检查修掉的真实缺陷：镜像校验误把平台符号链接祖先（macOS `/var`）当越界；channel 每条命令取消 reader 会终止
  AsyncStream（guest 只能服务一条命令）；`ControlParser` 的 PID marker 格式错误。修复后顺序命令与 SPAWN 均通过。
- `FloeAgent/Tests/FloeExecutionTests/LinuxGuestBackendTests.swift`（含路径映射/镜像/控制帧/supervisor/顺序命令回归）
  以 XCTest 桩类型检查通过；真实 XCTest 与完整 App 编译留给云端 CI。
- 语言包归属定向检查（2026-09-20，CommandLineTools，无 XCTest；日志保存在私有工作区，不随仓库分发）：`LanguageOwnershipCheck` 34/34 通过 —— guest venv
  真实 pip argv/源配置/缓存目录、无 iOS wheelhouse 参数、host 路径不进入 guest；owned-but-stopped 时 host Python
  零调用且 guest 零命令；native 环境不提供 Python（该断言是 Phase 2 前的记录）；Node 在 guest 事务目录内运行 guest npm（保留 scripts/bin 链接）、
  提交替换 `<layer>/usr/lib/node_modules` 并链接 CLI 到 `<layer>/usr/bin`、无 host Node/宿主路径；停止时拒绝
  change/inventory；forget 清空缓存。该切片以 `swift build`（Swift 6 + StrictConcurrency）对象编译通过；
  `FloeAgent/Tests/FloeExecutionTests/LinuxGuestLanguagePackageTests.swift` 为云端 CI 的 XCTest 版本。
- 本机 CommandLineTools 无 XCTest 模块，`swift test` 无法运行（记录为工具链限制，不是产品结果）；完整 App 编译由云端执行。
- NOT run：完整 package/App 构建、真机/模拟器、riscv64 镜像资格（核心 CI：交叉编译/注入/`FLOE_RUNNER_OK`）。

## Guest runner protocol evidence

The actual C execution endpoint, build and image injection scripts live in
`FloeAgent/LinuxGuest/`. Its native host protocol harness passed 13 checks /
66 assertions using the real framing parser, including byte-exact argv, large
chunked input/output, exit status, cancellation, PTY and owned background
services. See [the frame contract](FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md).
These are native process checks, not proof of a qualified riscv64 guest image.
