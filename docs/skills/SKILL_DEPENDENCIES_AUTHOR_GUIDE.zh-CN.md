# 官方 Skill 依赖声明 — 作者契约（schemaVersion 1）

读者：**经过人工审核并签名的官方 Skill Hub 包**的作者。外部（拉取/导入）Skill 继续通过现有执行工具由模型主导处理依赖：存在 `references/dependencies.json` 时仍会严格校验，但外部包绝不会触发原生自动准备。普通 `apt` / `pip` / `npm` 下载在 `exec.shell` 中依旧不受限制；本契约是小型、经审核的便捷集成，不是新的执行系统，也不是下载限制。

原生严格解码器是唯一权威：`FloeAgent/Sources/FloeSkills/SkillDependency.swift`（与已冻结的
`SkillRuntimeDependency` 描述符模式一致）。机器可读形状见
[dependencies.schema.json](dependencies.schema.json)；五个完整示例见
[examples/](examples/)。

## 声明的作用

官方包安装时，其声明会被校验并由服务持久化，并且安装边界会**真实准备无需任务环境即可
诚实准备完成的共享资源**：每条纯 `py3-none-any` wheel pin 都经既有受管 wheel 审计路径
在主机侧下载并完成哈希/大小校验（只下载——原生主机绝不执行任何包命令），其**已验证字节
持久写入共享官方 wheel 仓库**；任务首次受管安装经已映射的 `--find-links` 路径直接消费这些
字节、无需重下载（文件被淘汰或缺失时只是回退到有界索引下载——仓库是优化，绝不削弱审计）。
runtime-component 需求的制品经既有 GitHub-only 传输在钉住的发布 commit 处下载，通过
精确大小 + sha256 + 静态 ELF 门校验后原子写入首次使用会重新校验的同一应用私有组件缓存。
apt/npm/font 身份只有真实客户机的已配置源与架构下才可解析，因此显式记录
`等待任务环境` 状态。逐资源的持久状态由 `skill.read` 展示并跨视图与重启保留；
prefetch **绝不等于就绪**——不宣称命中缓存，也绝不显示"包已就绪"；无法持久写入的临时校验
只会记为等待，绝不记为已准备。任务在已解析的 Linux 客户环境中精确读取
（`skill.read`）该技能时，应用会记录绑定 `(environmentID, runID)` 的不可变计划。在该技能
携带 `"skillID"` 的已批准 `exec.shell` 调用点，Floe 会在**同一个已解析环境**中自动准备并
安装声明的资源，逐项回读校验；必需资源未就绪时，仅拒绝**该技能**的调用并给出真实原因。
没有目标环境选择器，执行绝不改道；不带 `skillID` 的命令保持原有行为（自行修复即走这条
普通路径）。

下载在共享存储（`/floe/cache`，只存下载物——安装状态永远留在任务环境自己的写层：环境
venv、`/floe/env/usr` node 前缀与每环境 dpkg 分片）中按字节去重。共享缓存淘汰永远不会破坏
安装状态；跨环境安装去重不做承诺。

## 冻结 schema（v1）

顶层键恰好为 `schemaVersion` 与 `profiles`；profile 恰好含 `id`、`target`（`os` +
`architectures`）与 `requirements`。每条需求以 `kind` 打标，且恰好携带该 kind 的键集。
**未知键一律失败关闭**：schema 中不存在 URL、命令、脚本、环境变量、registry、index、摘要、
权限或审批字段，声明永远无法生成 shell 命令、重定向下载或扩大审批。整个文件位于规范包内
`references/dependencies.json`——签名 `contentDigest` 已覆盖其字节与被引用的锁，因此审核
`.sig` 绑定已覆盖声明与锁，无需外部哈希；旧客户端仅把该文件视为惰性数据。

```json
{
  "schemaVersion": 1,
  "profiles": [
    {
      "id": "linux-guest",
      "target": { "os": "linux", "architectures": ["any"] },
      "requirements": [
        { "kind": "pip", "name": "pypdf", "version": "5.4.0",
          "purpose": "读取并合并 PDF 页面。", "required": true }
      ]
    }
  ]
}
```

kind（逐 kind 的精确键集）：

