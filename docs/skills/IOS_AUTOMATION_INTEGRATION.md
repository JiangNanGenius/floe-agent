# Local iOS automation Skill / 本机 iOS 自动化 Skill

Status: **source candidate only.** The package is not bundled with Floe, is not
in the signed Skill Hub catalog, and is not installable from the App yet. A
capable Floe build, a signed Hub publication and the release owner's verified
`minimumAppVersion` are still required. Nothing here is a claim of App, runtime,
Hub, physical-device or companion availability.

状态：**仅为源码候选。** 该包未随 Floe 内置，未进入签名 Skill Hub 目录，也尚不能从
App 安装。仍需具备相应能力的 Floe 构建、签名发布，以及发布负责人核验的
`minimumAppVersion`。本文不构成 App、运行时、Hub、真机或配套应用可用的声明。

## English

### What it is

`floe-ios-automation` is an optional, on-demand Skill for observing and
controlling the **current physical iPhone or iPad** through the separate
self-signed **Floe iOS Bridge** companion on the same device. It is not a Mac
bridge, not an SSH/remote-execution backend and not a shell. Its package has no
scripts, Python, WASM or native payloads: `scriptRuntime` is `none` and it
declares no execution dependency.

The source lives at `skill-hub/optional/floe-ios-automation/` in the App
repository. It is deliberately outside the four reserved bundled official
sources and outside the App's `skill-hub/catalog.json`/`catalog.sig`.

### Package contract

| Item | Value |
| --- | --- |
| Skill ID | `floe-ios-automation` |
| Platforms | `ios` |
| Capabilities | `credentials`, `device.observe`, `device.interact` |
| Tools | none (the tools are native App registrations, not shell tools) |
| Script runtime | `none` |
| Configuration field | `bridge`, kind `connection`, connectionKind `ios.bridge.local`, required |
| Native profile / target | `default` / `local-ios` |
| Pairing storage | Shared scoped, device-bound Skill connection credential; opaque payload only, no secret or credential URL in the package |

The `bridge` field is filled by a real native pairing after the owner approves
inside Bridge. It is not a typed token, and the Skill package never contains a
key, token or credential reference.

### Build and publication prerequisites

A candidate alone is not an available Skill. The release owner must:

1. Package the source through the curated Skill Hub, including a registry entry,
   a signed review record, the immutable archive and the complete signed feed.
2. Extend the Hub manifest/registry contract to accept the native
   `configuration` block and the native `device.observe`/`device.interact`
   capability names. Do not weaken trust, signature or review checks to make
   the candidate pass.
3. Set `minimumAppVersion` from an actually verified capable App identity. The
   value is intentionally absent/unset in this source candidate; do not invent a
   floor or advertise the candidate as published.
4. Review the exact capabilities, action surface, companion prerequisite and
   failure behavior before offering an install action.

The App's native tool availability already distinguishes:

- installed and enabled → `ios.bridge.status`, and `ios.bridge.pair` when grants,
  source state and the connection field are usable;
- a current validated connection that is actually ready → `ios.bridge.observe`
  and `ios.bridge.control`.

`configured` is not `ready`. A saved field, a reachable port or a previous
successful turn is not proof of readiness.

### User flow

1. Install the Floe iOS Bridge companion on the same iPhone/iPad. Check the official
   release centre at https://www.floe-agent.com/releases?platform=ios-bridge for the
   available package and its qualification scope. The official IPA is unsigned:
   the user signs it with their own Apple developer material, installs it,
   completes the one-time developer setup and starts the service.
   Floe cannot install, sign, start or approve Bridge.
2. Install and enable this optional Skill; review its three capabilities.
3. Pair from the Skill configuration page or `ios.bridge.pair`. Bridge shows a
   native owner confirmation. The user approves there; no chat message, model
   argument or URL can approve it.
4. Check `ios.bridge.status`. Use observe actions to read the screen, then
   control actions only for the user's intended change.
