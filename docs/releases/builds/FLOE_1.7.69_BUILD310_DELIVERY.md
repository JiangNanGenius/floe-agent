# Floe 1.7.69 (310) delivery

Delivery read back on 2026-11-04 (Australia/Sydney).

| Channel | Verified result |
|---|---|
| Internal TestFlight | `VALID`, unexpired; existing Floe QA group `IN_BETA_TESTING` |
| Public TestFlight | Existing publictest1 attached; submitted once; `WAITING_FOR_BETA_REVIEW`, not yet publicly installable |
| Formal App Store | Replaced the prior 309 review with 1.7.69 (310); `WAITING_FOR_REVIEW`; manual release retained |
| GitHub | [v1.7.69](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.69), stable and latest; canonical unsigned IPA and checksum independently verified |
| Feather | Awaited downstream publication succeeded; live download URL, version, source and digest match the GitHub asset |

## Source and artifact

- Immutable source: `af47609948470e9709e8ba21d8564f2144679ede`.
- Annotated tag: `v1.7.69`; tag object `422421985d664d4bec00cfcfb57877096a49808a`.
- Bundle: `org.floeagent.ios`; minimum iOS version 26.0.
- Unsigned IPA: `Floe-Agent-1.7.69-build310-unsigned.ipa`, 830,258,812 bytes.
- SHA-256: `e4cc20ec95912a363dd47bdfb70eb4f14c9f3df383fbc27992db396d929a37ea`.
- Local native archive: Xcode 27.1 (`27A9275`), iphoneos 27.1, arm64 iOS executable verified. Apple signing/upload workflow `41726926938` succeeded; publication workflow `41731254257` succeeded, including the awaited Feather job.

## Changes and verification

- App-owned task workspaces are resolved before external folder bookmarks. A false security-scope return no longer blocks Linux startup for an app-owned workspace. External-folder leases, task ownership and symlink containment remain checked. Eight lease tests and five task-ownership tests passed.
- Live speech recognition accepts replacement hypotheses rather than dropping cumulative corrections. Volcengine ordinary and Agent Plan routes remain separate. Fourteen provider tests passed. A compiled production Swift adapter also received 13 partial replacements and exactly one final result from the real Agent Plan endpoint using a synthetic audio file. This is not physical iPad microphone acceptance.
- Ordinary supplier names omit billing labels across model, speech and search surfaces. Agent Plan, Token Plan and Kimi Code distinctions remain visible. IDs, credentials, custom addresses and user aliases are preserved. Actual iPad Simulator screenshots confirmed the supplier menu and streaming-recognition form.
- Final source passed the local Swift 6 full App/test build (`app385`). All three affected catalog suites passed: 32 tests, zero skips (`app386`).
- The earlier mixed run (`app382`) retains its original result: 81 of 84 passed, three stale catalog assertions failed. Those three assertions were corrected and the affected suites rerun. Successful UI, workspace and speech-source checks were reused because production App source was byte-identical; the original mixed run is not relabeled as a full pass.
- Composer evidence covers automatic wrapping, a visible caret, three complete rows, expansion and draft retention. Relevant screenshots, original failures, native archive, symbols and recovery packages are retained. No user phone was used; the reused iPad Simulator was shut down after verification.

The physical background-audio review attachment was captured on build 308 and retained with an explicit disclosure. It is not represented as footage captured on 310. Existing China availability and the App ICP entry were preserved. Neither review submission publishes the App automatically.

## Separate catalog packaging follow-up

After delivery, a metadata-only follow-up stages provider catalog 1.1.5 and search catalog 1.2.1 with minimum App version 1.7.69, preventing older clients without the compiled adapter set from installing these candidates. Twenty importer tests and sixteen content-builder tests passed. Deterministic candidate ZIPs are pinned; historical archives and the signed index/signature are unchanged. This follow-up neither changes the 310 App artifact/tag nor publishes a content feed.

## Cleanup and coordination

- Removed 14 byte-compared duplicate prequalification App/symbol bundles, retaining their complete counterparts in the final archive.
- Removed the finished 310-only DerivedData directory and its relocated Build directory after checking for open handles and exporting delivery artifacts. Measured free-space changes during this final cleanup were +1,733,980,160 bytes internally and +2,398,814,208 bytes externally; other active tasks share these volumes, so these changes are observations rather than exclusive allocation accounting.
- Removed the private transport draft after independently verifying public delivery and local recovery. Public release assets contain only the unsigned IPA, checksum and minimal provenance.
- Retained the raw pre-normalization producer ZIP separately from the normalized recovery package, the current delivery, rollback artifacts, symbols, original failures and requested CAD images. Shared active caches, occupied worktrees and unrelated changes were preserved.
- Main-first work and coordination rules are recorded in AGENTS.md. Independent predevelopment remains assigned to build 311; it is not merged implicitly or made a release gate. No branch created by this closure remains to remove; already-merged branches occupied by other worktrees are preserved.

Public TestFlight and formal App Store review outcomes remain with Apple. Physical microphone and rendering/performance claims are limited to their separately recorded evidence.
