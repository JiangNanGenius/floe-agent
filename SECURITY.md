# Security Policy

> **Scope note (2026-09-12):** Floe 1.6.7 adds the local shell substrate
> (`exec.shell`, `shell.*`), the apt/pkg capability catalog, data-only `.deb`
> extraction and sandboxed WASM command packages. Every one of these paths is
> approval-gated and documented in
> [docs/ARCHITECTURE_LOCAL_SHELL.md](docs/ARCHITECTURE_LOCAL_SHELL.md); the
> explicitly approved relaxations (mini-root-wide read access for external
> commands, coarse per-command risk) are listed there. The bundled Python
> package path, fingerprint rules and no-native-ELF boundary are unchanged.

## Floe 1.7 环境与软件包边界 / Environment and package boundary

环境用于依赖、数据和生命周期分层；同进程原生 shell、Python 和 Node 不具备每环境的强安全隔离。改变 cwd、搜索路径或 mini-root 不等于 OS 沙箱。应用自身的文件访问继续进行路径与权限检查。

软件包签名链须从配置的可信 OpenPGP 公钥开始；缺少公钥必须失败，不能自动跳过。下载摘要一致只证明字节一致，不证明包适配 iOS。普通 Linux 原生二进制不属于可运行包；原生扩展需要预构建、来源/签名与 ABI 验证。当前完整接入状态见[实施记录](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md)。

Environments organize dependencies, data and lifecycle; they are not strong security isolation for native code within the App process. Package and model readiness requires verified trust, compatibility and execution, not just a successful download.

## Current status

Floe Agent publishes prerelease builds for evaluation. They are not a supported production service, and the community unsigned IPA is not an App Store package. Do not use development or unsigned builds to operate production systems or store production credentials. [简体中文安全策略](SECURITY.zh-CN.md)

## Reporting a vulnerability

Do not publish exploitable details in a public issue. Open the repository's **Security** tab and choose **Report a vulnerability** to submit a private GitHub security advisory.

Please include:

- the affected commit or branch;
- the impacted component and operating environment;
- reproduction steps or a minimal proof of concept;
- the expected and observed security boundary; and
- any evidence that credentials, private data, or remote hosts were exposed.

The project does not yet offer a formal response-time commitment. Please keep the report private until the issue has been investigated and a coordinated disclosure plan has been agreed.

## Security boundaries

The following are core requirements:

- Model API secrets belong in Keychain and must never be written to logs or SQLite.
- SSH credentials and host keys are device-local by default.
- Unexpected SSH host-key changes fail closed.
- Model output is untrusted input and must pass schema, policy, and scope validation.
- Full-control mode requires explicit local authentication and has visible expiry.
- High-confidence catastrophic actions stop for separate user confirmation, including while full control is active.
- SSH-tunneled VNC is the safe default. Direct VNC is an explicit legacy-network option; Floe warns before use and keeps its password in Keychain.
- Arbitrary downloaded or model-generated code is never executed on iOS. An installed skill may bundle pure-Python scripts only after one-time package audit; later reuse is bound to the same immutable content fingerprint and scope.
- Visible browser references are document-scoped, and sensitive login/upload/payment flows require explicit user review or takeover.
- Skill packages are statically validated and cannot dynamically register native runners or grant themselves authority. Bundled pure-Python helpers remain sandboxed and do not inherit remote, credential, or filesystem authority.

These controls reduce risk but cannot make unrestricted remote shell or graphical access safe. A user who enables powerful remote access remains responsible for the selected host, credentials, backups, provider terms, and actions they approve.