5. For control, one task owns device input until it finishes, is cancelled, is
   suspended or its bounded window expires. Mutations are never retried
   automatically. After a failure, cancellation, fence or unknown outcome,
   observe the screen before deciding what to do.
6. Bridge can be stopped or revoked at any time. A pairing expires after 30
   days without use. The user can pair again with a new native approval.

### Safety boundaries

- `collect` and `scroll_to_element` are **mutating**, even if an external schema
  labels them as reads. They page or scroll the live UI.
- `type.text` is not echoed. A credential reference may be used only as the
  entire text value for an authorized local control call; embedded placeholders
  are refused.
- Floe and Bridge authorization surfaces are protected. Automation cannot read
  the Bridge management screen, control Floe or Bridge, or open the `floe` and
  `floe-ios-bridge` schemes.
- System passcodes, device unlock authentication and third-party password
  prompts remain manual. This Skill does not bypass them.
- Pairing and control require a normal writable task; a temporary or read-only
  task cannot perform them.

### Companion open/return handoff

The published standalone Bridge 1.0 source at commit `3aed1496` has no URL
scheme. A minimal additive companion patch can register `floe-ios-bridge://open`
and bring Bridge forward so the existing native approval card is visible. It
must not approve, accept a key/token, or change the privacy prompt. Until both
the companion patch and a Floe build that configures its optional open URL are
present, opening Bridge remains a manual step.

The current App path has no incoming `floe-ios-bridge` return route and no
automatic navigation back to the pairing page. Do not claim automatic return.
The outstanding pairing request is owned by the Floe task and completes when
the owner decides in Bridge; the user can return manually and check status. Any
future automatic return must be an explicit App-owned route bound to that
pending request, with no secret in the URL.

### What not to claim

- Do not describe this as a Mac bridge, a LAN server, a remote-device service
  or a generic shell.
- Do not say the Skill is bundled, published, signed, installed or available
  before the actual feed, review and App build exist.
- Do not say Bridge 1.0 has an open/return URL scheme or that Floe can
  automatically return from Bridge in the current build.
- Do not claim a physical-device or real-Bridge acceptance result from source
  checks alone.

## 简体中文

### 这是什么

`floe-ios-automation` 是按需安装的可选 Skill，通过同一台设备上单独签名安装的
**Floe iOS Bridge** 配套应用，观察和控制**当前真实 iPhone 或 iPad**。它不是 Mac
桥接、不是 SSH/远程执行后端，也不是 shell。包内没有脚本、Python、WASM 或原生
载荷：`scriptRuntime` 为 `none`，不声明执行依赖。

源码位于 App 仓库的 `skill-hub/optional/floe-ios-automation/`，刻意不加入四个
保留的内置官方来源，也不进入 App 的 `skill-hub/catalog.json`/`catalog.sig`。

### 包契约

| 项目 | 值 |
| --- | --- |
| Skill ID | `floe-ios-automation` |
| 平台 | `ios` |
| 能力 | `credentials`、`device.observe`、`device.interact` |
| 工具 | 无（工具是 App 原生注册，不是 shell 工具） |
| 脚本运行时 | `none` |
| 配置字段 | `bridge`，kind `connection`，connectionKind `ios.bridge.local`，必填 |
| 原生 profile / target | `default` / `local-ios` |
| 配对存储 | 共享的、设备绑定的 Skill connection 凭据；只保存不透明载荷，包内没有密钥或凭据 URL |

`bridge` 字段由用户在 Bridge 中批准后的一次真实原生配对填入；它不是让用户手输的
token，Skill 包永远不会包含密钥、token 或凭据引用。

### 构建与发布前置条件

候选源码本身不等于可用 Skill。发布负责人必须：

1. 通过受审核的 Skill Hub 打包，包括 registry 条目、签名审核记录、不可变归档和
   完整的签名目录。
2. 扩展 Hub 的 manifest/registry 契约，使其接受原生 `configuration` 块和
   `device.observe`/`device.interact` 能力名。不得为了通过候选而削弱信任、签名或
   审核检查。
