# Build 209 compile failure

[Run 35501871606](https://github.com/JiangNanGenius/floe-agent/actions/runs/35501871606)
bound immutable tag `v1.7.0-beta.66` to source
`43a10a0a76c3cc183340ffb36ac940df7f24f818` (`codex/feedback-build209`) and passed
the release preflight for version 1.7.0, build 209, with every target matching
the generated project. It then failed the accepted-SDK App rebuild (job
106054964811, step "Rebuild the exact tag with the accepted App Store SDK") at
2026-09-20T09:44:17Z with `xcodebuild` exit 65.

The retained `rebuild-diagnostics-run35501871606` artifact (ID 10603081167,
981,507 bytes, not expired) holds the full rebuild log and
`FloeRebuild.xcresult`. The log records five unique Swift optional-unwrap
errors:

- `FloeAgent/FloeApp/App/AppEnvironment.swift:395` — `guests: linuxGuests`
  where the assembled service is `TinyEMULinuxCommandService?`.
- `FloeAgent/FloeApp/App/AppEnvironment.swift:413`, `:418`, `:425` — `await
  linuxGuests.stopGuest(environmentID: id)` on that same optional.
- `FloeAgent/FloeApp/Execution/LocalServiceTool.swift:334` —
  `BrowserURLPolicy.authorizeService(..., conversationID: context.conversationID)`
  passes the tool context's optional `UUID?` where a non-optional `UUID` is
  required.

The build stopped before IPA creation, symbol retention, signing or upload. No
unsigned IPA or dSYM artifact, no TestFlight evidence artifact and no Apple build
ID exist for build 209; the run's only artifact is the failure diagnostics set,
and every sign/upload/publish step is recorded as skipped. The bilingual
`docs/TESTFLIGHT_1.7_WHATS_NEW_BUILD_209.json` notes were prepared but never
used.

Source `33a72da9` corrects both causes: `LinuxGuestBackendAssembly.makeService`
now returns a non-optional `TinyEMULinuxCommandService` (with an explicit
`UnavailableLinuxGuestImageResolver` when there is no durable artifact root, so
missing image storage no longer drops environment ownership), and
`LocalServiceTool` passes the job's `conversationID` down as a `UUID`. These
changes have not yet been compiled by an accepted-SDK App build; the next
candidate must use build 210 and a new immutable tag.

Local, Git-ignored evidence copies:
`Local/Private/feedback-build209/build-failure-report.json`,
`Local/Private/feedback-build209/delivery-report.json` and
`Local/Private/feedback-build209/rebuild-diagnostics-run35501871606.zip`.
