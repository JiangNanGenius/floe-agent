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
| 分发 | 同一固定提交的开发/发布 SDK 构建、真机验收与可供 TestFlight 分发构建 |

不以“资源下载成功”“工具返回文本成功”替代真实处理证据。密钥、令牌、私人媒体及未脱敏日志不得加入证据包。

## 媒体工作台最小 App

[NativeMedia](../FloeAgent/Qualification/NativeMedia/README.md) 编译生产工作台/播放器，使用合成视频检查编辑模型保存重开和真实导出。`--model-smoke` 产出 `media-model-results.json`，与宿主媒体测试、完整 App UI 和真机结果分别记录。该测试不能证明共享队列或聊天附件已接通。
