# Floe 1.7 — 内部测试版说明 / Internal beta notes

状态：1.7.0（156）已交付 Floe QA 内部 TestFlight，VALID / IN_BETA_TESTING 已确认。应用源码为 `65969b8` / `v1.7.0-beta.13`，打包策略为 `5231222`；上传使用 Xcode 26.6 / SDK 26.5，部分 27 专属接口走兼容入口。正式发布另行安排；完整包/模型交付和真机验收仍有未完成内容。

## Build 168 反馈修复候选（尚未分发）

- 手记改为封面入口与全屏编辑，可直接从 Floe 项目／聊天工作区导入文件并保存独立副本；全文搜索覆盖正文、有效的 Office 索引与逐页 OCR，显示命中片段及未完整索引的状态。
- 手记参考 Goodnotes 的文档标签操作：切换保留页码、工具与缩放，关闭标签不删除文档；Office 切换前保存失败会保留当前编辑器。标题与标签栏可收起，书写工具保持可用。Apple Pencil 捏压／双击遵循系统偏好；捏一下在笔尖附近展开轻薄工具环，再捏或点空白关闭。移动与抬笔不切换，轻触工具才确认。工具弧位置可选正上方、左上方、右上方并持久保存；新增八种原生笔型及笔迹预览，各自保留颜色、粗细和不透明度，提供细／中／粗快捷档及连续调节。硬件手势待真机确认。
- 增加 Feather 软件源发布流程，从实际 GitHub IPA 生成版本、大小与下载信息，核对校验和及构建来源后更新固定源地址。首个可用地址与安装方式见 [Feather 说明](FEATHER_SOURCE.md)。
- 会话搜索及批量整理增加正文命中；画布增加文件夹、内容搜索和删除后的列表刷新，助手面板与语音按钮重新整理。
- Whisper 下载由应用持有，离开设置页后继续；已完成实际下载、取消后重试及重启校验，真机后台恢复由后续安装验证。
- 移除旧工具调用次数预算，修复执行结果、shell 管道、运行时注册及 HTTPS 证书链；Python/npm 依赖管理直接绑定所选环境。
- Node 常驻命令管道改为有界非阻塞读取，修复空闲时退出等待 libuv 文件读取线程的问题。
- 统一“等待模型响应”状态，稳定思考框预览高度，后续轮次出现时自动折叠旧工具组；普通浏览器调用保持后台，只有明确请求用户交互才呈现面板。
- 已禁用或未配置的搜索工具不进入模型工具目录；模型视觉能力和部分同步设置在加载时恢复，无需再次保存。

上述为候选源码行为，构建号已准备为 168，完整 App 回归与新 TestFlight 可用状态尚未确认。APT 官方签名仓库仍未发布，不能把 PyPI/npm 可用性等同于完整 Linux 软件包生态。当前证据和限制见[反馈修复记录](FLOE_156_FEEDBACK_REPAIR.md)。

### 简体中文

Floe 将 AI 助手、手记和创意工作流放在同一个以 iPad 为优先的原生应用里。手记独立管理课件、手写批注、Office 文件和图文思维导图，并与 Floe 助手共享模型和经过授权的资料。

- 手记：独立入口、笔记本、最近打开、收藏与回收站，PDF/图片批注、Apple Pencil 书写、套索与选区提问、保存解释及来源。
- 动态导图：主题、附图、附件、关联线和分支编辑，自动排版，支持独立创建、文档关联和 PDF 小窗；Agent 按授权编辑，撤销独立。
- Office 与导出：手记内打开 Office 编辑器，保留保存恢复链路；`.floenote` 保留可编辑资料与关联导图，PDF 分享带批注页面，Markdown 导出大纲。Word 画笔、更多转换与 PPT 放映仍需完整运行验收；Excel 暂缓增强。
- 媒体与语音：图像工作台、单素材视频剪裁与字幕，Whisper 多语言模型按需下载，不能使用时回退 Apple；文件转录提供 SRT/VTT/JSON。
- 环境与界面：项目/会话容器和软件包管理、通用设置中的自动/浅色/深色外观、改进的思考与工具调用框、连续工具折叠。

### English

Floe brings its AI assistant, independent Notes workspace and creative workflows together in an iPad-first native app. Notes organizes annotated course materials, handwriting, Office files and illustrated mind maps, while sharing Floe models and explicitly authorized material with the assistant.

Notes includes notebooks, recents, favorites, Trash, Pencil-first writing, region questions and editable archives. Dynamic maps support illustrated topics, attachments, independent editing and linked PDF windows. Image and video workbenches share local files; on-demand multilingual Whisper powers speech and timed captions with Apple fallback. Project/session package controls and automatic light/dark appearance extend the application workspace.

Build 156 is available to the existing internal Floe QA TestFlight group. Word ink, extended conversions, PPT presentation, complete media/model delivery and physical-device qualification are not yet claimed as accepted features.

## TestFlight “What to Test” — 随测试构建填写

1. iPad 优先：导入课件、书写、套索提问、保存回答、关闭重开；手指书写关闭时不能误写。
2. 导图：长标题与附图、展开折叠、拖动分支、Agent 编辑、PDF 小窗缩放与旋转、独立撤销、来源跳转。
3. 数据：`.floenote` 导出导入、Office 保存恢复、回收站恢复/永久删除；共享附件、其他文档及聊天资料不被误删。
4. 语音与媒体：中英混说、取消与失败回退、长文件字幕、剪裁/字幕导出重开及音画同步。
5. 双端与回归：iPad/iPhone，SDK 27 与 26 兼容；聊天、工具、中文 Office、工作区、Canvas 和 PiP。

## 发布门槛与填写项

- 固定源码、版本、打包策略、上传和内测状态已记录于[分发证据](evidence/floe-1.7/release-156/TESTFLIGHT_AVAILABLE.json)。
- 当前云端 53 项平台测试与双端合成 Whisper 推理是定向证据，不等于整版验收。
- 15 个候选软件包、33 个候选模型、15 类媒体能力以[资格矩阵](FLOE_1_7_QUALIFICATION_MATRIX.md)为准，不能因目录存在就标为可用。
- 完整当前记录：[继续实施状态](FLOE_1_7_CONTINUATION_STATUS.md)。恢复步骤：[迁移与恢复](FLOE_1_7_MIGRATION.md)。

截图沿用原始测试产物并注明提交、设备与场景。组件测试画面只能用于说明对应组件，不能作为完整新版本界面的交付证据。

## 真机检查交接

用户已指定由自己执行 iPad/iPhone 真机检查。自动化构建、测试和上传由本轮继续完成；真机结果由用户在 TestFlight 安装后确认，不把设备开发服务可用或模拟器通过写成真机验收。