| kind | 键 | 规则 |
| --- | --- | --- |
| `pip` | `kind,name,version,purpose,required[,lockfile]` | 精确 PyPI 名；单个精确 PEP 440 版本（禁操作符/范围/URL）；可选包内锁 `references/…​.txt`，内含 wheel sha256。锁是**完整钉定闭包**的约束而非审核装饰：必须枚举声明 pin 及每一个传递依赖 wheel，每条 `name==version` 至少一个 `--hash=sha256:`（用 `pip-compile --generate-hashes` 这类 hash 模式工具生成）；操作符、裸名、多余 flag/URL、缺摘要或矛盾重复一律拒绝——绝不猜测。预取把每条被锁 wheel 的已验证字节以规范文件名持久化；安装随后让客户机自身 pip 以 `--require-hashes` 一次事务处理**整个闭包**（pip 会校验每个被处理的需求，含传递依赖）。归属范围：与客户机 venv 已**拥有**的 pin 冲突会在任何安装前拒绝，而更旧的 `--system-site-packages`（apt）继承版本从不阻塞——被审核的 pin 只在 venv 内遮蔽，APT 底座不动。无锁时保持普通精确版本安装行为。仅纯 `py3-none-any`——现有安装期审计与原生拒绝保持不变。 |
| `apt` | `kind,name,version,purpose,required` | 一个 Debian 身份 + 精确 Debian 版本（epoch、`+dfsg`、`-rev`、`+tilde` 保留为 pin 的一部分）。经客户机自身单条 `apt-get install -y --no-install-recommends name=version` 事务安装并 `dpkg` 回读。 |
| `npm` | `kind,name,version,purpose,required` | 精确 `name@version`（可带 scope），仅精确 semver。安装后真实回读安装树。包内 `package-lock.json` 只是审核证据，**绝不**重放安装，因此 npm 没有锁字段。 |
| `font` | `kind,name,version,purpose,required` | 恰好一个 Debian 字体包身份 **加精确 Debian 版本**（与 `apt` 同一 pin 类；当前 `fonts-noto-cjk 1:20240730+repack1-1`）。v1 无免版本例外：身份+版本一起安装并一起回读，就绪门是固定的客户机 CJK **字形渲染**探测——用客户机自身的标准库 Python ctypes 调用 FreeType（`FT_Init_FreeType`、对冻结 Noto TTC 路径 `FT_New_Face`、对中文与日文各一个码点取得非零 `FT_Get_Char_Index`、`FT_Set_Pixel_Sizes` 32 px、`FT_LOAD_RENDER` 的 `FT_Load_Char`，随后释放）：它证明真实渲染器加字体能把 CJK 文本光栅化——缺渲染器或缺字体诚实回答未就绪，且不声称任何成品文档的视觉质量。请像 CJK 示例那样同时声明 `fontconfig`（它带出 Debian 提供的 FreeType 库）。 |
| `runtimeComponent` | `kind,componentDescriptorPath,purpose,required` | `componentDescriptorPath` 必须恰为 `references/engine-dependency.json`。身份、版本、制品摘要与大小只来自被钉住描述符，经既有的受管运行时组件白名单（当前恰为 `impeccable-engine`）。白名单、仅适用于该组件的 16 MiB 上限与非阻塞组件钩子**不会**因此契约扩大；需求条目不携带自身 name/version/摘要。 |

`purpose` 为 1–200 字节的简短、模型安全文本，经 `skill.read` 展示。`required` 为布尔：
`true` 门控该技能感知依赖的调用；`false` 继续执行并附带可见注解。

限制：文件 ≤64 KiB；1–8 个 profile；每 profile 1–32 条需求；profile id 唯一；profile 内
`(kind,name)` 唯一；`os` 恰为 `"linux"`；`architectures` ⊆ `{riscv64, arm64, x86_64, any}`。

`target.architectures` 是**选择**契约，不是文档注释：供给会把每个 profile 与实际本地 Linux
后端的架构匹配（被钉住的客户机是 `riscv64`），只有匹配或声明 `any` 的 profile 会进入计划、
预取或安装。没有任何匹配 profile 的声明会诚实失败且什么都不安装；两个匹配 profile 把同一
`(kind,name)` 钉到不同精确版本属于矛盾，会在任何事务之前被拒绝，而匹配 profile 间完全相同的
精确 pin 只是复用。若当前 Floe 只有 riscv64 客户机，`arm64`-only 的 profile 永远不会被本构建
安装——请声明真正会运行的架构（`any` 或客户机真实架构），只有对应后端存在时才增加按架构划分的
profile。

