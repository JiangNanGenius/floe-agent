# Floe Agent

Private AI agent workspace for iPhone and iPad. Your models. Your files. Your machines.

Framework status: **M0 integration implementation in progress; M0 and M1 are not yet
accepted**. The iOS app compiles with an iOS 26 deployment target. CloudKit configuration
sync, iCloud Keychain secret migration, SSH jump/PTY, loopback forwarding, RoyalVNC Metal
rendering, and coordinated document working-copy support now have real implementations
and a DEBUG diagnostics screen. Physical-device and Collabora evidence is still required.

See [`docs/M0_VALIDATION_REPORT.md`](docs/M0_VALIDATION_REPORT.md) for the implemented M0
surface, reproducible commands, current evidence, and blockers.

## Module map

| Target | Platform | Contents |
|---|---|---|
| FloeCore | cross-platform | ModelProtocol, ProviderProfile (+ plain-HTTP gate), ModelProfile, FloeError, FloeLogger |
| FloeModels | cross-platform | AgentEvent, ToolCall (64 KiB arg cap, idempotency keys), ToolResult |
| FloeProviders | cross-platform | SSEParser (CRLF/LF/lone-CR, BOM, UTF-8 split), three wire DTOs, WireTranslator, three ProviderAdapters |
| FloeTools | cross-platform | AgentTool protocol, ToolCatalog (compile-time whitelist), ToolContext/CancellationToken |
| FloeSecurity | cross-platform | Three approval policies, CatastrophicActionGate (27 patterns), AuditChain (HMAC-SHA256 hash chain, HKDF device key), CanonicalJSONEncoder, KeychainStore, ApprovalGrantStore |
| FloeAgentRuntime | cross-platform | AgentState machine (§7 diagram), AgentCheckpoint v1, FloeAgentRuntime actor with full cancel semantics |
| FloePersistence | cross-platform | DatabaseManager (GRDB actor facade), schema v2, provider/model CRUD, CloudKit metadata/state and known-host storage |
| FloeSyncCore | cross-platform | Per-field `updatedAt` merge, tombstone resolution, SyncStatus |
| FloeSync / FloeDocuments / FloeImages / FloeSSH / FloeVNC | iOS-only | CKSyncEngine configuration sync, safe document workspace, image operations, SSH/jump/PTY/forwarding, RoyalVNC Metal session |
| FloeApp | iOS-only | SwiftUI entry, adaptive navigation, per-window background policy, DEBUG M0 diagnostics |

## Building

Requirements: Swift 6.2 or newer and a full Xcode installation. The local
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
- `spm-linux-build` (ubuntu-latest, Swift 6.2): cross-platform compile gate. Full tests
  run on macOS because Debian's system SQLite omits GRDB snapshot linker symbols.

## Open implementation gates

- Provider adapters have real HTTP/SSE plumbing but `listModels` returns empty (M2).
- Tool execution routes through `CatalogToolExecutor` stubs until M2 runners land.
- CloudKit code now uploads/applies/deletes Provider and Model records and persists engine
  state, but two-device sync and server conflict behavior still require signed-device proof.
- The M0 diagnostics UI exercises Files, terminal and VNC integration; it is not the final
  production UI. App lock and production provider settings remain open.
- SSH and VNC compile with their real dependencies but have not been demonstrated on
  minimum hardware. Collabora is gated by build storage/tooling and is not embedded yet.
- CJK full-text search: FTS5 `unicode61` tokenizes CJK runs as single tokens; substring
  queries need a segmenting tokenizer (M2+ decision).
- GRDB exposes no public sqlite3 authorizer; audit append-only is enforced with
  `RAISE(ABORT)` triggers instead (see FloePersistence/Migrations/V1Initial.swift).
