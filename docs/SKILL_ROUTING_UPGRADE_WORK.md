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
- [x] Cloud CI, bilingual release and internal TestFlight VALID/group evidence (verified 2026-09-07 09:03 UTC).

Rollback journals retain complete permission decisions/scopes/expiry and recover both interrupted installation and interrupted rollback. Running-task execution digests are separate from current editing digests. RFB wire tests use real sockets, input and screenshots with a task-local empty OCR fixture: they do not claim Apple OCR accuracy or physical desktop acceptance. An earlier real-OCR test outlived its bounded caller and crashed in Apple's model compiler during process teardown; OCR/device acceptance remains separate.

Public beta remains closed. Physical iPad checks and live private-GitHub connector/remote-host acceptance are not replaced by local fixtures or CI. Run-snapshot retention/garbage collection is a future storage optimization, not an automatic deletion of resumable tasks.

Do not mark these complete merely because a file exists or a build compiles.

## Release evidence / 发布回执

- Immutable release / 不可变发布：`v1.4.97`, Build `128`, source `4804bfb3569b9f556ba3f23594fe8142fe5e1780`.
- [CI 34092117281](https://github.com/JiangNanGenius/floe-agent/actions/runs/34092117281): all three jobs passed / 三项全部通过；983 SwiftPM tests and 94 iPad app tests passed.
- [Release 34094907297](https://github.com/JiangNanGenius/floe-agent/actions/runs/34094907297): verified artifacts, accepted-SDK regressions, signing and Apple transport succeeded / 产物、兼容 SDK 回归、签名与上传全部通过。
- Apple build / 构建 ID：`5fa03ee0-0164-464a-bf6b-469823a7c7a4`, processing `VALID`.
- [Distribution verification 34103853138](https://github.com/JiangNanGenius/floe-agent/actions/runs/34103853138): exactly one group, `Floe QA`, internal; zero unexpected groups / 仅一个 Floe QA 内部组，无外部组。
- [Bilingual GitHub release / 双语更新记录](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.4.97).

Physical iPad and live-host acceptance remains a separate gate before external beta. Existing hosts need Guardian 1.4.5 deployment for the server-side lifecycle fixes; uploading the client does not mutate hosts. / 外部 Beta 仍须经过实体 iPad 与真实主机验收；旧主机需要部署 Guardian 1.4.5，客户端上传不会自动修改主机。
