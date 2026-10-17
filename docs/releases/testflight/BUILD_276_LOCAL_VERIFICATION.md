<!-- docs-updated: 2026-10-18 -->
# Floe 1.7.35 (276) — local verification, signing, upload and external beta submission

Exact-source local archive, minimum cloud signing/upload, independent Apple readback and the single authorized external TestFlight submission for the 1.7.35 (276) candidate. This record distinguishes the local artifact, internal Floe QA availability and the pending external beta review; it is not an App Store approval, public release or physical-device acceptance record.

## Source and toolchain

- Frozen source tag `v1.7.35` at commit `06c7f2c833c524dca548821576e1542d76fa4406` (annotated tag object `974d6274c0ce8b65e5f9a94a27b2b83071fa6ead`). The packaging-policy changes are separate at `19ab263a3c48fee30a5bb8f8df1d89603040f604`; the App checkout used by signing/upload remained the immutable tag source.
- Local Xcode 27.0 (27A266a), `iphoneos27.0`, Release, arm64, minimum iOS 26.0, six compiler jobs, `CODE_SIGNING_ALLOWED=NO`. The full archive at `037698e9` ended with `** ARCHIVE SUCCEEDED **` and zero `error:` lines; the final docs-only source at `06c7f2c8` completed an incremental archive with exit 0 and identical App/native product hashes. No App or Native recompilation occurred for signing.
- The source is frozen; `git diff 037698e9 06c7f2c8 -- FloeAgent` is empty. The two docs files changed between those commits are the release notes/review copy already recorded at the tag.
- `release_preflight.sh v1.7.35` passed at the tag: localization, native-runtime-free audit, dependency pins, Office pin, release-copy gate, all target versions and the generated project.

## Retained exact-source artifact (before signing)

| Item | Value |
| --- | --- |
| Unsigned transport ZIP | 897,475,383 bytes, SHA-256 `bb062033446c404774ba93c00d068f6d721b90fb7834f329b9eb1c02200ac59f` |
| Raw App export ZIP | 755,504,768 bytes, SHA-256 `fca4893981412cfeb1461eac01c3caeadc0f54358e23a429aa9a22ca7b44cf49` |
| App executable | SHA-256 `6b56f65da4146da7128c506b4f71822e356d80c96fe325f895d11d5cf07fbe2c`, UUID `EFE41A2D-5099-377D-9AA8-F6FD4024D19B` |
| Embedded Office framework | SHA-256 `e2348481a1940ff54ab74618dd23b970d380ee277735ee33dfa5b38cc4018c2f`, UUID `A44EC929-CF87-3678-900C-BFB2D0E73A18` |
| Symbols | 26 files, 596,990,357 bytes; App and embedded Office dSYM UUIDs match the product |
| Provenance | source `06c7f2c8…`, version 1.7.35, build 276, SDK `iphoneos27.0`, Xcode `27A266a` |

The transport ZIP passed independent integrity and payload readback (5,505 entries); the App and embedded Office hashes matched, the App privacy manifest and extension version parity were present, and all 26 symbol members matched the local manifest byte-for-byte. The embedded Office host remains `e2348481…` and its dSYM is included. The four Office device release capability flags remain unproven; this package does not promote them.

## Signing and upload (no App rebuild)

