# FloeCanvasKit

将资料白板与专业 AI 流程放在同一原生画布上的独立 Swift 6 包。
支持 iOS 26 / macOS 15，swift-tools 6.2，MPL-2.0。

| 产品 | 职责 |
| --- | --- |
| FloeCanvasCore | 稳定快照、混合内容、原子编辑批次、身份复制与类型化流程数据 |
| FloeCanvasLayout | 复用 DiagramKit 公开路由和空间索引，处理折叠、局部整理及视区查询 |
| FloeCanvasUI | SwiftUI 面板、UIKit/CoreGraphics 画布、聚焦编辑、Pencil 与调试界面 |
| FloeCanvasFlow | 类型检查、结构化条件与循环、模板、变量、检查点和调试 |
| FloeCanvasExchange | 完整实验归档、JSON Canvas、Excalidraw、draw.io 与 PDF/SVG/PNG |
| FloeCanvasIntegration | 宿主合同、资格仓库、来源刷新、资源及执行边界 |

本包不依赖 FloeCore/FloeApp，不拥有生产凭据、存储、权限或执行环境。
脚本与 API 步骤由宿主服务执行，不回退本机解释器；普通关系线不触发执行。
文档提交携带预期修订和稳定请求身份，保存及撤销始终由宿主权威仓库管理。

独立 iPad 宿主及基于实际生产 API 编译的适配包位于
[Qualification/InfiniteCanvas](../../Qualification/InfiniteCanvas/README.md)。
它们不注册生产入口，也不升级生产存储。

## 合同

- [核心与宿主边界](CONTRACT.md)
- [原生编辑器](UI_CONTRACT.md)
- [布局](LAYOUT_CONTRACT.md)
- [流程运行时](FLOW_CONTRACT.md)
- [格式支持及转换损失](FORMAT_SUPPORT.md)

原生 .floecanvaslab 保留支持的完整工程、资源、子工程载荷、未知原始载荷，
以及被引用的可复用流程定义。开放格式按其表达能力生成可编辑投影；
调用方应展示转换结果中的损失说明。

## 验证与示例

共享 scratch 目录的构建必须串行执行。原生 UI 使用独立 iOS 资格宿主验证；
macOS 包测试不代表 UIKit 或真实 Pencil 已验收。

从仓库根目录运行：

~~~sh
DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
swift test --package-path FloeAgent/Modules/FloeCanvasKit \
  --scratch-path ~/Library/Caches/CodexBuild/FloeCanvasKit/local/swiftpm --jobs 6
~~~

原兼容示例继续保留。扩展的离线验证程序会在仓库 Local/Private 或
Local/Artifacts 下创建新的证据目录：

~~~sh
DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
swift run --package-path FloeAgent/Modules/FloeCanvasKit \
  --scratch-path ~/Library/Caches/CodexBuild/FloeCanvasKit/local/swiftpm --jobs 6 \
  floe-canvas-examples qualify --output /absolute/repository/Local/Artifacts/canvas-run
~~~

独立资格验证结果已记录。Core/Integration/Flow/Layout/Exchange 共 396 项行为测试通过，
离线示例 50 项检查全部通过。原生 UI 及 iPad 宿主的实际结果分别记录在
[交付记录](../../../docs/FLOE_INFINITE_CANVAS_PREDEVELOPMENT_HANDOFF.zh-CN.md)。
独立预研发与主 App 接入、真实模型/Linux jobs、实机 Pencil、
双设备同步分别验收。
