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

Environments organize dependencies, data and lifecycle. Native shell, Python and Node within the App process do not gain strong per-environment security isolation. A changed working directory, search path or mini-root is not an OS sandbox. App file operations still enforce their path and permission checks.

Package trust starts with a configured OpenPGP public key; an empty trust store must fail rather than skip verification. A matching digest establishes byte identity, not iOS compatibility. Native Linux executables are not runnable packages. Native extensions require iOS builds, source/signature and ABI qualification. See [integration status](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md) for connected paths and remaining gates.

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
