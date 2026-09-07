# Skill routing and upgrade work / 技能路由与升级实施

Accepted plan baseline: 1d63b74, 1.4.96 (127). Python and Executor are independent substrates; interactive shells belong to Terminal. Visible PDF/Office/Network skills support explicit GitHub-file/package upgrades; hidden guides are app-owned read-only resources. No public beta.

- [x] Canonical IDs, validated seeding, truthful guides and read lifecycle.
- [x] Role-based discovery, read-to-tool activation and bounded context.
- [x] Python dependency/integrity checks without global skill authority pollution.
- [x] GitHub immutable source snapshots, review, atomic upgrade and rollback.
- [x] Source/version/local-revision protection and update UI.
- [x] SSH ownership, bounded cleanup and independent Executor lifecycle.
- [x] Local SwiftPM: 959 core tests plus 12 JavaScript engine and 12 JavaScript tool tests; real guardian PTY 4 and cancellation 5 tests. Staged and history secret scans passed.
- [x] Final iPad Simulator: 94 tests across all 8 app regression suites passed, including permission-preserving rollback and interrupted recovery. Final delta: 178 SwiftPM tests passed.
- [ ] Cloud CI, bilingual release and internal TestFlight VALID/group evidence.

Rollback journals retain complete permission decisions/scopes/expiry and recover both interrupted installation and interrupted rollback. Running-task execution digests are separate from current editing digests. RFB wire tests use real sockets, input and screenshots with a task-local empty OCR fixture: they do not claim Apple OCR accuracy or physical desktop acceptance. An earlier real-OCR test outlived its bounded caller and crashed in Apple's model compiler during process teardown; OCR/device acceptance remains separate.

Public beta remains closed. Physical iPad checks and live private-GitHub connector/remote-host acceptance are not replaced by local fixtures or CI. Run-snapshot retention/garbage collection is a future storage optimization, not an automatic deletion of resumable tasks.

Do not mark these complete merely because a file exists or a build compiles.
