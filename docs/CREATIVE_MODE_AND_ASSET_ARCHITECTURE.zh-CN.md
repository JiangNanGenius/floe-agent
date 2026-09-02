# 创意模式、画布与资料库：产品与实施计划

[English](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md) · [使用指南](USER_GUIDE.zh-CN.md) · [架构总览](ARCHITECTURE_OVERVIEW.md)

状态：产品 QA 已锁定；原生画布 MVP 与标准远程 MCP 工具链已进入首个公开 Beta 实现。本文其余阶段是后续扩展目标，不代表当前版本已经全部开放。

当前交互基线（v1.4.75）：画布使用“内容节点 → 任务节点 → 产物节点”的单一链路。生成上下文只沿显式来源关系读取，普通连线、产物关系和未连线备注不会进入提示词；保存配置、开始生成和失败重试共用同一任务快照，既有任务不会补造提示词节点。节点下方 AI 是无工具的节点原位编辑器，右侧 Canvas Assistant 才负责跨节点研究和编排。生成任务必须先保存配置，再由用户从任务卡明确开始；状态同时显示在任务卡和产物卡，失败重试复用原节点。空白处单指平移、节点单指移动、双指随时平移缩放、Pencil 绘制，连接端口支持实时曲线、磁吸和拖到空白处快速新建。

适用范围：Floe Agent 的聊天优先信息架构、项目容器、普通聊天、无限画布、普通绘画、Apple Pencil、图片/视频/音频产物、资料库管理，以及基于 AI/MCP/Skill 的创作操作。

本文补充 [架构总览](ARCHITECTURE_OVERVIEW.md)，并作为当前创意模式的正式实施计划。它不是把当前 App 的可靠能力全部推倒重做，而是规定如何在保留现有 Swift 运行时、安全边界和成熟菜单设置的前提下重做创作工作流。

## 1. 最终产品判断

Floe 仍然以普通聊天为主。普通聊天继续沿用现有的聊天、Task、Run 和 Workspace 层级。Workspace 文件夹右侧的 `+` 是新建工作项入口：第一次使用时可以选择“新建普通会话”或“新建画布”；选择普通会话，或在画布入口已经存在时点击 `+`，都回到首页的新建会话草稿，并自动预选当前 Workspace。用户发送第一条消息后才真正创建 Conversation。每个 Workspace 只有一个画布入口，进入后可以管理多张具体画布。资料库只负责长期图片素材，不承载项目结构本身。整体结构如下：

- `Conversation`：主产品入口，也是所有 AI 执行的统一载体。
- `Workspace`：现有聊天/Task/Run 所属的父级文件容器；通过右侧 `+` 创建普通会话或唯一的画布入口。
- `CanvasProject`：仅能在 Workspace 内创建且每个 Workspace 只能有一个的画布入口/画布工作区容器；进入后可以管理多张 `CanvasDocument`。
- `CreativeArtifact`：项目产生的图片、视频、音频、文本、设计稿、截图、Prompt 和版本。
- `ImageLibraryAsset`：被明确收藏、提升或发布后的长期图片素材，所有对话都可以搜索和读取。

核心原则：

1. 项目是资产的默认归属地。
2. 画布是资产的创作现场。
3. 长期图片资料库是全局复用层，不是所有草稿的回收站。
4. Workspace 只是现有聊天/Task/Run 的父级文件容器，不是一个独立 Agent，也不是共享权限层。
5. 普通聊天继续使用原有层级；绘画和画布是 Workspace 文件夹下的附属创作内容，不是第二套聊天入口。
6. Workspace 可以提供受控的共享项目背景资料；Canvas Agent 可以只读了解项目规划，但不能读取普通聊天的代码上下文。
7. 所有 Conversation/Run 都可以访问全局长期图片库；普通聊天的代码/文件上下文与画布内容仍然分开。
8. 图片、视频和音频的真实文件、语义记录、版本、来源和引用关系分开存储。
9. AI 生成能力是跨模式的共享能力；模式决定结果归属，不重复实现生图/生视频入口。
10. 所有新功能优先复用现有菜单、设置、模型配置、审批、任务时间线和数据管理入口。

## 2. 成熟项目带来的结论

### Penpot：项目文件与共享资产库分离

Penpot 将文件放在项目下，同时允许其他文件作为共享库提供组件、颜色、字体和设计资源。组件有主版本、实例、更新、替换和解除关联等关系。

借鉴：项目内资产默认只服务当前项目；可复用资产需要显式发布；资料库资产有主版本和复用关系，而不是每次复制一份孤立对象。

