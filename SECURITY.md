# Security Policy

## Current status

Floe Agent is pre-release software. There is no supported production release. Do not use development builds to operate production systems or store production credentials.

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
- VNC sessions on public networks require an encrypted SSH tunnel.
- Downloaded or model-generated code is never executed on iOS.

These controls reduce risk but cannot make unrestricted remote shell or graphical access safe. A user who enables powerful remote access remains responsible for the selected host, credentials, backups, provider terms, and actions they approve.
