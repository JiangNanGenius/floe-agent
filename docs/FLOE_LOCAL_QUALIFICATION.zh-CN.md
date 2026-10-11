# Floe 本地资格验证与补充 CI

本文用于区分**实际执行过的内容**与压缩后的状态描述可能暗示的内容。Floe 的发布资格验证以本地 Xcode 27 编译、定向测试、模拟器验证、归档以及可用的签名/上传为主路径。CI 只是简短补充：每次 push/PR 增加独立的只读检查，不作为阻塞本地资格的等待门槛。CI 全绿不等于 App、UI、真机或 Apple 证据。

本文介绍工具链与环境，不针对某个具体构建。本文**不**声明当前进行中的 App、UI 流程或真实模型路径已经通过；集成 App 验收是单独且需要明确记录的步骤。

## 1. 资格状态必须分开记录

| 状态 | 能证明什么 | 不能证明什么 |
| --- | --- | --- |
| 源码已固定 | 检出对应唯一源码 SHA/标签 | 编译或行为 |
| 已编译 | 编译器接受了该 target 或整个 App（Swift 6 并发必须做对象/SIL 或完整 App 编译，仅 `-typecheck` 不够） | 测试已执行、UI 可用 |
| 模块测试已执行 | 所列用例在该源码与工具链上真实运行并有结果 | 完整 App 行为、模拟器 UI、真机行为 |
| App 已构建 | 针对该源码产出模拟器/设备产物 | UI 交互、签名、Apple 处理 |
| 模拟器 UI | 指定 iPad/iPhone 流程在已启动模拟器上执行过 | 真机质量、用户真实配置 |
| 已打包产物 | 存在 IPA/归档，并记录哈希、包标识、版本/构建号、工具链与源码 SHA | 上传、Apple 处理、可安装性 |
| Apple `VALID`/测试组 | 对应构建未过期且对目标测试组可用，并独立回读 | 某个测试员已安装 |
| 真机 | 用户在真实设备上完成验收 | 未在该设备上执行的任何内容 |

本地产物不能证明测试；测试日志不能证明 UI；上传不能证明 Apple 已处理；Apple 有效不能证明用户已安装。

## 2. 本地预检命令

在仓库根目录执行。前五条与 CI 精简通道一致；Office 宿主 pin 是打包前额外的只读预检。六条命令都可以在更重的本地工作前安全运行：

```bash
cd FloeAgent
python3 scripts/check_engineering_viewer_assets.py
scripts/pin_check.sh
python3 scripts/validate_localization_catalog.py FloeApp/Resources/Localizable.xcstrings
python3 scripts/audit_native_runtime_free.py --project
scripts/license_inventory.sh --check
python3 scripts/pin_office_host_artifact.py --check
```

说明：

- `--check` 只读。绝不能先生成再检查来让检查通过；跟踪清单过期本身就是失败。
- 存在真实 `.build/checkouts` 时，`license_inventory.sh --check` 会读取它们；checkout 版本与已提交 pin 不一致会按设计失败（fail closed）。在全新克隆（没有 `.build`）中，它复用已记录且绑定 revision 的证据，无需解析或下载即可通过。
- 通过每条命令的 `DEVELOPER_DIR` 指定已安装 Xcode，不要改动全局 `xcode-select`；先检查实际输出卷的剩余空间。

## 3. 本地编译/测试证据

- 模块与资格测试在对应模块上运行，并记录 scratch 路径与并发数（重型编译从 6 个任务开始，按实测内存压力调整）。
- 共享同一 scratch 的 SwiftPM 命令必须串行执行。
- 模拟器测试、调试或截图结束后，关闭本任务启动的模拟器；保留设备数据以及其他任务仍在使用的模拟器。

## 4. 补充 CI 的范围

CI（`.github/workflows/ci.yml`）现在分为两种形态：

| 触发方式 | 执行的通道 |
| --- | --- |
| `push` 到 `main`、`pull_request` | 仅 `lean-checks` |
| 手动触发且不带选择器 | 仅 `lean-checks` |
| 手动触发 `full: true` | 完整矩阵：`build-test`、`appstore-sdk-compatibility`、`spm-linux-build` |
| 手动触发单个专用模式 | 仅该模式 |

默认 `lean-checks`（ubuntu-latest，Python 3.13）只运行只读且独立价值明确的检查：

- 内置工程查看器资源哈希、封闭网络策略与声明文件；
- 已提交的 SwiftPM pin（不解析依赖）；
- 第三方许可证清单的 `--check` 模式；
- 本地化目录完整性；
- 工程清单中"原生 Python/Node 不得回归"审计；
- 严格诊断/结果校验契约测试（测试运行器恢复、模拟器选择器、App/Notes/IDE 结果校验器、重试分类、延迟套件覆盖、发布版本/文案检查）；
- 使用固定版本、SHA-256 校验的 gitleaks 做全历史密钥扫描。

精简通道**不会**编译 App、引导原生组件、下载字体、解析 SwiftPM/Xcode 依赖、启动模拟器、归档或恢复构建缓存。完整 `full` 矩阵仅在显式手动选择时运行，并保留全部原有步骤与严格校验；它是补充手段，发布资格仍以本地 Xcode 27 为主路径，完整矩阵从来不是发布等待门槛。

### 运行完整手动矩阵

```bash
gh workflow run ci.yml -f full=true
# 窄范围重跑保持原有语义：
gh workflow run ci.yml -f build_test_only=true
gh workflow run ci.yml -f ide_only=true
```

一次手动触发最多只能选择一个顶层模式。新的 `validate-selectors` 作业会在每个手动触发的最前面运行，在付费演示、可写 Skill Hub 发布或任何重型通道启动之前拒绝冲突组合（例如 `full` 与 `ide_only` 同时选择、同时选择两个专用模式、或 `palette_*` 修饰符缺少 `feedback_ui`）。push/PR 与不带选择器的手动触发不会触及这些通道。

如果发布步骤希望复用某个源码 SHA 的 CI 产物，需要该 SHA 上存在一次成功的显式 `full` 运行；否则发布工作流会回退到本地编译/测试路径，这正是主路径。

## 5. CI 仍然无法证明的内容

- 精简通道不编译源码，无法发现编译或并发错误；本地对象/App 编译可以。
- 它不运行模拟器或真机 UI 流程。
- 它不验证签名、Apple 处理、TestFlight 测试组或可安装性。
- 精简通道失败是所选契约的真实失败；精简通道通过不得报告为"App 已通过"。

如有疑问，请报告精确状态：源码 SHA、工具链、命令、target、实际结果、保留证据与限制。
