# Security Policy

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
