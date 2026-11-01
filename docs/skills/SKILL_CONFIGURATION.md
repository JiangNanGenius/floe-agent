# Skill configuration / 技能配置

Implementation reference for the new native configuration path. App integration,
UI behavior and release availability must be qualified separately. See also
[local iOS automation](IOS_AUTOMATION_INTEGRATION.md).

本文件说明新增原生配置路径。App 集成、界面行为和发布可用性仍需分别验收。
另见[本机 iOS 自动化](IOS_AUTOMATION_INTEGRATION.md)。

## English

Open Skills → Installed → a Skill → Configuration. Ordinary parameters, secret
fields and supported native connections share this page. A Skill that only
mentions environment variables in its instructions can use “Add environment
variable”; this adds a local declaration and leaves the upstream package intact.
Connection components come from the compiled app, not arbitrary Skill content.

The assistant uses `skill.config`: inspect requirements, save ordinary values,
bind a one-time secret or an explicitly selected credential, validate supported
connections, then resume the task. `declare` and `remove-field` manage local ENV
fields. Users may provide a password in chat to their selected model; secure
entry is an alternative. Derived tool arguments and receipts use opaque
credential references. A reference is checked against its actual task and use;
knowing an ID does not permit reading another Skill’s connection key.

Run a configured script with `exec.shell` and its `skillID`; interactive work
uses `shell.open` with the same selection. The native service verifies the
installed revision, task grant and actual execution target before resolving any
secret. Configured values cannot be replaced through a tool’s `env` argument.
Secrets travel only in the selected process environment, not a generated
command, script, workspace `.env` file or the Floe process environment. Interactive
sessions recheck configuration before further input and close if access changes.
Outputs are redacted before their persistent receipt/output paths.

Linux requires a verified runner advertising `env=1`. Mac requires the companion’s
authenticated `sensitiveEnvironmentV1` capability. Unsupported targets report an
update/setup requirement before sending secrets. There is no inline-export
fallback. A process authorized to receive a secret can use it; output redaction
is not a sandbox against encoding or transferring that secret.

Configuration belongs to the trusted installation source, Skill, profile and
actual target. Compatible updates from the same source retain it. A publisher,
source or target change does not silently inherit old credentials. Sharing a
credential requires explicit selection; deleting one binding preserves other
users of that credential. Uninstall retains configuration by default. The
explicit cleanup option removes the selected profile after uninstall, with
retryable credential deletion. It never removes a separate companion app or its
developer pairing records. Local iOS pairing keys stay device-bound.

Mac Bridge is the same-Mac execution backend and is unavailable on physical
iPhone/iPad. iOS Bridge is an optional native automation connection supplied by
an on-demand Skill; it never becomes a shell backend or a permanent main
Settings item. Installing, pairing and actually reaching a ready engine are
separate states.

## 简体中文

入口为“技能 → 已安装 → 某个技能 → 配置”。普通参数、密钥和受支持的原生连接共用
此页。只在说明里提到环境变量的旧技能，也可以“添加环境变量”；声明保存在本机，
不会修改上游安装包。连接组件由 App 提供，技能文本不能创建任意原生组件。

模型通过 `skill.config` 检查缺失项、保存普通值、绑定一次性密钥或明确选定的已有
凭据、验证连接，再继续任务。`declare` 和 `remove-field` 管理本机 ENV 声明。
用户可以在聊天中向自己选择的模型提供密码，也可使用安全输入。派生工具参数和
执行回执使用凭据引用；引用仍需核对真实任务和用途，不能仅凭 ID 读取其他技能的连接密钥。

脚本通过 `exec.shell` 的 `skillID` 选择配置，交互程序通过 `shell.open` 使用相同选择。
原生服务先核验已安装修订、任务授权和实际执行目标，再读取密钥。工具的 `env` 参数不能
覆盖已配置的值。密钥只传入选定进程的环境，不写进命令、脚本、工作区 `.env` 或 Floe
主进程环境。继续向交互终端输入前会重新核验配置，授权失效则关闭会话；持久化输出和
回执经过脱敏。

Linux 需要经过验证且声明 `env=1` 的 runner，Mac 需要伴随程序经过认证的
`sensitiveEnvironmentV1` 能力。不支持的目标会在发送密钥前提示升级或完成设置，
不会改用命令内 `export`。获准接收密钥的进程能够使用密钥；输出脱敏不是阻止编码或
传输密钥的沙盒。

配置绑定受信任来源、技能、配置档案和实际目标。同源兼容更新沿用配置；发布者、来源
或目标改变时不会直接继承旧密钥。共享凭据需要明确选择，删除一个绑定不会删除其他
配置仍在使用的凭据。卸载默认保留配置；明确选择清理时，先卸载再清理选定档案，并
保留凭据删除的重试路径。不会删除独立伴随 App 或其开发配对资料。本机 iOS 配对密钥
始终绑定当前设备。

Mac Bridge 是同一台 Mac 上的执行后端，真实 iPhone/iPad 不提供入口。iOS Bridge 是
通过按需技能使用的原生自动化连接，不是 shell 后端，也不常驻普通设置首页。
安装完成、已配对和引擎实际就绪分别显示。