3. 从实际验证通过且具备能力的 App 身份填写 `minimumAppVersion`。本源码候选刻意
   不设置该值；不得臆造最低版本，也不得把候选宣传为已发布。
4. 在提供安装入口前，审核能力、动作面、配套应用前置条件和失败行为。

App 原生工具可用性已经区分：

- 已安装并启用 → `ios.bridge.status`；当授权、来源状态和连接字段都可用时 →
  `ios.bridge.pair`；
- 当前连接已通过真实验证且确实 ready → `ios.bridge.observe` 和
  `ios.bridge.control`。

`configured` 不是 `ready`。已保存字段、端口可连或上一轮成功都不能证明当前可用。

### 用户流程

1. 在同一台 iPhone/iPad 上安装 Floe iOS Bridge。请从官方发布中心
   https://www.floe-agent.com/releases?platform=ios-bridge 查看当前包及其资格范围。官方 IPA 未签名：用户自行使用
   Apple 开发者材料签名、安装，完成一次性开发者设置并启动服务。Floe 不能代装、
   代签、代启动或代批准 Bridge。
2. 安装并启用本可选 Skill，确认三项能力授权。
3. 在 Skill 配置页或通过 `ios.bridge.pair` 配对。Bridge 会显示原生确认，必须由
   用户亲自批准；聊天消息、模型参数或 URL 都不能代替批准。
4. 检查 `ios.bridge.status`。先用 observe 动作读取屏幕，仅在用户明确需要改变时
   使用 control 动作。
5. 控制期间一个任务持有设备输入，直到任务完成、取消、挂起或受限窗口过期。变更
   不会自动重试；失败、取消、fenced 或结果未知后，先观察屏幕再决定下一步。
6. 用户可随时在 Bridge 中停止或撤销。配对在 30 天未使用后过期；重新配对需要新的
   原生批准。

### 安全边界

- `collect` 和 `scroll_to_element` 属于**变更**操作，即使外部 schema 把它们标为
  读取；它们会翻页或滚动真实界面。
- `type.text` 不会回显。凭据引用只能作为整个文本值用于已授权的本机控制调用；
  嵌入的占位符会被拒绝。
- Floe 和 Bridge 的授权界面受保护：不能读取 Bridge 管理界面，不能控制 Floe 或
  Bridge，也不能打开 `floe`/`floe-ios-bridge` 链接。
- 系统密码、设备解锁认证和第三方密码输入仍需人工完成；本 Skill 不绕过它们。
- 配对和控制需要普通可写任务；临时或只读任务不能执行这些操作。

### 配套应用打开/返回交接

已发布的独立 Bridge 1.0 源码（提交 `3aed1496`）没有 URL scheme。最小增量补丁可以
注册 `floe-ios-bridge://open` 并让 Bridge 进入前台，露出已有的原生批准卡片；它不得
自动批准、接收密钥/token 或改变隐私提示。在配套补丁和配置了可选打开 URL 的 Floe
构建都到位之前，打开 Bridge 仍需手动操作。

当前 App 路径没有入站的 `floe-ios-bridge` 返回路由，也没有自动回到配对页的导航。
不要宣称自动返回。未完成的配对请求由 Floe 任务持有；用户在 Bridge 中决定后，手动
返回 Floe 并检查状态即可。未来若要自动返回，必须是 App 明确拥有的路由，并绑定到
该待处理请求，URL 中不得包含任何密钥。

### 不要这样宣称

- 不要把它说成 Mac 桥接、LAN 服务器、远程设备服务或通用 shell。
- 在真实目录、审核和 App 构建存在之前，不要说该 Skill 已内置、已发布、已签名、
  已安装或已可用。
- 不要说 Bridge 1.0 有打开/返回 URL scheme，也不要说当前构建能从 Bridge 自动返回。
- 不要仅凭源码检查声称已完成真机或真实 Bridge 验收。
