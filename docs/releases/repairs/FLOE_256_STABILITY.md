# Build 256 stability work (in progress)

## Changes

- Linux startup tools and both model prompt variants instruct the model to choose CPU/RAM from the task before its first shell call. User-selected resources take priority; the pool remains four cores total, at most three per guest.
- A successful guest launch records its granted shape in the environment directory. Cold shell starts and lifecycle restarts restore omitted dimensions after interruption.
- First multicore admission imports an existing verified image before checking its capability. Installation invalidates the pre-install status cache before the final verification.
- Python local services use the existing environment interpreter without implicitly creating a venv or running ensurepip. Startup jobs publish their starting state before activation.
- The task terminal defaults to a local workspace terminal and offers a separate Remote SSH selection.
- The pinned Impress engine no longer inserts a default freehand shape when iOS activates annotation. It waits for drawing input and keeps freehand mode active for subsequent strokes.

## Verification status

Local Swift lifecycle/service/shape tests and image migration/recovery tests passed. The Office overlay compiled for iOS 27 / arm64; its archive check verifies that only the locked members changed, including `drviewse.o` in `libsdlo.a`. Original failures and final receipts are retained privately.

Full App verification and the qualified Office host artifact pin are still pending. This record does not claim a released build, completed device drawing/save acceptance, or a confirmed crash root cause. The reported session ends with process interruption; no system crash stack was supplied. Removing implicit pip installation addresses the observed startup work, not proof of why the app exited.
