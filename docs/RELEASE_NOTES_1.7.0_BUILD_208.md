# Floe 1.7.0 build 208 — internal device candidate

This candidate collects the September 20 feedback code. It includes the first
Office/IDE/Git/mind-map/Shell repair slice from build 207 plus bounded local-model
recovery, cross-task history pagination and final-response continuation, and
separate Linux/Python/Node/WASM package entry points.

TinyEMU host integration now connects environment-owned Shell, local Python,
interactive terminals and background services. A Linux environment uses one
persistent Python venv with access to distro site-packages. Guest services use
owned process groups, shared logs and port forwarding. The actual guest runner
and image import/verification code are included in the source.

No qualified Linux image is offered for download yet. The current candidate
boots real Shell/process primitives, but APT HTTPS fails with SIGILL and its
complete distribution source record is unfinished. Native execution remains the
default; the Linux download list is not proof those packages run on the device.
See [backend status](FLOE_LINUX_GUEST_BACKEND.md) and
[image provenance](FLOE_LINUX_GUEST_IMAGE_MANIFEST.md).

## Focused verification and remaining acceptance

- Native mind-map model/layout: 9 cases and FloeNotes object compilation.
- Existing Shell: 71 bridge and 18 SessionIO checks.
- Cross-task pagination: 40 focused assertions; local prompt budgeting: 23.
- Linux host consumers: 34 checks with real guest-runner process exchanges;
  guest protocol harness: 66 assertions. These ran natively, not inside iOS.
- Linux Swift module slices passed Swift 6 object compilation. App changes
  still require this candidate's accepted-SDK cloud build.
- No simulator/UI regression is requested. The user performs physical iPad
  acceptance, including the reported crashes; no current device crash stack
  was available to establish every physical root cause.

The release workflow must retain the unsigned IPA and matching private symbols
before signing, then record upload acceptance separately from Apple processing
and Floe QA availability. This document alone is not an upload or availability
claim. Production distribution is outside this task.
