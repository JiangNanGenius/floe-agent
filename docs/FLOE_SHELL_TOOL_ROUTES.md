# Shell 工具路由与运行时版本展示 / Shell Tool Routes and Runtime Version Display

日期 / Dated: 2026-09-19 · 状态 / Status: 源码已实现并通过轻量校验；主 App 编译与真机复验留给冻结源码后的云端构建与测试者
/Source implemented and lightly verified; the frozen-source cloud build and device re-check remain.

## 运行时版本展示 / Runtime version display

设置 → 执行环境页不再使用三个固定占位行，而是每次加载时合并三类真实来源（`SettingsCenter.runtimeInventory`，
`FloeExecution/RuntimeInventory.swift` 只做纯合并，不发明版本）：

| 运行时 / Runtime | 版本来源 / Version source | 来源标注 / Source label |
|---|---|---|
| JavaScript (JavaScriptCore) | `JavaScriptCoreProbe`（框架可用性） | 内置 / Bundled |
| Python (CPython) | `LocalPythonCapabilityProbe`（真实探测，3.13.x） | 内置 / Bundled |
| Node.js | `IOSSystemNodeRuntime.probe()` → `FloeNodeRuntimeVersion()`（18.20.4；npm/pnpm/yarn 随包内置） | 内置 / Bundled |
| Python (remote host) | `RemotePythonProbe`（配对主机） | 远程主机 / Remote |
| floe/lua · floe/ruby · floe/php · floe/wasm-text | 已签名 WASI 目录版本 + 已验证激活回执 | 用户安装 / User |
| 环境层内 `floe-runtime*`/`floe-node*`/`floe-python*`/`floe-lua`/`floe-ruby`/`floe-php`/`floe-wasm-*` 包 | 层清单 `LayerManifest.loadChecked`（只读清单，不遍历文件） | 项目环境 / Project |

更新状态只在比较两个真实版本后出现：签名目录版本与回执版本一致为“已是最新”，不同为“可更新到 x”，
未安装但有签名产物为“可安装 x”，其余为不可用并附原因。缺失或损坏的清单/目录被跳过而不是猜测。

## 评审工具路由目录 / Reviewed tool route catalog

`capability-hub/tool-catalog.json` 与 App 内 `FloeExecution/Resources/ToolCapabilityCatalog.json` 是同一字节的
两份拷贝，`python3 capability-hub/build.py --check-tools` 强制二者一致，并把 Swift 侧
`ToolCapabilityCatalog.validate(knownCommands:signedCatalogIDs:)` 的规则在只读脚本里复验：

- `direct`：命令真实注册于本机 shell（引擎 `commandDictionary.plist` 字典 ∪ 两个 App 侧注册文件的
  `registry.register("…")` 字面量）。`id`、`cut`、`locale`、`basename`、`dirname`、`true`、`false`
  由 `FloeApp/Execution/FloeShellCoreUtilities.swift` 在本机实现（真机 v3 报告确认缺失后补齐），
  与 `sha256sum`/`sleep` 走同一 handler 契约。
- `floe-precompiled`：必须引用真实签名目录 id 才可标 available/installable；产物未签名（如 pool 中
  pending 的 uutils/sqlite3/ripgrep WASI）必须写明 `artifactGap`，不得宣称可安装。
- `remote`：只能在配对主机 PATH 上运行，永不可安装，并给出本机替代建议（如 `wget` → 内置 `curl`）。
- `unsupported`：无 Floe 路径（如原生 ELF/Mach-O 可执行文件），尝试会被拒绝并说明原因。
- `required` 名单（26 个常用命令）必须全部被条目覆盖；直接命令必须在上述真实注册集合中。

APT 仍是 Shell 下的包管理能力（`ManagedPackageTool` 描述已扩展 `route=`/`local=`/`installable=` 说明），
未新增任何 Agent Tool，ToolDiscovery 未改动。`CapabilityInstaller` 对 shellTool 的安装/移除按路由给出
真实回执或拒绝原因，direct 命令“安装”只是确认已可用，不会下载任何东西。

## 校验与证据 / Verification

只做了轻量校验（未跑完整 SwiftPM / App 构建，主编译留给冻结源码后的单次云端构建）：

```bash
python3 capability-hub/build.py --check-tools   # Tool route catalog verified: 13 direct, 2 pending, 13 remote, 1 unsupported
python3 capability-hub/build.py --check         # 已签名目录与固定清单一致
python3 -m unittest test_build                  # 35 tests OK（含 7 个新 ToolRouteCatalogTests）
swiftc -parse <全部 14 个触及的 Swift 文件>       # 全部通过
# 纯逻辑行为断言（cut/basename/dirname/locale/id，23 项）经临时最小编译全部通过
```

