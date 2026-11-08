# 主 App 接入合同

本目录的 `FloeLaTeXHostAdapter` 已提供共享服务和 6 个模型工具。不能将独立 `Qualification/LaTeX` 宿主的简化所有权或原生实验接入正式 App。本轮已在 `FloeApp/Space/LaTeX` 和既有集中入口完成接线；冻结源的实际 App／定向测试 runner 已构建通过，主线接管后续增量与最终模拟器验收。

## 依赖与单例

1. `project.yml` 添加正式 `Modules/FloeLaTeXKit` 产品 `FloeLaTeXKit`，以及 `Integration/FloeLaTeXHostAdapter` 产品；运行既有工程生成脚本。不要添加 `Native/Experiment`。
2. AppEnvironment 在真正的 jobs、环境注册表与 `exec.shell` 可用后，保留一个 `LaTeXHostServices`；同一实例服务空间、任务和手记。把既有 `PDFReadingSession`／PDFKitGate 保护预览、SwiftMath `MathImage.asImage` 作为宿主回调注入。
3. 环境变化时使对应 capability facts 失效。每次排版创建自己的 transport／授权绑定，不缓存旧 transport、grant 或 ToolContext 供新调用执行。

## 必须实现的原件与权限回调

| `LaTeXHostHooks` | 实际接法 |
| --- | --- |
| `verify` | 查真实 `RunStore`／`ConversationStore`：保存的 ordinary task、run 未结束、run/task 匹配；核对 `TaskExecutionBindingStore` 当前 generation／target 与此次 ToolContext 一致。排除 temporary/public-web；保留现有 child、scope、远程与冻结工具权限边界。 |
| `acquire` | 通过所属空间／任务／手记宿主找到原件，核查此任务对该 project 的实际读写授权，取得既有使用租约；验证 `LaTeXProject.json.id` 与原件身份；以 `LaTeXHostProject.release` 归还租约。不能把模型 UUID、文件夹、工程 owner 字段当作授权。 |
| `create` | 从真实调用来源决定 owner，使用现有创建事务／幂等身份生成工程并绑定原件。空间创建对应 LaTeX 类型，任务生成物留在任务，手记工程保留在手记附件；失败保留可恢复原件。 |
| `publish` | 通过现有 `RunOutputSnapshotStore` 发布实际 PDF／ZIP；复核源文件身份、字节数、摘要、原件租约与当前 run，返回真正的 `RunOutputFile` 引用。不要仅返回 App 私有路径或成功字符串。 |
| `didChange` | 从已提交的原件同步文件库标题／modifiedAt 与现有通知。索引失败不回滚已经完成的幂等事务；需要保留可重试的索引刷新。 |

`LaTeXShellTransport` 复用真实 `ToolEnvironmentRouting` 和 Linux `exec.shell`／jobs，携带当前 run/task/environment、call origin 与确切原始参数授权。它取得独立环境租约，保存在该次 `LaTeXHostProject` 的构建生命周期内；取消或状态不明时，不能先归还租约再声称停止。

## 原生编辑器与文件类型

空间需补齐 `PersonalContentKind`、创建／导入菜单、`PersonalContentService.create/verify`、`PersonalContentEditor`、文件操作／回收站与封面路径。可用包装目录内 `LaTeX/LaTeXProject.json` 作为空间原件；若采用独立永久存储，包装文件只能携带稳定绑定，不得成为第二份文档或执行根目录。

任务／手记保留自己的原件解析与授权，不强行通过空间单例查找。编辑器的 selection、undo、assistant 会话彼此隔离；共享的是工程与排版服务。

构造 `LaTeXEditorSession` 时传入该原件的 lease、实际服务、`formulaRenderer`、`engineCapabilities`、`typesetAction` 与服务拥有的 `operationIsActive`。原生 Typeset 按钮应沿用既有原生工作台的真实 durable run／环境／审批记录入口，捕获准确 project/revision/payload；模型调用继续走 AgentRuntime，不能伪造 native-ui 来源或仅构造一个带 grant UUID 的 ToolContext。排版运行期间可以关闭编辑器，服务继续持有原件及环境生命周期。重开时通过 `LaTeXWorkbenchOperation` 接回状态及 Stop；不共享输入、选择或撤销状态，也不再启动第二个操作。

PDF 回调必须使用现有受保护读取服务，按 `context.location` 定位同次构建；反向定位通过 `onSource(page,x,y)` 返回相对于纸张左上角的 PDF points，注意 PDFKit 页面坐标的 Y 翻转与页面边界。宏包或图片预览不能绕开项目权限与 PDFKitGate。

## 模型注册与产物

- `registerTools()` 只注册共享实现一次；加入实际可用工具检索与冻结目录，临时聊天不得暴露私有 LaTeX 工程能力。
- 工程读写目标应加入现有 typed mutation target／ordinary document edit profile，使正常任务授权覆盖普通文档编辑；保留 CAS、幂等回放与历史。
- 当前模型 `latex.typeset start` 等待实际完成，避免模型调用提前返回导致 owning run 在传输／编译前结束。原生界面仍通过服务观察运行状态；未来若增加模型非阻塞 start，必须先在准备阶段注册真实持久 run dependency，不能仅提前返回 BuildRecord。
- PDF 导出引用可交给现有 PDF 读取／页面图工具继续检查。该闭环需要实际回传文件可读、修订对应正确；版本提示和成功字符串不算检查证据。

## 完成接入的实际验收

同一份 App 中验证空间创建／导入、保存重开、任务生成工程、手记附件返回、真实模型发现与调用，以及“修改→真实 Linux 排版→读 PDF→修错→导出”；分别核对四种引擎、Biber、索引／词汇表和准备后的离线运行。失败、取消、环境删除、原件回收站和进程重启不能释放仍未确认停止的工作。

组件测试、macOS 构建、隔离原生实验和主 App／实际 Linux 证据分别记录。本接入不包含版本、签名、标签或发布授权。


## 本轮已接入的实现

- `LaTeXAppComposition` 共享 host、注册表、工具发现和现有结果发布；`LaTeXOriginalRegistry` 仅保存原件归属，不保存或授予权限。
- `LaTeXNativeRuntime` 为显式原生排版／准备事件建立真实 saved run、执行 pin 和租约，通过 `NativeWorkbenchApproval` 持久记录精确原始参数，再发行现有 runtime authority；未确认停止时保留原件和 run。
- Notes run 使用自身 scratch 的显式 Linux pin，保留既有 Notes 助手和 scope；每次原件调用以及 native grant 的前后都复核。模型不能调用原生 UI 的创建／授权入口。
- `LaTeXProjectSession` 每个编辑器独立，注入现有 PDFReadingSession／异常保护和 SwiftMath 图像；文件预览只读保存的 PDF／源码，不初始化编辑器或触发编译。
- 既有 8 项 App／授权契约已在主线实际 App 的定向测试中通过。实际 App 已验证空间与手记入口、归属、保存重开、工程 ZIP 和历史恢复；首次安装与隔离探针暴露了宿主临时路径和 guest chroot 兼容问题，原始失败保留。
- 本轮修复已通过 UIKit 组件对象编译和 12 项 worker 合成协议契约。新的 App 桥接／取消测试、恢复安装、root 模式真实隔离、App PDF／定位／返回和实际模型调用仍待主线对应产物验收；旧 worker 的独立 Linux 结果不能替代本轮摘要的资格。
