# Floe 1.7 构建与验收 / Build and acceptance

本说明适用于 1.7 整合分支；完整验收状态以[实施记录](FLOE_1_7_IMPLEMENTATION_STATUS.md)为准。最低系统为 iOS/iPadOS 26，数据库迁移至 v40。重型 App 构建与归档放在云端，本地仅做定向验证。正式发布不属于本轮自动动作。

## 本地准备

使用完整 Xcode，通过 `DEVELOPER_DIR` 指定安装路径，不必更改全局 `xcode-select`。先检查磁盘空间。以下命令从仓库根目录运行；Xcode 路径按本机调整。

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
bash FloeAgent/scripts/pin_node_tools.sh
bash FloeAgent/scripts/pin_node_tools.sh --check
node --test FloeAgent/scripts/tests/node_host.test.cjs
swift test --package-path FloeAgent/Qualification --scratch-path FloeAgent/.build --force-resolved-versions --jobs 2
swift build --package-path FloeAgent --target FloeExecution --force-resolved-versions --jobs 2
```

首次 pin 命令下载并校验锁定资源；`--check` 只读校验，缺失资源应失败，不重写锁文件。Qualification 为环境、软件包、媒体和后台任务迁移提供独立测试入口，避免完整 App/MLX 构建。共享 `.build` 的 SwiftPM 命令串行执行。

原生 Node 最小 App 见 [NativeNode](../FloeAgent/Qualification/NativeNode/README.md)。宿主 Node 测试通过不代表 iOS 原生桥接或真机通过。

## 工程与云端构建

`FloeAgent/project.yml` 是工程源；运行 `bash FloeAgent/scripts/gen_project.sh` 并提交匹配的 Xcode 工程。完整依赖准备由 `bootstrap_python_runtime.sh` 负责，包括 Python、shell 和锁定 Node 框架。不要把 Node/npm/pnpm/yarn 的生成目录手工展开为 Xcode 源文件条目。

推送固定提交后检查 CI 的 Linux、开发 SDK 和发布 SDK 作业。每项记录提交 SHA、Xcode/SDK、测试结果、失败日志和产物。重跑使用同一提交；代码变化后结果属于新提交。构建产物上传、签名归档、App Store Connect 处理、TestFlight 可安装分别记录。

当前发布流水线分别验证 SDK 27 源码和 Xcode 26.6（17F113）的上传构建，签名包由后者重建同一标签。`#if compiler(>=6.4)` 控制的 27 专属实现不会出现在这份上传包中，例如手记的新笔迹选择接口会走兼容选区入口。SDK 27 组件图不能用来证明 TestFlight 包含全部 27 专属能力；上传后记录中必须注明实际工具链。

## 完整验收门槛

| 范围 | 必须保留的证据 |
|---|---|
| 环境 | 两项目多会话、重启、模板/晋升、删除等待、配额及 CAS 引用 |
| 执行 | 循环、多段管道、stdin、未知命令、环境继承、取消与资源回收 |
| 软件包 | 同一发布器/客户端签名样本、篡改、依赖冲突、恢复、升级回滚、卸载归属 |
| 媒体 | 横竖屏、不同帧率/声道、长文件、后台、空间不足、取消；重读输出实际参数 |
| 模型 | 33 项评估；15 类各有真实输入、产物、真机耗时与内存 |
| 工作台 | 文件/附件入口、编辑保存重开、共享任务、取消/重试、导出播放/返回 |
| 回归 | 聊天与工具循环、Office 保存重开、中文文档、工作区、Canvas、PiP |
| 分发 | 同一固定提交的开发/发布 SDK 构建、签名上传、Apple 处理与内部测试组可见；用户安装后完成双端真机验收 |

不以“资源下载成功”“工具返回文本成功”替代真实处理证据。密钥、令牌、私人媒体及未脱敏日志不得加入证据包。

## 媒体工作台最小 App

[NativeMedia](../FloeAgent/Qualification/NativeMedia/README.md) 编译生产工作台/播放器，使用合成视频检查编辑模型保存重开和真实导出。`--model-smoke` 产出 `media-model-results.json`，与宿主媒体测试、完整 App UI 和真机结果分别记录。该测试不能证明共享队列或聊天附件已接通。

## 原生外观、容器和步骤框验证

[NativeManagement](../FloeAgent/Qualification/NativeManagement/README.md) 编译生产主题选择器、容器管理界面、思考框、工具框和连续步骤组。它使用合成环境和明确的 App 路由替身；不能替代完整 App 导航、审批执行、附件或真机验收。UI 测试实际点击主题选择、展开思考、折叠完成调用并追加运行中的调用。模块级 `EnvironmentManagementTests` 验证真实管理服务对不同项目、继承依赖和生命周期的处理。

## 当前描述文件与新链路验收

当前版本描述入口为 [RELEASE_NOTES_1.7.0.md](RELEASE_NOTES_1.7.0.md)，对应中英文 README、USER_GUIDE、变更草稿、架构、迁移恢复及 TestFlight 准备记录。历史版本文件保留，不改写为新版本说明。上传后必须补入实际固定提交、构建号、Apple 处理结果与可安装状态。

手记验收增加：回收站永久删除必须确认且检查修订；活动附件、其他文档和撤销历史不误删；多存储句柄共享读取保护，失败回收可重试。动态导图需在真实 WebKit 验证长文字、附图和分支无重叠，方向更新生效；iPhone 横屏保留阅读位置，以真实截图正文识别确认。

真机分工更新：由用户执行 iPad/iPhone 真机检查。本轮保留自动化测试、云端归档与 TestFlight 上传责任，交付时附上双端检查清单；不以自动化通过代替用户的真机检查结果。

TestFlight 就绪检查同时要求：`VALID`、未过期、现有私有内部 Floe QA 组可见，以及 `buildBetaDetail.internalBuildState == IN_BETA_TESTING`。`READY_FOR_BETA_TESTING` 继续等待分发状态更新，出口合规或异常状态明确保留。字段含义见 [Apple InternalBetaState](https://developer.apple.com/documentation/appstoreconnectapi/internalbetastate)。实际工作流状态判断通过 7 组就绪、等待、过期和合规阻塞样本检查。

### Build 156 分发恢复

Apple 校验前运行 `prepare_app_store_bundle.py`：按摘要移除 pnpm 非 iOS 资源，保留 libssh2 原有 arm64 切片并修正其最低版本占位符，不伪造 SDK 元数据。恢复工作流将固定应用源码与单独的打包策略提交绑定，验证原始云端作业的成功构建/测试后再复用证据。重新签名、上传与处理状态均须重新检查，参见[实际包验证记录](evidence/floe-1.7/release-156/distribution-recovery.md)。