## Build 198 现场报告的边界复核 / Build-198 runtime-boundary audit (2026-09-19)

Build 198 的 v5 测试报告把两处宣传与真机表现的差距定性清楚，本轮按“如实描述、不夸大”原则修正文案：

- **shell 内的 `apt` 不是 Debian 系统包管理器**：`apt list` 只有 Floe 自家签名 WASI 目录项
  （`floe/lua`、`floe/ruby`、`floe/php`、`floe/wasm-text`），`var/lib/apt/lists` 为空，产物不是原生 ELF。
  没有配置 Debian 源的环境时，`apt install bash/ps/ssh/zip/sqlite3` 之类的系统工具**不存在可安装项**。
  `floe-shell` 技能文案与 `exec.shell` 工具描述已改为“Floe APT-compatible capability catalog”，
  并列出可用替代（`workspace.archive`、Python `zipfile`/`sqlite3`、`exec.localService`、`git.*`/`ssh.*` 工具）。
- **shell 内的 `git` 是引导桩**，返回 127 并指向 `git.*` 工具；`exec.shell` 描述不再把它列为内置命令。
- **`npm install` / `pnpm add` 由环境托管**：只有在绑定受管理环境的 shell 内才执行，
  安装位置与生命周期脚本归环境所有，不支持的选项或未绑定环境会给出明确拒绝原因。
- **shell.exchange 必须真的能收发**：真机报告里 `shell.exchange` 长时间 `alive=true` 但零输出。
  根因是 Floe 的 dash 顶层解析读取 App 进程 fd 0，而不是会话的 `thread_stdin`；修复落在
  `ThirdParty/DashIOS/src/input.c` 的 INIT（`basepf.fd = fileno(thread_stdin)`）。
  这条链路如何进 App（不再是“源码改了就算修了”）：
  - 发布 CI 的 release tooling bootstrap 会跑 `scripts/build_dash_ios.sh`，从**被跟踪的**
    `ThirdParty/DashIOS` 源码重新生成 git-ignored 的 `Frameworks/dash*.xcframework`；
  - 构建脚本收尾写入 `Frameworks/dash-build-manifest.json`（DashIOS 非文档文件哈希 +
    构建脚本与 FloeShellEngine 引擎 pin + 每个 dash 二进制哈希）；文档（PROVENANCE.md、
    COPYING、man 页）进不了编译/链接，改文档不会让二进制失效；release 工作流
    （release-unsigned-ipa 两个 SDK job、testflight-direct）随后用
    `scripts/tests/test_dash_framework_provenance.py` 校验，源、构建配置、引擎 pin
    与二进制任何不一致都直接失败——保证交互 stdin 修复**确实编进了**构建输入；
  - 行为侧证据：`scripts/tests/run_feedback_dash_interactive_host.sh` 用同一套真实
    DashIOS 源码在 macOS 主机上编译（桩掉 ios_system），验证 `dash -i` 通过
    thread_stdin 管道收到输入（修复前同源构建必然失败）；CI 模拟器回归里的
    `LocalShellRuntimeTests.interactiveSessionReceivesInputAndReturnsOutput` 再对
    编译进 App 的产物复验同一行为。
- **超时/取消不再拖死、也绝不并发**：超时的命令在有限宽限期内协作式停止（dash 在命令间、
  Floe 命令在循环内轮询取消标志），worker 真正退出、teardown 释放进程级 run gate 后，
  下一条命令才会进入引擎。无视取消的原生命令不会一直占着 gate 到“碰巧停掉”，而是被
  **隔离（quarantine）**：调用方带着已捕获的输出立即返回，gate 继续持有，期间新命令如实
  报 not-started（exit 75，诊断含 `quarantined=`/`quarantineOwner=`），直到旧 worker 真正
  停止、由它的 teardown 释放 gate。任何时刻进程内只有一个 ios_system 使用者。

## 真机限制 / Device limits

- v3 真机报告确认 Node 18.20.4/npm 10.9.2、Python 3.13.5、Lua 5.4.8、Ruby 3.4.1、PHP 8.2.33 真实执行通过；
  设置页版本与上述来源一致，无硬编码可用状态。
- 新增 7 个基础命令的实现逻辑在本机编译并断言通过，但尚未在真机 shell 内逐条敲命令复验；
  `id` 的用户名解析在沙盒拒绝目录查询时只输出数字（不虚构名称）。
- pending WASI 产物（uutils、sqlite3 shell、ripgrep）仍不可安装；签名目录当前仅
  floe/lua、floe/ruby、floe/php、floe/wasm-text 四个真实可安装产物。
