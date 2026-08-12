# Security Policy

## Current status

Floe Agent is in the planning and technical-validation phase. There is no supported production release. Do not use development builds to operate production systems or store production credentials.

## Reporting a vulnerability

Do not publish exploitable details in a public issue. Use **Security → Report a vulnerability** in the GitHub repository to open a private report, and include:

- The affected commit or version.
- The impacted component and operating environment.
- Reproduction steps or a minimal proof of concept.
- The expected and observed security boundary.
- Any evidence that credentials or remote hosts were exposed.

The project will acknowledge a complete report when a maintained release and formal response process exist. A response-time commitment is not yet offered.

## Security boundaries

The following are core security requirements:

- Model API secrets belong in Keychain and must never be written to logs or SQLite.
- SSH credentials and host keys are device-local by default.
- Unexpected SSH host-key changes fail closed.
- Model output is untrusted input and must pass schema, policy, and scope validation.
- Full-control mode requires explicit local authentication and has visible expiry.
- High-confidence catastrophic actions stop for separate user confirmation, including while full control is active.
- VNC sessions on public networks require an encrypted SSH tunnel.
- Downloaded or model-generated code is never executed on iOS.

These controls reduce risk but cannot make unrestricted remote shell or graphical access safe. A user who enables full control accepts that a model can modify or destroy data on the selected remote host.
