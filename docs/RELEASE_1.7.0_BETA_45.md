# Floe1.7.0 build188 — candidate beta45

Tag `v1.7.0-beta.45` fixes source `c5656276a3fed0cc0546d2ab360603e443b7f87e`.
[Cloud run35317532109](https://github.com/JiangNanGenius/floe-agent/actions/runs/35317532109) has failed its SDK27 full-App Notes UI gate; remaining accepted-SDK evidence is still being collected.

This candidate follows blocked build187. It retains durable IDE GitHub CI jobs:
submission is persisted before network dispatch; App launch/foreground recovers
known jobs and polls their remote states with bounded backoff, without requiring
the model to sleep. Cancel requests remain pending until remote confirmation.

The new Notes changes publish actual cover state directly on the file card, avoiding
a second whole-App accessibility query into the thumbnail child. Word/Excel/PPT
still require real system content or an explicitly labelled content summary; icon
fallback is not accepted as content. Source/revision and rename/reopen checks remain.
Mind-map component screenshots have a bounded callback wait and retain failure
diagnostics instead of hanging beyond XCTest's execution allowance.

[Preflight and original failures](qualification/build188-release/README.md).
No full-App UI pass, signed IPA, upload, or installable TestFlight is claimed yet.
Device-only Office/MLX/Pencil checks retain their recorded physical-device limits.
GitHub prerelease, Feather, publicBeta submission and internal TestFlight are
separate stages; this source document is not evidence that any was published.
