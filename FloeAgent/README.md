# Floe Agent

Private AI agent workspace for iPhone and iPad. Your models. Your files. Your machines.

Framework status: **audited, buildable foundation; M1 is not yet complete**. The shared
modules pass 151 tests and the iOS app compiles for an iOS 27 simulator with an iOS 26
deployment target. CloudKit record synchronization, production tool runners, app lock,
Files workflows, and the M0 integration spikes remain open.

See [`docs/FRAMEWORK_AUDIT_2026-08-13.md`](../docs/FRAMEWORK_AUDIT_2026-08-13.md)
for the review findings, fixes, evidence, and remaining gates.

## Module map

| Target | Platform | Contents |
|---|---|---|
| FloeCore | cross-platform | ModelProtocol, ProviderProfile (+ plain-HTTP gate), ModelProfile, FloeError, FloeLogger |
| FloeModels | cross-platform | AgentEvent, ToolCall (64 KiB arg cap, idempotency keys), ToolResult |
| FloeProviders | cross-platform | SSEParser (CRLF/LF/lone-CR, BOM, UTF-8 split), three wire DTOs, WireTranslator, three ProviderAdapters |
| FloeTools | cross-platform | AgentTool protocol, ToolCatalog (compile-time whitelist), ToolContext/CancellationToken |
| FloeSecurity | cross-platform | Three approval policies, CatastrophicActionGate (27 patterns), AuditChain (HMAC-SHA256 hash chain, HKDF device key), CanonicalJSONEncoder, KeychainStore, ApprovalGrantStore |
| FloeAgentRuntime | cross-platform | AgentState machine (§7 diagram), AgentCheckpoint v1, FloeAgentRuntime actor with full cancel semantics |
| FloePersistence | cross-platform | DatabaseManager (GRDB actor facade), schema v1 (13 STRICT tables + FTS5 + append-only audit triggers), provider/model configuration CRUD |
| FloeSyncCore | cross-platform | Per-field `updatedAt` merge, tombstone resolution, SyncStatus |
| FloeSync / FloeDocuments / FloeImages / FloeSSH / FloeVNC | iOS-only | CloudKit engine skeleton, DocumentCommand + bridge protocol, ImageOperation + validate, RemoteHostProfile + RemoteRun lifecycle, VNCAction + VisualActionBudget |
| FloeApp | iOS-only | SwiftUI entry (iPhone TabView / iPad NavigationSplitView), per-window scene accounting, PlatformBackgroundPolicy + iPhone/iPad implementations |

## Building

Requirements: Swift 6.4-compatible toolchain and a full Xcode installation. The local
build script discovers `/Applications/Xcode.app` or `/Applications/Xcode-beta.app`
without changing the machine's global `xcode-select` setting.

```bash
swift build                          # all SPM targets (macOS host)
swift test                           # cross-platform test suites
scripts/local_build.sh               # build + test with environment workarounds
```

If SwiftPM's sandbox fails under your shell: `SWIFTPM_NO_SANDBOX=1 scripts/local_build.sh`.

The iOS app target is generated with XcodeGen: `scripts/gen_project.sh` (requires full
Xcode; the generated `.xcodeproj` is git-ignored).

## CI

`.github/workflows/ci.yml` runs two jobs:

- `build-test` (macos-26): xcodegen + pin check + SPM build/test + app builds on iPhone
  and iPad simulators + gitleaks + syft SBOM + license inventory.
- `spm-only` (ubuntu-latest, Swift 6.4): cross-platform build + test regression net.

## Open implementation gates

- Provider adapters have real HTTP/SSE plumbing but `listModels` returns empty (M2).
- Tool execution routes through `CatalogToolExecutor` stubs until M2 runners land.
- `ConfigSyncEngine` creates a `CKSyncEngine`, but its delegate still does not upload,
  apply, delete, or persist CloudKit records. Two-device sync is not implemented.
- The SwiftUI destinations are navigation placeholders; provider settings, app lock,
  Files import/edit/save, terminal, and VNC surfaces are not production UI.
- SSH, Office, and VNC M0 spikes have not been demonstrated on minimum hardware.
- CJK full-text search: FTS5 `unicode61` tokenizes CJK runs as single tokens; substring
  queries need a segmenting tokenizer (M2+ decision).
- GRDB exposes no public sqlite3 authorizer; audit append-only is enforced with
  `RAISE(ABORT)` triggers instead (see FloePersistence/Migrations/V1Initial.swift).
