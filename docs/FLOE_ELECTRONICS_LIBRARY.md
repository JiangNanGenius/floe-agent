# 电子元件库与按需下载

元件数据由独立公开仓库 [Floe Electronics Library](https://github.com/JiangNanGenius/floe-electronics-library)
维护。GitHub Actions 定期检查已批准来源，固定提交版本，转换二维记录并发布完整包、单库包、
索引、原件和许可。三维目录保留来源提交、路径和 Git 对象身份，模型文件按需获取。

App 的 `electronics.library` 工具消费这条数据源。目录、下载缓存和任务文件由服务管理；
下载结果通过现有运行输出机制返回文件引用，供同一任务继续读取、导入或交付。
原生元件安装、引脚绑定和三维渲染沿用各自的适配与验收流程。

## AI 工具

工具参数是 `action` 与 JSON 字符串 `inputJSON`。下表展示字符串解码后的请求对象。

| action | inputJSON | 结果 |
| --- | --- | --- |
| `refresh` | `{}` | 获取并验证官方目录、资源清单和模型索引 |
| `status` | `{}` | 当前数据版本和缓存状态 |
| `search` | `{"kind":"libraries","text":"KiCad"}` | 上游库及兼容状态 |
| `search` | `{"kind":"parts","libraryID":"kicad-footprints","text":"R_0603"}` | 指定库的实际二维记录索引 |
| `search` | `{"kind":"models","text":"R_0603","format":"step"}` | 单个模型的固定身份 |
| `read` | `{"kind":"part","libraryID":"kicad-footprints","id":"<搜索返回的 id>"}` | 验证后的二维记录；大记录注明截断 |
| `read` | `{"kind":"model","id":"<搜索返回的 id>"}` | 模型来源、版本、路径和对象摘要 |
| `install` | `{"libraryID":"kicad-footprints","partID":"<搜索返回的 id>"}` | 安装所选原生元件，读回后返回 `EDALibraryReference` |
| `download` | `{"libraryID":"kicad-footprints"}` | 一个库的二维 ZIP 与任务文件引用 |
| `download` | `{"full2D":true}` | 全部二维数据 ZIP 与任务文件引用 |
| `downloadModel` | `{"modelID":"<搜索返回的 id>"}` | 一个模型文件与任务文件引用 |

先调用 `refresh` 安装目录，再选择返回的库或模型身份。二维搜索需要相应库内容：
已下载的完整二维包或单库包可直接提供索引和记录；缺少内容时只获取所选单库包。
三维模型逐个下载并缓存。工具支持进度、取消和重新调用；失败的下载保留先前可用缓存。

每条二维记录都有 `converted`、`reviewRequired` 或 `unsupported` 状态。需要复核的几何、
依赖和未支持字段保留来源信息及原件。`converted` 表示交换格式转换完成；原生安装和渲染
仍需对应消费者验证。文件下载成功仅说明拿到了所选版本的文件。

原生安装目前使用现有 KiCad 符号／封装适配器。安装后使用 `eda.library.bind` 明确绑定
符号、封装与引脚映射，再通过 `eda.library.place` 放入工程。其他交换格式仍可搜索、
读取和下载；未支持或需要复核的内容不会被当作可放置元件。

## 三维显示

在线元件库、AI 下载工具与三维视图使用同一个已验证缓存。工程保存固定版本的模型引用，
打开三维视图时才读取网格。下载模型后可点击“重新加载”，也可重新打开三维视图。
目前使用现有 CAD 导入服务显示 STEP／IGES；其他模型原件和引用保留。

每个封装优先显示一个支持的模型，多个引用仍保存在工程中。场景最多保留 48 个不同模型、
256 个放置实例和 100 万个三角形；CPU 网格与实际 SceneKit 缓冲区合计最多 48 MiB，
相同模型的实例共享几何。超过预算或格式未支持时会说明未显示的部分。切换、关闭视图或
关闭工程会取消并等待所属任务，旧视图的延迟回调不会清除新视图。模型变换遵循原生封装
的正反面焊盘坐标。上述保留量限制不代表底层同步 CAD 解析的峰值内存保证。

## 镜像与校验

下载复用 `AppEnvironment.githubTransportMirrors` 的共享签名策略、角色和可用性回退规则。
库工具不增加独立镜像设置。目录身份来自官方发布或此前验证的缓存；镜像只提供字节。
GitHub 资源包使用 `releaseAssets`，固定提交的原始文件使用 `rawFiles`。

KiCad 官方 GitLab 模型可使用内置的官方 GitHub 传输别名，保持相同提交和文件路径，
再按共享策略选择原始文件镜像。该 GitHub 仓库已归档，其后续版本可用性需要实际确认；
GitLab 来源身份始终保留。

资源包核对公开清单中的大小与 SHA-256。二维记录还会核对分块摘要，以及含结尾 LF 的原始 UTF-8 JSONL 行摘要。三维文件先验证
`SHA1("blob " + 文件字节数 + NUL + 文件内容)` 与固定 Git 对象一致，再保存本地 SHA-256。
校验、权限或证书错误会停止下载；可用性错误才按既有规则回退。工具只接收目录中的身份，
不接受调用方提供的 URL、主机路径、凭据或镜像策略。

## 维护与许可

来源和许可审批规则位于独立仓库的 `upstreams.json`，每个发布版附带实际使用的锁定清单。
许可文本变化、来源消失或目录异常减少会停止候选发布；已有数据版本保留。
新增来源需要修改批准清单及必要的客户端来源约束。

主 App 的 MPL-2.0 许可保持原状。第三方数据分别保留 KiCad／Espressif 的
CC BY-SA 4.0 与设计例外、SparkFun 的 CC BY 4.0、LibrePCB 库的 CC0-1.0，
包内保留许可、署名、来源和修改说明。详见独立仓库的
[许可边界](https://github.com/JiangNanGenius/floe-electronics-library/blob/main/LICENSES.md)
及 [模型下载格式](https://github.com/JiangNanGenius/floe-electronics-library/blob/main/docs/MODELS.md)。

## 原生安装与放置

`electronics.library` 的 `install` 接受目录中的 `libraryID` 和精确 `partID`：只处理
`converted` 记录，读取已校验单库 ZIP 中的原始源文件和许可证，沿用现有 KiCad
符号/封装导入器生成小的不可变 `EDALibraryPackage`，再通过元件库存储的 CAS
安装并读回精确 `EDALibraryReference`。`reviewRequired`、未知格式或原生导入剩余
阻断项不会安装，原始记录仍可查看或下载。安装只改变元件库，不修改任何工程原件；
随后用现有 `eda.library.bind` 明确绑定引脚和焊盘，再用 `eda.library.place` 放置。

在线元件库界面只展示目录中的身份、转换状态、安装/取消/重试和进度。关闭界面不会
丢弃已提交的本机安装。安装完成后现有元件选择器刷新，不需要第二套下载器或工程
编辑器。

## 三维模型

封装记录保留来源绑定的三维引用（固定模型 ID、路径、Git 对象、格式、偏移、
旋转和缩放）。模型文件仍按需下载和校验，不嵌入工程或会话。PCB 三维视图只读取
本机已验证缓存，通过注入的精确 CAD 网格加载器显示支持的 STEP/IGES 实体；VRML
等未支持格式保留引用并显示明确状态，不冒充已渲染。同一来源模型在板内只解析一次
并共享 SceneKit 几何；板级总预算、模型数、放置数、并发解析和取消/板切换都会
约束内存，达到预算时显示部分状态，不声称全部模型已显示。

## 原理图到 PCB 同步

`eda.forwardAnnotation` 现在先生成并检查同步计划：缺少封装、锁定封装或无法唯一
映射的已布线网络会返回具体元件/封装/网络身份和下一步操作，不会静默改网络或删除
铜箔；成功应用后核对保存读回的实际板数据。没有封装的元件必须先从在线元件库安装
并显式绑定/指定封装，系统不会按相似名称猜测几何。