## 版本管理（冻结区分）

只有四个版本概念。不得发明第五个，也不得再加一个用户可见的版本计数器：
**现有 Skill 包的 `id`/`version` 仍是唯一包权威。**

1. **Skill 包版本** —— `floe.json` 的 `id` + `version`（语义化版本）。已发布字节不可变：
   规范 `contentDigest` 覆盖包内每个文件，包括 `references/dependencies.json`、其锁与组件
   描述符。脚本、依赖声明或权限的任何变化都要求**新的包版本与新的签名摘要**；绝不以相同
   版本替换已发布字节。同 id/同版本/字节不符的包会针对已审核摘要失败关闭（回执身份/冲突），
   而非静默通过。
   **发布者 CI 必须拒绝**以不同 `contentDigest` 复用既有 Skill `id`+`version` 的任何
   发布，即使发布者能为新字节产生有效的新签名——客户端回执摘要只能把字节对照**当前**
   签名回执校验，无法证明历史发布的不可变性，所以该规则必须在发布边界强制执行。作为对
   本机**已观察到**的发布身份的客户端第二道防线，每次官方 curated 提交还会持久记录发布
   身份（id + version + contentDigest + publication commit）；之后携带同 id+version 但
   摘要不同的 curated 安装或更新会失败关闭（"发布身份冲突"）。保留的身份不替换字节，也
   不为本客户端从未观察到的历史提供证明——发布方 CI 对该场景仍属强制。
2. **`dependencies.json` 的 `schemaVersion`** —— 仅用于解析器兼容。当前构建恰好接受 `1`。
   未知更高值会使准备通道兼容性失败（必需资源以真实原因报告为未就绪），而不是猜测；读取、
   暂存与技能其余功能不受影响。
3. **精确资源/依赖版本与锁** —— 每条需求的 `version` pin（pip、apt、npm **以及
   font**：字体需求是精确 apt 身份+版本 pin，回读回执逐字记录该版本），pip 另有被引用
   锁中的 wheel `sha256`，运行时组件另有被钉住描述符自身的 `componentVersion`/制品摘要。
   安装与回读只认这些——绝不装范围、绝不 `latest`、绝不隐式升级、绝不静默降级（同环境
   已存在不同版本的冲突会被诚实拒绝）。
4. **`minimumAppVersion`** —— 既有的旧客户端门。需要新原生行为的声明所对应的 curated hub
   条目，把其现有 `minimumAppVersion` 提升到首个具备能力的构建（候选 `1.7.60`）；旧客户端
   照旧得到未改变的 `.incompatibleApp` 报价状态且永远无法安装。被钉住组件描述符自身的
   `minimumAppVersion` 门保持不变。

### 就绪回执绑定内容

每份回执共同绑定、且每次使用都会重新校验：**包版本**、包 **contentDigest**、
**dependencyManifestDigest**（`dependencies.json` 精确字节的 SHA-256）、profile id 与需求
身份（kind、name、精确版本）、已解析**环境**以及客户机**启动代**。仅当以上事实全部仍然
一致且安装授权重新有效时回执才可复用；重启轮换、禁用、卸载、编辑或收回授权都会使其失效
（重新授权/重新检查——序列化副本永远不是就绪令牌）。

### 升级、回滚与进行中的调用

- **升级**安装新的不可变包版本与新签名摘要；计划与回执都从新精确字节重新记录。不存在
  同版本依赖刷新，也不合并声明字节。
- **回滚**恢复先前不可变的包 + 描述符配对。若当前环境无法满足回滚后的 pin（例如已安装
  更新版 pip wheel 而旧 pin 与之冲突），Floe 会逐条如实报告——绝不自动删除 apt/pip/npm
  包；环境包移除始终是在没有其他已安装技能仍需要该精确 spec 时，由用户在环境包 UI 中的
  显式操作。
- **进行中的调用**钉住其运行记录计划时的包版本 + 依赖描述符：运行中途落地的安装或升级
  不能替换活动运行已校验过的字节；延迟的重新校验会失败关闭，运行必须重新读取才能继续。
