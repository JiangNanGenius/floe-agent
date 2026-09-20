# Floe 1.7.0 (214) — TinyEMU and feedback repairs

Status: source integration complete; Linux component published; App build next.
No Build214 upload or installability claimed yet.

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

Source tag, cloud run, retained IPA/symbols, upload and Floe QA availability
will be recorded after the corresponding steps complete.