参考：[Penpot Assets](https://help.penpot.dev/user-guide/design-systems/assets/)、[Penpot Components](https://help.penpot.dev/user-guide/design-systems/components/)、[Penpot 数据模型](https://help.penpot.dev/technical-guide/developer/data-model/)。

### tldraw：文档状态与界面状态分离

tldraw 的 Store 把页面、形状、绑定和资产作为带稳定 ID 的记录管理，并区分文档快照与当前页面、摄像机等会话状态。

借鉴：`CanvasDocument` 不保存临时 UI 状态；摄像机、选区、工具和面板属于 `CanvasSession`；节点修改通过语义命令进入撤销、保存和同步流水线。

参考：[tldraw Store](https://tldraw.dev/sdk-features/store)。

### Excalidraw：场景与 Library 分开

Excalidraw 把当前 scene 与可复用 Library 分开。Library 项目可以本地保存、导入、发布和重新导入，宿主 App 负责具体持久化。

借鉴：进入画布不等于发布到全局资料库；“加入资料库”必须是显式动作；资料库可以保存一组相关对象，而不只是单个图片。

参考：[Excalidraw Library 类型](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/types.ts)、[Excalidraw Libraries](https://github.com/excalidraw/excalidraw-libraries)。

### InvokeAI：Gallery、Boards、来源信息和项目快照

InvokeAI 将生成结果放入 Gallery，并通过 Boards 组织项目上下文；图片保留 Prompt、Seed、模型和输入等生成来源。按日期、收藏等是派生视图，不是新的物理目录。Canvas 项目可以导出为包含图层、蒙版、引用图和生成参数的快照。

借鉴：AI 结果必须带来源信息；项目分类和全局搜索可以同时存在但不能制造副本；删除 Board 和删除素材是两个动作；项目导出只打包必要引用，不把模型本体打进项目。

参考：[InvokeAI Gallery](https://invoke.ai/features/gallery/)、[InvokeAI Canvas Projects](https://invoke.ai/features/canvas/canvas-projects/)、[InvokeAI 图片存储维护](https://invoke.ai/features/image-storage-maintenance/)。

### infinite-canvas：画布 JSON 与媒体 Blob 分开

infinite-canvas 将项目 JSON 与图片/媒体 Blob 分开，节点通过 `storageKey` 引用媒体。这是 Floe 的直接参考，但 Web 端 localForage/IndexedDB 和本地 Node Agent 不能直接作为 iOS 架构。Floe 应使用 Swift、GRDB、文件协调和原生生命周期边界，并把外部 MCP 作为适配层。

参考：[infinite-canvas 数据结构](https://raw.githubusercontent.com/basketikun/infinite-canvas/main/docs/content/docs/development/canvas-data-structure.zh-CN.mdx)、[本地 Agent 集成计划](https://github.com/basketikun/infinite-canvas/blob/main/docs/content/docs/progress/local-agent-integration-plan.mdx)。

许可证门禁：仓库根目录是 MIT，但插件清单目前声明 AGPL-3.0。任何源码、Skill 或插件资产进入 Floe 前必须单独完成许可证、依赖和 App Store 合规审查。

## 3. 领域边界

### 3.0 Chat-first 与项目内工作项

App 启动后默认进入普通聊天列表或新建聊天，不直接进入画布。普通聊天继续按现有层级创建和运行。用户打开一个 Workspace 后，Workspace 顶部的画布入口提供“新建画布”；没有主动创建时，Workspace 不显示画布内容。

```text
Workspace 顶栏
  ├── Workspace 选择器
  └── 画布入口（默认不存在；用户点击后新建）
```

两者都是项目内的工作项：

- 普通聊天是现有的 `Conversation`，可以持续创建多个 `Run`，不因为画布功能改变层级。
- 无限画布是只能在当前 Workspace 内创建的 `CanvasProject` / `CanvasDocument`，适合发散、节点关系、素材编排和 AI 生成流程。
- “普通绘画”是无限画布内的一个绘画工具/子模式，适合单页区域内的草图、手绘、涂鸦、精修和 Apple Pencil 连续绘画；它不创建第三种项目。

普通绘画不需要再引入一个 Agent、项目类型或聊天系统；它只是画布中的一种编辑状态，绘画结果仍然保存为画布节点或图片 Artifact。

### 3.1 Workspace 是普通聊天的既有父级，画布是按需附属面

不存在不依附 Workspace 的 `CanvasProject`。CanvasProject 的创建入口只能位于当前 Workspace 文件夹右侧的 `+` 菜单；如果用户没有创建，Workspace 就没有画布入口、画布会话或画布素材。每个 Workspace 只能创建一个 CanvasProject；CanvasProject 内部的 `CanvasDocument` 数量不受这个入口限制。画布入口存在后，Workspace 行右侧的 `+` 固定执行“回到首页并打开新建会话草稿”，不再打开选择菜单，也不直接创建空 Conversation。

用户打开一个 Workspace 时，仍然先看到现有的普通聊天/Task/Run 层级；画布不是第二个并列项目入口，而是顶部的可选附属面：

```text
Workspace：智能家居 App
├── 现有普通聊天 / Task / Run 层级
│   ├── 普通聊天
│   ├── 代码与文件
│   └── 普通 Agent 的 Conversation / Run
└── 画布入口（可选，用户新建后出现，最多一个）
    ├── 多张画布 / CanvasDocument
    ├── 普通绘画工具
    ├── 画布内 Agent 的 Conversation / Run
    └── 画布项目素材
```

Workspace 继续负责普通聊天的既有归档、列表、文件和 Task 关系，并可维护一组受控的项目背景资料引用；它不产生 `Workspace Agent`，也不把普通 Agent 和画布内 Agent 合成一个 Agent。普通 Agent 继续操作代码和文件；Canvas Agent 只在唯一画布入口创建后操作其中选定的画布、节点和画布素材；两者默认不能读取对方的私有项目上下文，但 Canvas Agent 可以读取被 Workspace 标记为“项目背景资料”的文件。

当前 Floe 已有“一条任务唯一拥有一个 Workspace”的持久化约束。需要在此基础上增加 Workspace 的唯一画布入口和入口内多画布关系，但不能把 Workspace 变成普通聊天与 Canvas Agent 共享的工具权限池。每个 Conversation/Run 仍保留自己的项目上下文快照。

```text
WorkspaceContainer 1 ──── 0..N ProjectContextDocument
WorkspaceContainer 1 ──── 0..N Conversation / Task / Run（现有层级）
ProjectContextDocument N ──── N CanvasProject（只读授权）
WorkspaceContainer 1 ──── 0..1 CanvasProject（默认 0，唯一入口）
CanvasProject 1 ──── 0..N CanvasDocument（入口内部的多张画布）
CanvasProject 1 ──── 0..N Conversation / Run（Canvas Agent）
Run 1 ──── ProjectContextSnapshot
```

### 3.2 受控项目背景资料：让 Canvas Agent 了解项目，但不越权读文件

Workspace 可以维护一组“项目背景资料”。这是一层由用户明确选择、由 Workspace 统一管理、向普通聊天和已创建的画布只读投影的资料，不是第三个 Agent，也不是把 Workspace 下所有文件变成共享文件。

推荐默认支持以下资料类型：

- `PROJECT.md`：项目简介、受众、目标和成功标准。
- `PLAN.md`：阶段计划、范围、优先级和当前进度。
- `BRIEF.md` / 设计简报：视觉方向、页面目标、交付规格和参考对象。
- `DESIGN_GUIDELINES.md`：色彩、字体、间距、组件和品牌约束。
- 用户在 Workspace 中明确勾选的其他只读文档。

用户在 Workspace 主页的“项目背景资料”面板中添加或取消资料，并为每份资料选择允许读取的画布。默认只提供摘要、章节标题和必要的正文片段；Canvas Agent 需要更多内容时，通过 `workspace.read_project_context` 按已授权的文档 ID 和章节读取，不能传入任意路径。

```text
Workspace
├── 项目背景资料（受控、只读）
│   ├── PROJECT.md       → Canvas Agent 可读
│   ├── PLAN.md          → Canvas Agent 可读
│   └── DESIGN_GUIDELINES.md → 普通 Agent / Canvas Agent 可读
├── 普通聊天 / Task / Run（私有代码、文件和对话上下文）
└── 画布（仅在新建后出现，私有画布、节点、Canvas Agent Conversation/Run）
```

必须明确区分以下两类权限：

| 能力 | Canvas Agent | 普通 Agent |
| --- | --- | --- |
| 读取被 Workspace 标记的项目背景资料 | 允许，只读、按文档 ID 和版本读取 | 普通聊天按现有上下文读取；允许只读 |
| 读取普通聊天的代码、任意文件、终端或 Git | 禁止 | 允许，但仍受现有路径守卫和任务权限约束 |
| 读取画布私有节点和画布产物 | 允许，限当前画布项目 | 不允许，除非用户显式附加/导出 |
| 修改项目背景资料 | 禁止 | 由用户或普通 Agent 的既有文件流程修改，修改后下一次 Run 才生效 |

每个 Run 启动时把项目背景资料的文档 ID、内容哈希、版本号和允许的读取范围写入 `ProjectContextSnapshot`。运行中的 Run 继续使用启动时的快照；用户更新 `PLAN.md` 后，下一次 Run 才读取新版本。这样 Canvas Agent 能够理解“我们正在做什么”，但不会因为同属一个 Workspace 就看到代码、凭据、聊天记录或普通聊天的私有上下文。

这条受控投影也适用于普通聊天，但不改变普通聊天原有的私有上下文；不存在独立 CanvasProject，未创建画布时也不存在 Canvas Agent 的画布上下文。

### 3.3 核心对象

| 对象 | 责任 | 不负责什么 |
| --- | --- | --- |
| `WorkspaceContainer` | 父级文件夹、普通聊天层级、唯一画布入口、名称和进入关系 | 不合并普通聊天与画布上下文，不执行 Agent |
| `AgentProfile` | 普通 Agent 或 Canvas Agent 的提示词、工具集和能力边界 | 不拥有 Workspace 父级，不跨项目读取私有上下文 |
| `ProjectContextDocument` | Workspace 中供普通聊天和已创建画布只读的规划、简介、目标和约束文件 | 不包含代码、凭据或任意未授权文件 |
| `CanvasProject` | 所属 Workspace、名称、封面、画布状态和画布 Agent 会话 | 不能脱离 Workspace 存在，不保存完整媒体字节，不拥有远程执行权限 |
| `CanvasDocument` | 页面、节点、连接、画布坐标和文档版本 | 不保存当前面板、摄像机和临时选区 |
| `CanvasSession` | 当前页面、摄像机、选区、活动工具、面板状态 | 不作为文档事实 |
| `CanvasNode` | 文本、图片、视频、音频、组、插件节点及布局 | 不直接内嵌大型 Blob |
| `CreativeArtifact` | 项目产物的稳定身份、类型和来源 | 不直接等同于某个文件 |
| `ArtifactVersion` | 不可变版本、参数、父版本和预览 | 不覆盖历史版本 |
| `MediaBlob` | 图片、视频、音频、缩略图和导出文件的存储引用 | 不决定资源属于哪个项目 |
| `ArtifactReference` | 画布节点、对话、Workspace 文件和长期图片素材的引用 | 不复制资产内容 |
| `ImageLibraryAsset` | 将一个图片产物提升为全局长期图片素材 | 不重新复制媒体文件，不收录视频/音频 |
| `DerivedCollection` | 最近、收藏、类型、标签、搜索和使用位置视图 | 不是物理目录 |

推荐字段方向：

```swift
struct CreativeArtifact {
    let id: UUID
    let projectID: UUID?
    let type: ArtifactType // image, video, audio, text, design, file
    let currentVersionID: UUID
    let source: ArtifactSource
    let createdByRunID: UUID?
    let createdAt: Date
}

struct ArtifactVersion {
    let id: UUID
    let artifactID: UUID
    let blobID: UUID
    let parentVersionID: UUID?
    let metadata: ArtifactMetadata
}

struct MediaBlob {
    let id: UUID
    let contentHash: String
    let mimeType: String
    let storageKey: String
    let byteCount: Int64
}

struct ImageLibraryAsset {
    let id: UUID
    let artifactID: UUID
    let publishedVersionID: UUID
    let tags: [String]
    let searchableText: String
    let embeddingID: UUID
}

struct ProjectContextDocument {
    let id: UUID
    let workspaceID: UUID
    let sourceDocumentID: UUID
    let allowedCanvasProjectIDs: Set<UUID>
    let contentHash: String
    let version: Int
    let allowedSections: [String]
    let readOnly: Bool
}
```

`ArtifactMetadata` 至少保存来源 Run、模型、Prompt、Seed、输入产物、输入节点、创建时间、所属项目、当前引用节点、Workspace 导出路径和人工备注。视频还需要记录宽高比、帧率、时长、分辨率、首帧/尾帧、参考视频或参考图和生成任务状态；音频需要记录时长、采样率、声道和来源输入。

## 4. 存储、版本与生命周期

```text
GRDB / SQLite
  ├── project、document、node、connection
  ├── artifact、version、reference、image library asset
  ├── project_context_document、project_context_grant、版本哈希
  ├── provenance、tag、migration state
  └── 搜索索引与删除墓碑

Application Support / 文件提供者
  ├── 原始图片、视频、音频
  ├── 预览缩略图、海报帧和波形
  └── 导出包与临时文件

Workspace security-scoped root
  ├── 用户文件、代码和导出文件
  └── Workspace 对画布/媒体的文件引用或用户选择保存的画布包
```

Workspace 是逻辑上的文件夹容器。普通聊天继续使用现有层级；Workspace 通过右侧 `+` 管理普通会话和唯一的 CanvasProject 入口。CanvasProject 内部可以有多张 CanvasDocument，它们都归属于当前 Workspace，但不在 Workspace 根目录额外生成多个画布入口。Workspace 另有一层明确授权的项目背景资料投影，供普通聊天和画布只读理解目标和规划，但不因此开放代码或任意文件。媒体 Blob 是否物理存放在 App 管理目录或 Workspace 根目录，由存储策略和用户选择决定，不改变它们的归属关系。

### 4.1 全局长期图片库

`ImageLibraryAsset` 是资料库的唯一长期资产类型。它只接收图片，包括用户导入的图片、AI 生成图片、视频提取的帧、画布导出的图片和用户明确保存的截图。视频、音频、代码文件和画布文档仍属于项目/对话产物，不直接进入这个全局图片库。

所有 Conversation/Run 都有全局图片库的只读搜索和读取能力，不按普通聊天、Workspace 或 Workspace 内画布再切割。区别只在于：

- 项目/画布内容按当前上下文决定默认范围。
- 长期图片库始终可以被搜索。
- Conversation/Run 不会自动把整个图片库加载进上下文，只会根据用户意图或检索结果读取相关图片。
- 写入、替换主版本、归档、删除和批量操作仍然必须经过现有确认与审计。

### 4.2 混合搜索

图片库采用本地优先的混合搜索：

```text
用户查询
  ├── 关键词检索：名称、标签、备注、Prompt、OCR、来源信息
  ├── 语义检索：图片向量、图片描述向量、文本查询向量
  ├── 结构化过滤：类型、比例、颜色、时间、来源项目、使用位置
  └── 结果融合与重排：相关性 + 新近度 + 使用频率
```

实现方向：

1. SQLite FTS5 保存可解释的关键词索引。
2. Vision/OCR/本地模型生成图片描述、文字识别和颜色/比例等特征。
3. 图片本身和图片描述分别生成 embedding，支持“蓝色客厅”“带有某个 Logo 的图片”等文本搜索。
4. 使用 Reciprocal Rank Fusion 或等价的可测试融合算法合并关键词、向量和过滤结果。
5. 结果卡片显示“为什么匹配”，例如标签命中、OCR 命中、语义相似或曾在当前 Workspace 使用。
6. 向量生成失败时仍可使用关键词、OCR 和元数据搜索，不能让资料库整体不可用。
7. embedding 和索引属于可再生成数据；原图、人工标签、Prompt 和来源信息不能因为重建索引而丢失。

图片入库显示明确状态：先完成图片和基础元数据保存，随后异步生成 OCR、描述和 embedding。索引未完成时，所有对话仍可通过名称、标签和来源检索；索引完成后再获得完整语义搜索能力。

搜索入口统一复用普通聊天的附件/工具菜单、创意模式的资料库面板和 Workspace 的项目产物面板；不增加第二个搜索系统。

生命周期：

```text
生成 / 导入 → 临时产物 → 项目产物 → 加入画布
                                  ├→ 附加到对话
                                  ├→ 创建新版本/变体
                                  ├→ 导出到 Workspace
                                  └→ 提升为长期图片素材
```

规则：

1. 新生成或导入的图片、视频、音频默认只进入当前项目，不自动进入全局长期图片库；如果当前项目位于 Workspace，则它同时属于该 Workspace 的项目资料。
2. 加入画布只是创建引用，不复制 Blob。
3. “保存为长期图片素材”创建 `ImageLibraryAsset`，指向已有图片产物或版本；视频和音频不能直接执行此操作。
4. 编辑、重新生成和变体创建新 `ArtifactVersion`，原版本保留。
5. “导出到 Workspace”是明确的文件写入，产生 Workspace 文件引用和变更记录。
6. 从画布移除只移除节点引用，不立即删除产物。
7. 从项目移除只移除项目关联；若长期图片库、对话或 Workspace 仍引用，图片继续保留。
8. 永久删除前展示所有引用、版本和导出文件；删除后保留可恢复墓碑。
9. 只有没有任何引用且经过清理策略确认的 Blob 才可以垃圾回收。

## 5. 图片、视频、音频生成能力

### 5.1 统一能力，不重复入口

生图、生视频、生音频以及图片编辑都属于 Floe 的媒体生成能力，不属于某一个界面。普通聊天、创意模式和 Workspace 都复用同一套：

```text
统一 MediaGenerationService
  ├── Provider adapter
  ├── ModelProfile / capability
  ├── queued generation run
  ├── progress / cancellation / retry
  ├── preview and result streaming
  └── CreativeArtifact + provenance
```

模式只决定：

- 结果默认归属哪个项目。
- 允许模型看到哪些输入。
- 结果显示在聊天消息、画布节点还是 Workspace 项目产物面板。
- 是否允许直接替换节点或写入 Workspace。

### 5.2 普通聊天中的视频生成

普通聊天必须支持视频生成，且不能被创意模式垄断：

1. 用户在普通聊天输入框的现有工具/附件菜单中选择“生成视频”，或直接用自然语言提出视频需求。
2. 视频模型纳入现有“设置 → 模型服务商”的 Provider/Model 管理，与文本、视觉和图片模型使用同一套添加、发现、启用、禁用、凭据和能力标签流程；Agent 实际调用的默认视频模型则在“设置 → 辅助模型”中选择；不新建“视频设置中心”。
3. 生成请求作为当前 Conversation 下的一个 Run，显示在现有任务时间线中。
4. 流程显示排队、生成中、预览、失败、取消和重试，不把提交成功说成生成完成。
5. 生成结果作为聊天附件消息展示，同时创建 `CreativeArtifact`。
6. 当前 Workspace 没有 CanvasProject 时，结果属于当前对话的临时产物；用户点击“保存到资料库”或“加入画布”时再建立长期归属。
7. 用户可以从结果菜单选择“加入画布”（没有画布时引导在当前 Workspace 创建唯一画布入口）、“加入已有画布”“保存到 Workspace”或“仅保留在此对话”。
8. 普通聊天不因为生成视频而自动创建 Workspace。

### 5.3 画布中的视频生成

1. 用户从画布工具栏或节点菜单手动发起视频生成时，可以在模型选择器中选择任意已启用且支持视频能力的 Provider/Model；这是一次性选择，不修改辅助模型默认值。
2. 画布对话中的 Canvas Agent 发起视频生成时，只读取“设置 → 辅助模型”的默认视频模型；不能使用画布上一次手动选择的模型，也不能自行切换 Provider。
3. 如果有选中的参考图、文本节点、首帧/尾帧或参考视频，系统把这些节点作为明确输入引用。
4. 画布先创建一个“生成中”节点和关联 Run；用户可以继续编辑其他区域。
5. 结果完成后更新节点引用到新版本，保留 Prompt、模型和输入关系。
6. 失败时保留失败 Run 和可重试参数，不留下伪成功节点；默认模型不可用时显示明确错误，不静默改用其他模型。
7. 用户可选择“替换当前节点”或“作为新变体”，默认不覆盖原视频。

### 5.4 Workspace 中的视频生成

Workspace 下的普通聊天和唯一画布入口都可以调用统一的媒体生成服务，但结果归属各自的工作面：

- 普通聊天生成的视频进入普通聊天的 Run 和 Workspace 项目产物；普通 Agent 可以按现有文件流程保存代码或文件。
- 画布生成的视频进入画布内 Agent 的 Run 和当前 CanvasDocument 节点；画布内 Agent 不获得普通聊天的代码上下文。
- 两边都可以使用全局长期图片库中的图片作为输入。
- 需要把结果从普通聊天转交给画布或从画布转交给普通聊天时，必须执行明确的导出/导入或复制动作，不是因为同属 Workspace 就自动共享。

无论普通聊天还是 CanvasProject，媒体生成都不直接绕过资产服务操作视频 Blob；文件写入仍使用 `FloeWorkspace` 的路径守卫、原子写入、冲突检查和 Change Artifact。

### 5.5 视频特有交互

- 生成中显示取消、后台状态、预计剩余阶段和重试入口。
- 结果卡片显示首帧、时长、分辨率、模型、Prompt 和来源输入。
- 支持预览、静音、循环、逐帧查看和“选取首帧/尾帧”。
- 支持从视频提取帧作为新的图片 Artifact，但不删除原视频。
- 变体、剪辑和重新生成都是新版本或新产物；原视频保持可恢复。
- 大视频只在需要时加载原始媒体，列表和画布使用海报帧/代理预览。
- iOS 后台限制下，任务状态必须诚实显示；App 被挂起时不声称仍在实时连接。

## 6. 信息架构与入口

Floe 仍然以普通聊天为主。Workspace 继续沿用现有聊天/Task/Run 主页；创意模式提供独立保存的私人画布，也保留 Workspace 顶部的项目画布入口。进入创意模式至少需要一个已配置的生图模型，但不要求先创建 Workspace；资料库可以从普通聊天、画布和项目文件面板进入，第一阶段不增加独立的顶层资料库 Tab。

```text
Floe 启动
  └── 普通聊天（默认，沿用现有层级）

打开 Workspace
  ├── 现有普通聊天 / Task / Run / 项目文件
  └── 顶部画布入口（默认没有；用户主动新建后出现）
       └── 当前 Workspace 的画布与画布 Agent

Files / Workspace
  └── 项目产物面板

普通聊天
  └── 附加：画布、项目产物、长期图片素材、生成媒体
```

如果后续资料库使用频率足以成为主任务，再提升为顶层入口；数据模型和导航路由不依赖这个 UI 决定。

所有资料库选择器都提供两个范围：

1. **当前项目**：当前 Workspace 的普通聊天产物或已创建 CanvasProject 的画布产物，默认范围。
2. **长期图片库**：全局可搜索的长期图片素材，所有 Conversation/Run 都可以读取。

### 6.1 项目主页与工作项跳转

普通聊天不改变现有的新建和层级；Workspace 文件夹行右侧增加 `+`，用于新建普通会话或唯一的画布入口。首次点击时弹出两项选择；画布入口创建后，后续点击 `+` 回到首页并打开预选当前 Workspace 的新建会话草稿，不再弹菜单。进入画布界面后再新建和管理多张具体画布；普通绘画仍是画布内部的绘画工具状态。

```text
Workspace 行                                      [+]
  ├── 新建普通会话
  └── 新建画布（仅在尚未创建 CanvasProject 时显示）

进入唯一 CanvasProject
  ├── 画布 A / CanvasDocument
  ├── 画布 B / CanvasDocument
  ├── 新建画布
  └── 普通绘画模式：在当前画布区域内用 PencilKit/Apple Pencil 手绘
```

Workspace 右侧 `+` 的行为由“是否已经存在 CanvasProject 入口”决定：

| Workspace 状态 | 点击 `+` | 结果 |
| --- | --- | --- |
| 没有 CanvasProject 入口 | 弹出“新建普通会话 / 新建画布” | 选择普通会话则回到首页并打开已预选当前 Workspace 的新建会话草稿；选择画布则创建唯一 CanvasProject 入口和第一张 CanvasDocument |
| 已有 CanvasProject 入口 | 回到首页并打开新建会话草稿 | 自动预选当前 Workspace，不弹菜单，不直接创建空 Conversation，也不创建第二个 CanvasProject |
| 已进入 CanvasProject | 使用画布内部“新建画布” | 创建新的 CanvasDocument；只增加画布文档，不增加 Workspace 入口 |

#### 首页新建会话草稿

从 Workspace 的 `+` 新建普通会话时，App 回到普通聊天首页，但把当前 Workspace 作为草稿的目标预选项，而不是跳进新的聊天层级或立即创建空对话：

```text
普通聊天首页
┌──────────────────────────────────────┐
│ 新建会话                              │
│ Workspace：智能家居 App        [更改] │  ← 已预选
│                                      │
│ 输入消息……                            │
│                              [发送]    │
└──────────────────────────────────────┘
```

- 用户点击发送后，才创建普通 `Conversation` 和第一个 `Run`。
- 用户可以在发送前更换 Workspace、清除 Workspace，或返回而不产生任何记录。
- 草稿只保存导航意图和预选 Workspace，不写入 Conversation 历史。
- 如果用户从已有画布进入首页，草稿仍然是普通会话；它不会自动附加画布内容，只有用户明确选择后才附加。

跳转关系采用“现有聊天层级保持不变 + Workspace 顶部按需打开画布”的方式：

1. Workspace 主页/聊天列表 → 普通聊天：继续创建和打开现有 `Conversation`、`Task` 和 `Run`，使用普通 Agent；可读取被标记的项目背景资料。
2. Workspace 行右侧 `+`（尚无画布入口）→ 弹出选择：选择“新建普通会话”时回到首页并打开预选当前 Workspace 的会话草稿；选择“新建画布”时在当前 Workspace 内创建唯一的 `CanvasProject` 入口，并创建第一张 `CanvasDocument` 后进入画布界面。
3. Workspace 行右侧 `+`（已有画布入口）→ 回到首页并打开预选当前 Workspace 的普通会话草稿，不再弹出选择菜单，也不直接创建空 Conversation。
4. Workspace 顶部 → 已有画布：打开当前 Workspace 唯一的 CanvasProject；没有画布时只显示“新建画布”，不显示“打开画布”。
5. 画布界面 → 新建画布：在唯一 CanvasProject 内创建新的 `CanvasDocument`；这只增加画布文档，不增加 Workspace 入口，也不改变右侧 `+` 回到首页新建普通会话草稿的行为。
6. 普通聊天 → 打开画布：保留当前聊天，将用户明确选择的消息、图片或 Prompt 作为一次性引用带入当前 Workspace 的当前画布；如果当前没有 Workspace，先要求用户选择或创建 Workspace，不创建独立画布。
7. 画布 → 在聊天中讨论：打开当前 Workspace 的普通聊天，或创建一条普通 `Conversation`；它仍使用普通 Agent，不能因此获得画布私有节点上下文。
8. 画布 → 普通绘画：切换到当前 CanvasDocument 内的绘画工具，结果保存为当前画布节点或图片 Artifact。
9. Workspace 主页 → 项目背景资料：用户添加资料并勾选允许读取的画布入口；资料只读投影到下一次 Run，不等于开放 Workspace 文件夹。
10. 普通聊天 ↔ 画布：默认没有私有上下文跳转；需要转交时使用明确的图片/Artifact 导入或长期图片库，不把一个 Agent 的上下文注入另一个 Agent。
11. 任意工作项 → 长期图片库：只对图片提供“保存为长期图片素材”；保存后所有对话都能搜索和读取。

每个工作项都使用统一面包屑：`项目 → 聊天/画布 → 当前内容`。返回按钮优先返回项目主页，不把用户送回上一次不相关的页面。iPad 可以通过多窗口或第三列同时查看项目主页和工作项，但不改变数据归属。

## 7. 完整交互逻辑

### 7.1 新建与进入

#### 普通聊天入口

1. 用户点击“新建任务”，默认进入普通聊天草稿。
2. 用户可以继续发送普通消息，不创建 CanvasProject 或改变现有 Workspace 层级。
3. 用户需要画布时，进入目标 Workspace，点击文件夹右侧 `+`，选择“新建画布”；不能从普通聊天列表直接创建脱离 Workspace 的画布。
4. 从 Workspace 的 `+` 选择“普通会话”只打开首页草稿，不立即创建 Conversation；用户发送后才建立会话，并保留当前 Workspace 归属。
5. 如果要把普通聊天内容带入画布，必须由用户明确选择消息、图片或 Prompt 作为引用；原 Conversation 保留，画布使用自己的上下文。

#### 画布入口

1. 提供不依赖 Workspace 的“私人画布”入口；进入创意模式前至少配置一个可用的生图模型。视频模型是可选 Extra，Workspace 只在用户需要项目归属或文件导出时显式选择。
2. 从 Workspace 文件夹右侧 `+` 选择“新建画布”；没有 Workspace 时先创建或选择 Workspace。
3. 画布入口创建后，点击该入口进入 CanvasProject；最近打开状态恢复该入口内的当前 CanvasDocument。
4. 进入画布后可以创建多张 CanvasDocument；这些文档都在同一个 CanvasProject 内管理。

#### Workspace 入口

1. Workspace 文件夹右侧显示 `+`，普通聊天和 Task/Run 列表继续按现有方式展示。
2. 尚未有画布入口时，点击 `+` 弹出“新建普通会话 / 新建画布”。
3. 选择“新建普通会话”回到首页并打开预选当前 Workspace 的会话草稿；选择“新建画布”创建唯一 CanvasProject 入口和第一张 CanvasDocument。
4. 已有画布入口后，点击 `+` 回到首页并打开预选当前 Workspace 的会话草稿，不再弹出选择菜单；发送后才创建普通 `Conversation`。
5. 点击画布入口进入画布界面；画布内部的“新建画布”只创建新的 CanvasDocument，不增加 Workspace 入口。

### 7.2 画布主界面

画布界面由项目栏、工具栏、无限画布、检查器和底部工作区组成：

```text
┌──────────────────────────────────────────────┐
│ 项目标题 · 保存状态 · Workspace · 分享/导出     │
├──────┬──────────────────────────────┬────────┤
│工具栏 │          无限画布             │检查器  │
│      │  节点、连线、选区、批注、墨迹    │节点详情│
├──────┴──────────────────────────────┴────────┤
│ 项目产物 · 资料库 · 画布对话 · 历史/撤销 · 缩放   │
└──────────────────────────────────────────────┘
```

交互原则：

- 画布是主工作面，面板可收起，资料库不会夺走画布焦点。
- 当前项目和当前选区始终可见，避免用户和 AI 不知道操作对象。
- 保存状态显示“已保存、保存中、待处理、需要恢复”，不能只显示静态图标。
- AI 变更先生成预览，再由用户确认或撤销。
- 画布操作、资料库操作和 Workspace 文件操作使用不同的确认文案。

### 7.3 节点操作

单击节点：选中并在检查器显示类型、来源、版本和引用。

双击节点：进入对应编辑器；文本原位编辑，图片/视频/音频进入媒体检查器，组进入组内编辑。

拖拽节点：移动布局，不改变产物内容；移动操作进入画布命令历史。

连接节点：创建“参考图”“输入素材”“生成结果”“设计变体”等语义关系，而不是只保存一条无意义的线。

节点长按或右键菜单提供：

- 加入当前对话上下文。
- 发送到普通聊天。
- 在当前 CanvasProject 对话中继续。
- 创建变体。
- 使用同一 Prompt 重新生成。
- 打开来源 Run。
- 在长期图片库中定位。
- 保存为长期图片素材（仅图片）。
- 导出到 Workspace。
- 创建独立副本。
- 移除节点。

“移除节点”和“删除资产”必须是两个不同菜单项；后者需要展示所有引用影响。

### 7.4 画布对话与普通聊天

画布对话复用现有 `Conversation` / `Run` 的持久化、进度、取消和恢复模型，但使用独立的 Canvas Agent profile 和画布工具集，不另造一套消息数据库。普通 Agent 和 Canvas Agent 是两个不同的工作角色；普通聊天继续按现有 Workspace 层级运行，Canvas Agent 只在 Workspace 的唯一 CanvasProject 入口内运行。

每个 Run 启动时记录不可变的 `ProjectContextSnapshot`：

```swift
struct ProjectContextSnapshot: Sendable, Codable {
    let workspaceID: UUID?
    let workspaceProjectID: UUID?
    let canvasProjectID: UUID?
    let projectContextDocumentIDs: [UUID]
    let projectContextDocumentHashes: [UUID: String]
    let selectedNodeIDs: [UUID]
    let attachedArtifactIDs: [UUID]
    let allowedAssetScopes: [AssetScope]
    let surface: AgentSurface
}
```

其中全局长期图片库的只读范围是所有新 Run 的默认基础范围；`allowedAssetScopes` 只用于额外限制项目文件、画布和临时产物，不得把长期图片库误删为 Workspace 私有资源。

普通聊天和 CanvasProject 使用不同的 Agent profile，但都复用 Conversation/Run 基础设施：

| 工作上下文 | 默认可见 | 默认不可见 |
| --- | --- | --- |
| 普通聊天 | 当前对话、用户附加内容、全局长期图片库搜索结果；若位于 Workspace，可读被标记的项目背景资料 | 未附加的画布、项目文件 |
| Workspace 中普通聊天的 Conversation/Run | 当前普通聊天的代码、文件和项目产物、被标记的项目背景资料、全局长期图片库搜索结果 | CanvasProject 的私有画布上下文 |
| Workspace 中 CanvasProject 的 Conversation/Run | Canvas Agent；当前 CanvasDocument、当前选区、画布项目产物、被标记的项目背景资料、全局长期图片库搜索结果 | 普通聊天的代码、任意文件和私有上下文 |

“项目背景资料”只通过 Workspace 的授权清单提供，按文档 ID、版本和章节读取；它不是 `workspace.read_file` 的别名，也不允许 Canvas Agent 枚举 Workspace 目录。背景资料更新后，下一次 Run 重新生成快照，当前 Run 不发生隐式上下文变化。

从画布发送到普通聊天时，附加选定节点/资产的引用和预览，不改变原对话类型。从聊天发送到画布时，用户选择目标 CanvasProject，系统创建引用或新节点，不把普通聊天自动变成画布 Agent。

### 7.5 资料库面板

资料库默认打开“当前项目”，提供：全部、画布中、AI 生成、用户导入、参考素材、未使用、版本和变体；切换到“长期图片库”后，显示所有已入库图片。

长期图片库提供类型、标签、来源项目、最近使用、使用位置、版本状态以及重复/近似资产提示。它是全局图片索引，不再按 Workspace 或对话隔离。

资产详情页显示预览、来源、Prompt/模型、版本时间线、引用位置、关联项目和操作按钮：

- 加入当前画布。
- 附加到当前聊天。
- 创建变体。
- 保存为长期图片素材。
- 导出到 Workspace。
- 归档。
- 删除。

“保存为长期图片素材”只对图片可用，创建 `ImageLibraryAsset` 并开始建立混合搜索索引；视频、音频和画布文档保留在项目/对话中。

### 7.6 Workspace 中的代码与设计交接

这里的“往返”不是两个 Agent 共享上下文，而是用户主动发起的交接。普通 Agent 继续负责代码和文件，Canvas Agent 继续负责画布；Workspace 提供两个入口、统一归档和受控的项目背景资料投影。

```text
画布设计方案
  ↓ 导出/生成资源
Workspace/Assets 或用户指定路径
  ↓
代码引用、预览或 App 资源
  ↓ 代码/运行结果
截图、日志或预览回到画布
```

规则：

1. 画布向代码输出时，先显示目标路径、文件类型、覆盖策略和 Git 变更。
2. 默认使用新的导出文件或用户指定的 Assets 子目录，不自动覆盖已有源码资源。
3. 代码向画布输入时，可以导入截图、运行预览、SVG、JSON、组件说明或文件引用。
4. Workspace 文件继续由 `FloeWorkspace` 的路径守卫、原子写入、冲突检查和 Change Artifact 保护。
5. CanvasProject 和普通聊天即使位于同一个 Workspace，也不自动互相访问；跨工作面转交必须通过用户明确的图片导入/导出、长期图片库或其他受控交接动作。
6. 重新导出同一资产时创建新的导出版本并比较差异，避免静默替换。

### 7.7 删除、归档、恢复

删除分四级：

1. 从画布移除：删除节点引用。
2. 从项目移除：删除项目关联。
3. 归档资料库条目：隐藏于默认列表，但保留引用和版本。
4. 永久删除：检查所有引用、导出文件和版本后，经过明确确认再执行。

删除对话、画布或 Workspace 时先显示影响清单，例如：

```text
将移除：1 个 CanvasProject 关系、3 个节点引用、0 个资料库条目
仍保留：2 个资料库资产、4 个历史版本、1 个 Workspace 导出文件
```

恢复优先恢复数据库关系和版本；媒体缺失时显示缺失清单和重新定位入口，不能用占位图伪装恢复成功。

## 8. Apple Pencil 与无限画布交互

### 8.1 技术分层

采用 SwiftUI 外壳 + UIKit/Metal 画布内核：

- SwiftUI：导航、工具栏、检查器、资料库、聊天和设置。
- UIKit：触控、键盘、拖放、Pencil 事件和多指手势协调。
- Metal/MetalKit：大量节点、缩略图、连线和缩放时的高性能绘制。
- PencilKit：自由手绘、批注和墨迹图层，墨迹坐标转换到 `CanvasDocument` 坐标系。
- Floe 文档命令层：节点、连接、分组、墨迹和 AI 变更统一进入撤销/保存/同步流水线。

PencilKit 负责自然书写体验，画布文档负责稳定对象、版本和引用；不能让 PencilKit View 直接成为持久化数据模型。

### 8.2 Pencil 手势规则

- Pencil 绘制，手指默认平移/选择，双指缩放。
- Apple Pencil 悬停显示笔尖位置、当前工具和可捕捉节点预览；不支持悬停的设备退化为按下反馈。
- 压力、倾角、方位和橡皮擦状态保存到墨迹版本。
- Pencil 双击切换当前工具；用户可以在已有设置中的“画布与 Pencil”项修改。
- 长按节点显示操作菜单；避免把长按误判成连续绘制。
- 画布边缘自动平移有速度上限，Pencil 离开后立即停止。
- 所有 Pencil 操作支持系统 Undo/Redo 和 Floe 变更时间线恢复。

### 8.3 设备与性能目标

首个技术门以 iPad Pro/M1 或 A17 Pro 级设备为基准，同时验证 iPhone 的只读/轻编辑体验。需要单独测试：

- 100、500、2,000 个节点下的平移和缩放。
- 4K 图片缩略图和视频预览不会阻塞主线程。
- Pencil 连续书写、切换工具、后台恢复和低内存场景。
- 大文档打开、保存、崩溃恢复和撤销栈增长。
- VoiceOver、动态字体、指针、键盘和外接显示器。

## 9. 现有菜单、设置与能力复用

### 9.1 复用原则

创意模式不能新建一套与主 App 平行的“模型设置、权限设置、数据管理、任务列表、导入导出和诊断”入口。所有能力优先回到已有入口：

| 能力 | 统一入口 | 创意模式中的表现 |
| --- | --- | --- |
| 服务商、模型、API Key | 现有设置 → 模型服务商 | 右上角 `+` 先选择模型服务商类型，再进入对应 Provider/Model 配置；LLM Provider 同时承载文本和视觉模型，图片、视频/音频模型按媒体 Provider 管理，不复制配置表单 |
| 图片编辑与图片模型 | 现有设置 → 辅助模型只负责角色选择 | 辅助模型页移除“添加图片模型”快捷入口；新增图片模型统一回到模型服务商管理 |
| 视频生成模型 | 添加/维护：设置 → 模型服务商；默认值：设置 → 辅助模型 | 手动生成可临时选择全部兼容模型；普通聊天和 Canvas Agent 使用辅助模型设定的默认视频模型 |
| 任务进度、取消、重试 | 现有 Conversation/Run 时间线与任务中心 | 生成中节点链接回 Run |
| 权限与确认 | 现有任务权限、审批和安全设置 | 导出、发布、删除沿用相同确认层 |
| Files 与 Workspace | 现有 Files/Workspace 入口 | 只通过明确“导出到 Workspace”进入 |
| Git 变更 | 现有源码管理检查器 | 导出后显示同一个 Diff/Change Artifact |
| 数据管理 | 现有设置 → 数据管理 | 增加画布/媒体占用和清理分类 |
| Skill | 现有 Skill 管理与校验 | 增加 canvas/artifact 能力，不建立第二种安装流程 |
| MCP/外部连接 | 新增普通 Agent 的标准 MCP 工具来源，复用现有连接/主机/工具安全边界 | 画布默认不用 MCP；仅用户逐 Server 授权后再按 Run 权限筛选；不暴露任意 App 控制 |
| 诊断与恢复 | 现有 More → Diagnostics/数据管理 | 增加画布索引、Blob 和恢复报告 |

### 9.2 设置结构调整

只在已有设置分类下增加必要字段：

```text
设置
├── 服务商与模型
│   ├── LLM 服务商（普通文本 + 视觉输入能力）
│   ├── 图片生成/编辑服务商
│   └── 视频/音频生成服务商
├── 辅助模型
│   ├── 识图与审查模型
│   ├── 默认图片生成/编辑模型
│   └── 默认视频模型
├── 任务与权限
├── 工作区与文件
├── 数据管理
│   ├── 对话与运行
│   ├── 画布项目
│   ├── 媒体缓存
│   └── 资料库
├── Skills 与工具
├── 主机与远程
└── 诊断
```

不增加独立的“创意设置中心”。画布项目自己的设置只保留画布确有必要的项目级选项，例如背景、网格、默认导出格式和 Pencil 默认工具；模型、权限、同步、存储和通知仍由主设置管理。

设置边界固定为：模型服务商页负责“添加什么 Provider、模型来自哪里、是否启用以及支持什么能力”；LLM Provider 的普通文本和视觉模型使用同一条配置链路，视觉只是 `ModelProfile.capabilities` 中的图片输入能力。辅助模型页只负责“当前 Agent 使用哪个已配置的识图/审查/图片生成/图片编辑/视频角色模型”。辅助模型页不得再提供添加图片模型的第二入口，视频模型本体也不得绕过模型服务商页单独配置；辅助模型页只保存默认视频模型 ID。

模型服务商页右上角 `+` 的交互：

```text
设置 → 模型服务商                         [+]
                                             │
                                             ▼
                              选择要添加的模型服务商类型
                              ├── LLM 模型服务商
                              │   └── 普通文本模型 / 视觉模型
                              ├── 图片生成/编辑模型服务商
                              └── 视频/音频模型服务商
                                             │
                                             ▼
                              选择 Provider 预设或自定义端点
                              配置 Endpoint / 凭据 / 模型 / 能力
```

这里选择的是“Provider 类型”，不是把每种模型能力都创建成独立 Provider。LLM Provider 的模型由同一个 Provider 配置链路管理；其中支持图片输入的模型通过 `ModelProfile.capabilities` 标记为视觉模型，辅助模型页从已配置的 LLM 模型中筛选默认识图模型。若 Provider 已经存在，流程应优先进入该 Provider 的“添加模型/启用能力”状态，不重复创建同一个 Provider。

### 9.3 复用现有 AppRouter 和导航状态

当前 `FloeApp/Shell/AppRouter` 是跨 iPhone/iPad 的统一路由源。计划扩展 `WorkbenchSelection`，而不是在 Creative View 内创建另一套路由：

```swift
enum WorkbenchSelection: Hashable, Sendable {
    case overview
    case newTask(workspaceID: UUID?)
    case workspace(UUID)
    case workspaceProject(UUID)
    case conversation(UUID)
    case canvasProject(UUID)
}
```

检查器增加画布项目、节点详情、项目产物和资料库内容，但仍复用现有 iPad 第三列 / iPhone Sheet 机制。导航、场景恢复和后台生命周期由 AppRouter/现有 Platform 层统一负责。

## 10. 现有 Swift 组件复用方案

### 10.1 必须保留并复用

| 现有组件 | 复用方式 |
| --- | --- |
| `FloeCore` | 错误、事件、权限、ID、并发和基础协议；不加入 SwiftUI 状态 |
| `FloeModels` | 扩展 Canvas、Artifact、Version、Reference、Library 的 Sendable/Codable 值模型 |
| `FloeAgentRuntime` | 继续负责 Conversation/Run、上下文组装、检查点、取消、恢复和事件时间线 |
| `FloePersistence` | 新增画布/资产/版本/引用/资料库迁移和 actor 隔离 Store；沿用原子事务和 schema migration |
| `FloeSecurity` | 复用审批、灾难性操作门、审计链；为导出、删除、发布增加资源影响范围 |
| `FloeTools` | 继续作为编译期工具目录和 Schema 过滤层；新增画布/资产工具描述 |
| `FloeSkills` | 复用 Skill 包校验、能力上限、来源和每次 Run 的工具收窄 |
| `FloeProviders` | 复用文本、视觉、生图、图片编辑和新增的视频/音频 Provider 适配器 |
| `FloeImages` | 复用本地图像处理、缩略图、格式、元数据和版本化输出；不把它改成全局资料库 |
| `FloeDocuments` | 复用文档读取、编辑、导出和 Workspace 变更桥；画布只通过明确导出调用它 |
| `FloeWorkspace` | 复用安全作用域、路径守卫、原子写入、冲突和 Change Artifact；画布不能绕过它写文件 |
| `FloeGit` | 复用导出后的仓库状态、差异、提交和同步展示 |
| `FloeApp/Shell/AppRouter` | 扩展统一路由和 iPhone/iPad 自适应导航；不在 View 内复制导航状态 |
| `FloeApp/Chat` | 复用消息渲染、Run 时间线、审批、附件、生成结果和上下文附加入口 |
| `FloeApp/Workspace` | 复用 Workspace 项目主页、文件检查器、源码管理和导出确认 |
| `FloeApp/Platform` | 复用场景生命周期、后台边界、恢复和通知策略 |

### 10.2 新增窄边界模块

```text
FloeModels
  └── Canvas / Artifact / Library value models

FloePersistence
  └── CanvasStore / ArtifactStore / MediaIndexStore / migrations

FloeArtifacts
  └── 资产生命周期、版本、引用、去重、垃圾回收、资料库服务

FloeCanvas
  └── CanvasDocument、命令、选区、连接、渲染输入、Pencil/Metal bridge

FloeApp/Creative
  └── SwiftUI 入口、画布壳、检查器、资料库面板、项目流程
```

依赖方向：

```text
FloeCore → FloeModels → FloePersistence
                     ↘ FloeArtifacts → FloeCanvas
FloeAgentRuntime → FloeTools / FloeSecurity / FloePersistence
FloeApp → 上述模块及现有 Providers、Workspace、Documents、Images
```

`FloeArtifacts` 不直接取得 Workspace 根目录；`FloeApp` 或专门的导出适配器将资产服务与当前 `WorkspaceRecord`、`WorkspacePathGuard` 连接，防止项目资产反过来扩大文件权限。

### 10.3 “重写整个 App”的实际含义

“用 Swift 框架重写”按以下方式执行：

- 重写 App Shell、导航、画布交互、状态编排和创作体验。
- 保留已经验证过的 Swift 6 领域模型、Agent Runtime、Persistence、安全、工具、Provider、Workspace、文档和图片能力。
- 旧 View 不作为新交互的状态源；迁移期可以复用服务和 ViewModel，但新界面只能通过统一 Store/Coordinator 访问数据。
- 每个阶段都能编译、测试和运行，禁止等到全部画布完成后才验证原有聊天、Workspace 和远程能力。

## 11. AI、MCP 和 Skill 设计

### 11.1 工具边界

计划增加以下受限工具族：

```text
canvas.read_state
canvas.read_selection
canvas.create_node
canvas.update_nodes
canvas.connect_nodes
canvas.move_nodes
canvas.delete_nodes
canvas.apply_ops

artifact.search_project
artifact.get_metadata
artifact.attach_to_canvas
artifact.attach_to_conversation
artifact.create_version
workspace.list_project_context
workspace.read_project_context
image_library.search
image_library.get
image_library.save
artifact.export_to_workspace
artifact.archive

web.search
web.fetch
```

工具只能接收结构化 ID 和受限参数，不能接收任意屏幕坐标后模拟点击整个 App。AI 的画布写操作以 `CanvasOperation` 列表返回，由 App 校验目标版本、冲突和权限，再生成用户可读的变更预览。

工具目录按工作面做能力筛选。普通聊天从 Floe 原生工具、Skill 与用户启用的 MCP Server 组成候选目录，再由当前 Run 的 Workspace、任务权限和模型能力取交集。CanvasProject 默认只获得 Floe 原生的画布节点、绘画、画布素材、媒体生成、`web.search`、`web.fetch` 以及被授权项目背景资料的只读工具；不提供浏览器导航、点击、登录、表单操作或 Computer Use。联网搜索只用于发现公开资料和候选素材，Web Fetch 只读取用户目标或搜索结果的明确 URL；导入画布前保存来源 URL、抓取时间和可获得的作者/许可信息，无法确认授权状态时标记为“许可待确认”，不能自动宣称可商用。画布核心能力不依赖 MCP，也不通过 MCP 实现。MCP 不是新的 Agent，更不是画布能力的前置条件。只有用户对某个 Server 明确开启“允许在画布中使用”，并且其具体工具被本地策略判定为与素材、设计资料或当前创作任务相关时，该工具才进入 Canvas Run 候选目录。任何 MCP、Skill 或模型参数都不能扩大当前 Run 的原生权限上限。`workspace.read_project_context` 只能解析 Workspace 授权清单中的文档 ID、章节和版本，禁止任意路径、代码、凭据、终端、Git 或 SSH。图片跨工作面交接只能由用户触发的导入/保存流程完成。

### 11.2 确认和撤销

- 读取当前状态、搜索项目资产、搜索/读取全局长期图片、生成预览：按低风险只读规则执行。
- `web.search` 与 `web.fetch` 属于受限只读联网能力；下载或保存素材必须保留来源与许可状态，遇到登录、付费墙、验证码或交互页面时停止，不升级为浏览器控制。
- 创建节点、移动节点、修改文本：显示可撤销变更；用户开启画布自动执行时可以批量确认。
- 删除节点、删除资产、发布到资料库、导出到 Workspace：必须明确确认。
- 所有 AI 变更带 `runID`、`operationID` 和父文档版本。
- 应用失败时不提交部分成功的隐式状态，逐项报告成功、冲突、跳过和失败。

### 11.3 Skill 与标准 MCP

现有 `FloeSkills` 的 `SKILL.md + floe.json`、静态校验、能力上限和每次 Run 工具白名单继续复用。infinite-canvas 的 Codex 插件 Skill 不能直接当作 Floe Skill 安装；需要转换为 Floe 格式，并重新声明：

- `canvas.read`。
- `workspace.project_context.read`：读取 Workspace 明确授权的项目规划资料，只读、按版本和范围限制。
- `canvas.write`。
- `artifact.read`。
- `artifact.write`。
- `image_library.read`（所有 Conversation/Run 的默认只读能力）。
- `image_library.write`（保存、替换、归档和删除需要明确授权）。
- `workspace.export`。

Skill 可以缩小权限，不能动态增加原生能力。MCP 是普通 Agent 的可选外部工具来源：用户可以在设置中添加、测试、启用、停用和删除标准 MCP Server，普通聊天通过现有 Conversation/Run、审批、审计和执行账本调用其工具。画布默认不暴露 MCP；若用户单独授权某个 Server 在画布中使用，仍需经过画布工作面和当前 Run 的二次筛选。

首个公开 Beta 的标准 MCP 支持范围：

- 原生支持 Streamable HTTP，兼容旧版 HTTP+SSE；初始化时协商协议版本、能力和会话 ID。
- 支持无需认证、用户提供的 Bearer/API Token 和自定义认证请求头；所有秘密只存钥匙串。交互式 OAuth 发现、PKCE 与令牌刷新在完成独立安全和恢复门禁后再开放，不在本次 Beta 中伪装成已支持。
- 支持 `tools/list`、分页、列表变更通知、`tools/call`、进度、取消和结构化内容；Resources 与 Prompts 可浏览、读取和显式加入上下文，但不自动注入每次 Run。
- iOS 本机不启动 `stdio` 子进程，不依赖 `npx`、Node、本地下载代码或 `127.0.0.1` Agent。远端 stdio bridge 需要单独的守护程序生命周期、权限和恢复设计，不在本次 Beta 中开放。
- 不在首轮渲染任意 MCP Apps/第三方 UI，也不允许 MCP 暴露或调用未编译进 Floe 的 iOS 原生 API。MCP 返回的文本、资源、工具描述、Schema 和结果全部视为不可信数据。

添加流程：用户输入显示名称与 MCP URL，Floe 先进行只读探测，显示服务身份、协议版本、认证方式和工具清单；用户确认后才启用。每个 Server 和每个工具都可以单独停用。工具名称使用稳定命名空间，避免多个 Server 重名。Server 声明的只读/破坏性注解只作为提示，最终风险标签、审批、数据发送提示和灾难门禁由 Floe 本地策略决定。未知或会写入外部系统的 MCP 工具默认需要审批；读取用户文件、图片、位置、联系人等受保护数据并发送给 MCP 时，必须在具体调用中取得明确同意。

MCP 配置归入“Skills 与工具来源”，不放在模型供应商或画布设置里。工具选择器按“Floe 原生 / Skill / MCP Server 名称”分组，用户能看到当前普通会话实际可用的工具、不可用原因、最近连接状态和最后一次调用结果。每个 Server 的“允许在画布中使用”默认关闭。

## 12. 分阶段实施计划

### Phase 0：设计与合规门

产出：

- 本文评审结论。
- `CanvasProject / Workspace / Conversation / Run / Artifact` 关系图。
- infinite-canvas 源码、插件、字体、图标和依赖许可证清单。
- 目标设备、性能预算、媒体大小和离线恢复指标。
- 标准远程 MCP 是可选工具来源，不把外部 Node/MCP 服务作为 Floe 核心能力或画布能力的前置条件。
- App Review 说明：MCP 只传输 JSON-RPC 工具请求，不在 iOS 下载或执行新代码，不向 MCP 暴露原生平台 API，受保护数据逐次同意，审核账号可看到 Server 管理、工具清单和关闭入口。

门禁：产品边界、删除语义、资产生命周期、视频能力归属、设置复用和许可证全部确认。

### Phase 1：领域模型与持久化

工作：

- 在 `FloeModels` 增加画布和资产值模型。
- 在 `FloePersistence` 增加新 schema migration、Store 和事务。
- 建立节点/资产/版本/Blob/引用/资料库条目的外键和删除墓碑。
- 建立媒体生成 Run、视频状态和 `ProjectContextSnapshot`。
- 定义 schema version、导入 adapter 和未来格式迁移入口。

验收：断电、崩溃、重复提交、重复导入、旧数据迁移、删除后恢复和引用保护测试通过。

### Phase 2：统一媒体生成与媒体存储

工作：

- 抽象 `MediaGenerationService`，让普通聊天、画布和 Workspace 调用同一服务。
- 复用现有 Provider、ModelProfile、图片模型配置和任务时间线。
- 将视频/音频能力作为 `ModelProfile` capability 纳入现有 Provider/Model 管理；移除辅助模型页的“添加图片模型”入口和重复编辑流程。
- 视觉模型不新增 Provider 类型：沿用 LLM Provider 的消息/多模态输入适配器，由 `ModelProfile.capabilities` 标记图片输入；辅助模型只筛选兼容的 LLM 模型。
- 在辅助模型偏好中增加 `defaultVideoModelID`；普通聊天和 Canvas Agent 的视频工具只使用该默认模型，画布手动生成仍使用独立的临时模型选择。
- 增加视频/音频能力标识、参数校验、排队、取消、重试、预览和失败状态。
- 实现 Application Support 媒体目录、缩略图、海报帧、波形、内容哈希和安全临时文件。
- 复用 `FloeImages` 的图像信息和操作能力。
- 实现 `ArtifactStore`、版本、来源、引用、收藏、归档和垃圾回收。

验收：模型供应商页能添加、启用和禁用视频模型；辅助模型页能设置默认视频模型；普通聊天和 Canvas Agent 使用默认模型完成“请求视频 → 生成 Run → 预览 → 保存/加入画布”；画布手动生成可以选择其他兼容模型且不修改默认值；项目删除不误删仍被长期图片库或其他引用使用的媒体。

### Phase 3：Canvas 内核与 Pencil 技术验证

工作：

- 实现画布坐标系、视口、节点索引、连接和语义命令。
- 实现 Metal/MetalKit 的大画布渲染输入。
- 实现 PencilKit 墨迹图层与画布坐标转换。
- 实现 UIKit 手势、Pencil 悬停、键盘、指针和拖放桥。
- 让撤销/重做、保存、快照和恢复都走同一命令流水线。

验收：目标设备完成节点数量、缩放、Pencil 连续书写、低内存、后台恢复和无障碍测试。

### Phase 4：Workspace 画布 MVP

工作：

- 在 Workspace 文件夹右侧增加 `+`，实现“新建普通会话 / 新建画布”的首次选择。
- 实现一个 Workspace 只能有一个 CanvasProject 入口；入口内支持多张 CanvasDocument 的新建、打开、重命名、封面、最近项目和恢复。
- 支持文字、图片、视频、音频、墨迹、分组、连接、缩放、选区和检查器。
- 支持当前项目产物、导入、统一媒体生成、版本和删除语义。
- 接入现有聊天时间线，但限制为当前 CanvasProject 和当前 CanvasDocument 上下文。

验收：只能在 Workspace 右侧 `+` 创建画布入口；首次点击可选择普通会话或画布，画布入口存在后点击 `+` 回到首页并预选 Workspace；发送后才创建普通会话；进入唯一入口后可以创建和恢复多张 CanvasDocument；普通聊天和既有 Workspace 回归测试通过。

### Phase 5：资料库与复用工作流

工作：

- 实现当前项目和全局长期图片库两个范围。
- 实现图片的 FTS5、OCR/描述、embedding 和混合搜索；索引失败时保留关键词搜索。
- 实现收藏、提升、发布、标签、搜索、最近和引用位置。
- 实现版本、变体、创建独立副本和来源查看。
- 实现导入/导出项目包；项目包只带必要引用，不打包模型和全局库本体。
- 将资料库入口接入现有数据管理，不新增独立设置中心。

验收：生成、打开或拖入画布不会自动污染全局长期图片库；图片入库后所有对话都能搜索和读取；复用时不产生无意义 Blob 副本。

### Phase 6：Workspace 画布入口与显式转交

工作：

- 普通聊天继续沿用现有 Workspace、Conversation、Task、Run 和文件层级。
- Workspace 右侧 `+` 在没有 CanvasProject 时弹出“新建普通会话 / 新建画布”；已有 CanvasProject 时回到首页并打开预选当前 Workspace 的普通会话草稿。
- Workspace 最多保存一个 CanvasProject 入口；入口内部保存多张 CanvasDocument、画布 Conversation/Run、项目产物和上下文。
- Workspace 提供项目背景资料清单；用户明确标记的规划、简介、目标和设计约束可被普通聊天和 CanvasProject 只读读取，并按版本进入下一次 Run 的上下文快照。
- 实现用户主动发起的图片导入/导出、长期图片库保存和受控交接，不实现自动上下文串联。
- 普通聊天继续复用 `FloeWorkspace` 的路径守卫、原子写入、冲突检查、Change Artifact 和 `FloeGit`。
- CanvasProject 可以搜索全局长期图片库、读取已授权的项目背景资料，但不能调用普通聊天的代码/文件工具，也不能枚举 Workspace 任意路径。

验收：Workspace 右侧 `+` 的两态行为正确；已有画布时点击 `+` 回到首页并预选 Workspace，发送前不产生空 Conversation；Workspace 只有一个画布入口，但入口内部可以创建多张 CanvasDocument；普通聊天与 Canvas Agent 的私有上下文、工具和任务历史不串线；Canvas Agent 能读取已授权的 `PROJECT.md`/`PLAN.md` 等资料，但无法读取代码和任意文件；资料更新只影响下一次 Run；用户明确转交图片时流程可追溯，没有未经确认的代码项目文件写入。

### Phase 7：AI、Skill、标准 MCP 和自动化

工作：

- 增加结构化 Canvas/Artifact 工具和权限映射。
- 为 Canvas Agent 暴露受限 `web.search` 与 `web.fetch`，用于发现公开资料和拉取明确 URL；不暴露浏览器导航、点击、登录和 Computer Use 工具。
- 实现变更预览、批量确认、冲突检查和逐项结果。
- 为 Floe Skill 增加画布/资产能力声明。
- 将外部 infinite-canvas Skill 转换为 Floe 格式，完成许可证和工具映射审查。
- 提供原生 Swift CanvasCoordinator；画布操作首先作为 Floe 原生结构化工具实现。
- 增加标准 MCP Server 管理、Streamable HTTP、旧 HTTP+SSE 兼容、OAuth/令牌、工具发现与调用、Resources/Prompts 显式导入、断线恢复和诊断。
- 普通聊天使用已启用的 MCP 工具来源；CanvasProject 默认不使用 MCP，仅在用户逐 Server 开启画布授权后按工作面和 Run 权限过滤。MCP 不引入新的 Agent 类型，也不能扩大原生权限。
- 增加远端执行环境上的可选 stdio MCP bridge；iOS 本机不启动外部进程。
- 增加 App Intents：打开项目、附加资产、生成媒体、导出资产等入口；写入和删除仍走确认。

验收：普通聊天能调用获准的 MCP 工具；未开启画布授权时 Canvas Run 看不到任何 MCP 工具，开启后也只能看到当前画布任务获准的工具；Canvas Agent 可以通过 `web.search` 和 `web.fetch` 找到公开资料并把带来源/许可状态的素材候选加入项目，但无法调用浏览器点击、登录或 Computer Use；普通聊天和 Workspace 内 CanvasProject 的 Conversation/Run 都能读取全局长期图片库；不存在脱离 Workspace 的画布 Run；Canvas Agent 无法越权读写普通聊天的代码和任意 Workspace 文件；MCP 断线、401、Schema 变化、工具重名、取消、超时和恶意结果都有确定状态；所有 AI 变更都可追溯和撤销。

### Phase 8：同步、迁移与发布

工作：

- 定义 iCloud 同步范围：优先同步元数据和用户选择的项目状态，媒体按明确策略处理。
- 解决多设备冲突、Blob 缺失、版本冲突和离线编辑。
- 提供 infinite-canvas 导入适配器，不直接把其历史 JSON 当作 Floe 永久格式。
- 增加诊断、导出、恢复、存储清理和性能报告。
- 同一版本完整交付，但使用内部验收门顺序启用：Workspace 画布入口 → 资料库 → 多 CanvasDocument → AI/标准 MCP；任一门失败时不创建发布标签。

验收：旧用户的普通聊天、Workspace、Files、Git、SSH、VNC 和设置无回归；画布能力可以关闭或迁移，不阻塞原有工作流。

## 13. 测试与发布门禁

### 领域与存储

- 项目、Workspace、对话和资产归属不交叉污染。
- 稳定 UUID、版本父子关系、内容哈希和引用计数正确。
- 事务中断后不出现半个节点、半个资产或错误资料库条目。
- 删除、归档、恢复和孤儿回收符合影响清单。
- 导入旧格式失败时保留原文件并报告具体字段。

### 交互

- iPhone 和 iPad 路由使用同一选择源，不出现 Home/Chat/Canvas 各自维护的旧状态。
- 普通聊天、私人画布与 Workspace 画布之间的引用和转交必须由用户明确触发；私人画布不隐式获得任何 Workspace 文件上下文。
- 普通聊天、画布和 Workspace 都能使用视频生成；配置和任务进度来自同一套能力。
- AI 操作有预览、确认、撤销和失败状态。
- Pencil、手指、鼠标、键盘、VoiceOver 和动态字体都能完成核心流程。

### 安全

- 不存在独立画布；Workspace 内的 CanvasProject 只能读取授权清单中的项目背景资料，其他文件访问仍受当前 Conversation/Run 的任务权限约束。
- 导出、发布、删除和共享走现有审批与审计链。
- 画布与资料库工具只能操作授权的结构化资源 ID。
- Skill 只能收窄能力，不能动态注册未经审查的原生工具。
- 许可证、第三方依赖和插件内容通过发布前审查。

### 性能与恢复

- 大画布滚动、缩放和 Pencil 采样不阻塞主线程。
- 媒体解码、视频海报帧和缩略图生成可取消、可恢复、有限流。
- 后台、终止、低内存和磁盘不足都显示真实状态。
- 崩溃恢复不会把未提交的 AI 操作或媒体导出说成已完成。

## 14. 当前实现顺序

在开始画布 UI 之前，先完成：

1. 本文作为产品和架构基线评审通过。
2. 在 `FloeModels`/`FloePersistence` 中落下资产、版本、引用和资料库模型。
3. 完成统一媒体生成 Service，使普通聊天和创意模式共享图片/视频能力。
4. 完成媒体 Blob、缩略图、删除保护和导出 Workspace 的最小服务。
5. 完成 Canvas 内核的坐标、命令、撤销和 Pencil 技术验证。
6. 清点所有现有菜单和设置项，确认新功能只有增量字段和上下文入口，没有重复设置中心。

之后再做创意模式界面。这样画布不会先以临时 JSON 和 View 状态长出来，最后再被迫重构资料库、视频生成、AI 上下文和 Workspace 边界。