- **卸载技能只移除所有权记录**——声明的安装包原样留在环境中（不自动 `apt`/`pip`/`npm`
  删除）。

## 编写规则

- pin 必须对准客户机镜像实际服务的 Debian 发行版。运行时始终使用作者的精确 pin，
  pin 无法满足时诚实失败——绝不替换成"差不多"的版本。本文示例 pin 已对照实时
  `packages.debian.org`/`sources.debian.org` trixie 元数据核验
  （`python3-scipy 1.15.3-1`、`python3-matplotlib 3.10.1+dfsg1-4`、
  `poppler-utils 25.03.0-5+deb13u4`、`fontconfig 2.15.0-2.3`、
  `fonts-noto-cjk 1:20240730+repack1-1`）。
- 只声明技能真正需要的内容；优先复用已审核配方或环境已有之物（精确 pin 并注明），用纯
  wheel、Debian apt 二进制与一个小型可选 CJK 字体，而不是重量级预装扩展。不加新基础镜像，
  不加重量级科学栈。
- 不放假哈希，不在包内放大体积二进制或 wheel 实体：锁只列摘要；wheel 本体在首次使用时
  经共享缓存下载（官方安装在首次使用时可把已审计字节以真实规范的 PEP 427 文件名持久化进
  共享 wheel 存储，客户机 `--find-links` 的 pip 因此能真正消费它）。
- 保持既有上限：本契约绝不扩大普通 Skill 包工件限制（单文件 2 MiB、整包 8 MiB）——唯一
  扩大的上限仍是现有显式白名单运行时组件自身的界限。
- 把文件放在 `references/` 下，`schemaVersion` 钉为 `1`，提升**包版本**，重新签名摘要，
  交由正常审核发布流程携带。

## 完整示例

**没有依赖的技能根本不携带 `dependencies.json`。** 不要伪造空声明（零 profile
或空 `requirements` 数组都无效且失败关闭）；纯指导/纯脚本包对新旧客户端保持完全
一致的无 sidecar 行为。

| 文件 | 演示 |
| --- | --- |
| [examples/dependencies.minimal.json](examples/dependencies.minimal.json) | 最小信封：一个必需精确 pip pin |
| [examples/dependencies.purepip.json](examples/dependencies.purepip.json) | 多个纯 `py3-none-any` pin 共享一个包内 wheel 锁 |
| [examples/dependencies.debian.json](examples/dependencies.debian.json) | Debian apt 身份 + 精确版本，经客户机自身单事务安装 |
| [examples/dependencies.npm.json](examples/dependencies.npm.json) | 精确 `name@version` npm pin（锁字节是审核证据，绝不重放） |
| [examples/dependencies.cjk.json](examples/dependencies.cjk.json) | Debian 科学栈 pin（`python3-matplotlib`、`fontconfig`）+ 可选字体精确身份+版本 pin 与固定 CJK 字形渲染探测 |

`runtimeComponent` 需求形如：

```json
{ "kind": "runtimeComponent",
  "componentDescriptorPath": "references/engine-dependency.json",
  "purpose": "Impeccable snapshot engine.", "required": true }
```

且只能与已冻结、已入白名单的描述符及其既有受管部署路径配合使用。

## 模型如何调用带依赖的技能

对装有声明的官方技能执行精确 `skill.read`，会报告 profile、每条需求（kind、精确 pin、
必需/可选）与调用契约：在同一任务运行内对 `exec.shell` 传 `"skillID": "<skill id>"`。
携带 `skillID` 时，该运行会校验安装记录、当前运行绑定与授权，自动在任务的已解析 Linux
环境中准备/安装声明资源并回读。必需资源未就绪只拒绝**该技能**的调用并给出真实原因；
可选缺口以可见注解出现；不带 `skillID` 的命令行为完全不变，普通修复即走此路径。

## 范围与不做承诺

- 自动准备仅适用于官方已审核/已签名的 Hub 安装。
- 不对外部不可信安装指令做通用原生自动执行。
- 无新执行别名、无新包安装工具、无环境选择器。
- 不承诺跨环境物理去重（dpkg 分片与 venv 按设计每环境一份）；共享存储只去重下载。
- `fonts-noto-cjk` 与 apt python 闭包的安装体积以真实客户机日志在资质验证时测量；本契约
  不做声明。
