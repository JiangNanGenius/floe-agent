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

## 真机限制 / Device limits

- v3 真机报告确认 Node 18.20.4/npm 10.9.2、Python 3.13.5、Lua 5.4.8、Ruby 3.4.1、PHP 8.2.33 真实执行通过；
  设置页版本与上述来源一致，无硬编码可用状态。
- 新增 7 个基础命令的实现逻辑在本机编译并断言通过，但尚未在真机 shell 内逐条敲命令复验；
  `id` 的用户名解析在沙盒拒绝目录查询时只输出数字（不虚构名称）。
- pending WASI 产物（uutils、sqlite3 shell、ripgrep）仍不可安装；签名目录当前仅
  floe/lua、floe/ruby、floe/php、floe/wasm-text 四个真实可安装产物。
