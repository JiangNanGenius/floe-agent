# Floe 1.7.0 (214) — TinyEMU and feedback repairs

Status: available in internal Floe QA TestFlight. Apple VALID, unexpired and
IN_BETA_TESTING verified at 2026-09-20T21:32:34Z.
[Source, artifacts, upload and limits](qualification/build214-release/README.md).

This delivery makes Linux the default local environment and archives the native
Python/Node runtimes outside the App payload. Shell, direct Python and services
use the selected guest; apt/dpkg, pip/venv, node/npm and WASM keep separate
responsibilities. A runner-only component update must preserve existing guest
disks and packages.

The complete repair scope and evidence are tracked in
[FLOE_PHASE2_2026_09_21.md](FLOE_PHASE2_2026_09_21.md). It includes concurrent
commands and terminals, cancellation/recovery, per-VM networking, Git discovery
and refresh, local-model prefill/compaction, cross-task lookup, Notes grants and
tool selection, native mindmap controls/dragging, Office recovery and Chinese
font metadata, and IDE document layout/workspace ownership.

Only focused checks and the cloud App build are required for this expedited
internal TestFlight. Physical-device acceptance belongs to the user. In
particular, Git and local-model crash changes are targeted mitigations pending
device confirmation; Office recovery/font metadata tests do not prove actual
engine rendering. Real SSH/SCP transfers and iPad performance remain manual
acceptance items.

The interpreter uses no host JIT; this does not establish App Review approval.
Engine and guest licenses remain separate, with corresponding sources and
notices delivered with the Linux component. No production App Store or public
App release is included.

The App source is `33759e44` / `v1.7.0-beta.71`. Packaging-only recovery
`c4dddb79` reused the saved IPA, removed an accidentally embedded SDK link stub,
then re-signed and uploaded without rebuilding. Full evidence is linked above.
