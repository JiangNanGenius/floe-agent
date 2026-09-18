# Build191 media fixture suites (tracked)

Focused, offline fixture suites for the Build191 media repair, ported from the
private media-review harness so the checks survive the task:

- `ReviewProviderTests.swift` — reference-image policy, provider routing and
  adapter request/status bodies (89 checks)
- `ReviewOwnershipTests.swift` + `DatabaseManagerShim.swift` — durable job
  ownership, schema v42/v43 and idempotent `createJob` against real SQLite
  (45 checks)
- `ReviewGIFTests.swift` — GIF disposal/compositing, timing, bounds and atomic
  cancellation (22 checks)

Run:

```
bash FloeAgent/scripts/tests/media_review/run_media_review_tests.sh
```

Actual result (2026-09-19, branch `codex/build191-feedback-repair`): all three
suites pass, 156 checks total (`REVIEW-PROVIDERS: PASS (89)`,
`REVIEW-OWNERSHIP: PASS (45)`, `REVIEW-GIF: PASS (22)`).

How it works: the runner compiles `FloeCore` freshly from the current sources
into a temporary module before linking any fixture, so no stale prebuilt
FloeCore interface is exercised, then compiles the current `FloeProviders`,
the media-job persistence sources (with a test-local `DatabaseManager` shim)
and `FloeMedia/MediaGIFSupport.swift`. No SwiftPM, no root SwiftPM build, no
App build, no network, no paid provider call and no private-file dependency.

Prerequisites: an Xcode-beta-compatible `swiftc`, the cached dependency build
at `FloeAgent/.build/apple/Products/Debug` and the GRDB checkout module map.
If they are missing the runner exits 2 with `SKIP` (never a fake pass). The
Build191 owners ran it on Xcode-beta 6.4.0.30.4; the cache is not regenerated
here because heavy builds belong in CI.

Limits: structure/behavior level only. It does not prove an App/cloud build,
a real device database upgrade (v42→v43 was exercised on fresh fixture
databases) or real provider acceptance (no paid calls).