- The already accepted transport ZIP was uploaded to a private unpublished transport draft (eight parts, all server digests matched). The draft was not published and no SCM tag ref was created for it.
- `release-unsigned-ipa.yml` run [39061508589](https://github.com/JiangNanGenius/floe-agent/actions/runs/39061508589) completed `success`; only the local-artifact signing/upload job ran. The runner verified the tag source, downloaded and reassembled the eight parts, matched the whole-ZIP SHA-256, checked provenance/bundle/version/build/SDK/Xcode/App UUID, imported the existing distribution identity and profiles, signed the frameworks/appex/app, verified deep/strict, packaged the IPA, passed `altool --validate-app`, and uploaded with `altool --upload-app` (`No errors uploading archive`). The App was not rebuilt.
- Signed IPA: 756,713,675 bytes, SHA-256 `8d6d2d19976b71fa52506b0a69d53bad910700dfbcbd860ed61574540aa39851`. Independent local checks: `unzip -t` passed; `codesign --verify --deep --strict` is valid and satisfies its Designated Requirement; `org.floeagent.ios` 1.7.35 (276), `iphoneos27.0`, Xcode `27A266a`, minimum iOS 26.0; `get-task-allow=false`, `beta-reports-active=true`; App and extension profiles expire 2027-08-17; App/Office dSYM UUIDs match. The native-runtime-free IPA audit passed.

## Apple state and external submission

- Apple build `41557c7e-c971-473d-9242-6f602acadb9c`, 1.7.35 (276): processing `VALID`, `expired=false`, audience `APP_STORE_ELIGIBLE`, uploaded 2026-10-17T12:22:52-07:00.
- Internal: attached to exactly the existing private `Floe QA` group, `internalBuildState=IN_BETA_TESTING` — internal installation is available. Independent GET-only verification: [run 39062680995](https://github.com/JiangNanGenius/floe-agent/actions/runs/39062680995).
- External: the primary saved the exact 1,359-byte review-notes file (SHA-256 `16f445546aaad6dffe4e7860a21559adfdb42bb65d3ac271457fec66e4d30332`) and submitted build 276 once to the existing `publictest1` group through App Store Connect. The submission row read back as waiting for review; no second submission was made.
- What to Test: SHA-256 `9f1e5908cbe259f54c4d91fed8a8927262c1503505f9e7c0128a799ed1126ef1`; both `en-US` and `zh-Hans` are present with no missing locales.
- Independent GET-only inspect [run 39063023300](https://github.com/JiangNanGenius/floe-agent/actions/runs/39063023300) completed `success` at head `06c7f2c8…` and read back:
  - `buildState`: `processingState=VALID`, `expired=false`, `externalBuildState=WAITING_FOR_BETA_REVIEW`, `internalBuildState=IN_BETA_TESTING`;
  - `externalGroup`: name `publictest1`, `isInternalGroup=false`, `attachedToBuild=true`, public link enabled;
  - `submission`: count 1, state `pending_review`;
  - review notes: prepared copy matched (`notesMatchPrepared=true`, `currentNotesMatchPrepared=true`, `pendingWrite=false`); the helper canonicalizes the 1,359-byte file to 1,358 characters for comparison;
  - What to Test is present for `en-US` and `zh-Hans`, with no missing locales;
  - `ok=true`, `issues=[]`. No Apple API 403 was observed and no write fallback was used.
- The external state is a TestFlight beta review submission, not approval, public availability, an App Store review result or a guarantee of eventual approval. No further Apple write, submission, group change, metadata change or timer was performed by this delivery record.

## Qualification scope and limits

- Local Simulator and component checks that closed the Office chart data/Chinese category, series add/delete/save/reopen, three-format vector ink, attachment navigation, composer/draft and Linux execution items are recorded in the qualification and repair records. They were not rerun for this delivery.
- The full paid-model business matrix, a new UI regression matrix, a Native recompile and the complete cloud CI matrix were not waiting gates for this round.
- Some Office formatting may change on save: the existing engine rewrites embedded-workbook default fonts, unused styles, empty A1 and `calcPr`. Value, type and formula checks are preserved, but byte/style identity is not claimed.
- Physical Apple Pencil pressure, palm rejection, feel and real-iPad performance remain user/device acceptance. Simulator strokes and component hosts do not establish those results.
- The external beta review outcome and any App Store release action remain separate. The existing 1.7.34 (275) formal App Store review build and immutable tag were not changed.

## Cleanup (measured)

- Removed only finished task caches after confirming no open process references and preserving the small build/qualification receipts: the local test DerivedData (84,106 files, ~7.90 GB allocated), the device host build bundle (46,545 files, ~2.12 GB), the device filter cache (2,978 files, ~0.22 GB), the simulator-host ready cache (~0.37 GB; the retained simulator ZIP has framework binary SHA-256 `a70c5342a81b22432dcae87a289824edfd8c57f4794b6fdaa909a4eab299233d`), the device source scratch (9,615 files, ~0.12 GB; its 14 modified source files are byte-identical to a retained source checkout and the tracked patches), and the exact 276 `FloeAgent.xcarchive` (~1.84 GB) after the raw App, transport ZIP, signed IPA and matching App/Office dSYMs were verified retained.
- Internal-volume available space rose from 86,701,216 KB to 98,338,540 KB (measured `df` delta +11,637,324 KB); external-volume available space rose from 320,445,592 KB to 320,538,300 KB (+92,708 KB; concurrent volume activity affects the delta). Nominal allocated sizes and measured `df` deltas differ because APFS accounting and concurrent work; both are recorded in the private cleanup evidence.
- Retained: the build 276 unsigned ZIP/raw ZIP/symbols/provenance, the signed IPA and symbols, the current Native host ZIP/dSYM and simulator ZIP, the build 275 rollback artifact, the current Vendor Office host, and the shared SourcePackages graph. No Simulator device, runtime, app data or user file was deleted; no broad DerivedData/CoreSimulator cleanup was used.

## Remaining

- External TestFlight beta review is pending. Approval, rejection, public availability and any App Store release remain separate outcomes; this record does not claim them.
- Physical-device acceptance remains the user's step.
