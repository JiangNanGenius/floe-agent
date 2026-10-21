# Android Alpha3 qualification — 2026-10-21

Version `0.1.0-alpha.3` / code `3`, full ARM64 package `com.floe.agent.full`.
This is the G02-R1 delivery batch; G02's complete 41-operation acceptance remains open.

## Artifact and source binding

The formally signed APK is 129,150,226 bytes. SHA-256:

```text
e49b287da62c6f2f5d6a053a3a042ad4e5b6fabec7c236f8102607cee30e98b9
```

The unchanged release certificate SHA-256 is
`b0d64b6fcce616fef2c64eb33d4000e612cea20997ea29b20844758b83e1b411`.
The immutable release source is identified by `android/v0.1.0-alpha.3`.
Builds preceded the release-source commit; the release owner checked all 340 frozen
App input records and 588 native overlay/input records against the proposed Git tree.
No iOS source or unrelated working-tree edits are included in this Android batch.

Swift 6.4.1 actually cross-linked the Android ARM64 core. The canonical unstripped
core and symbols were retained, with core SHA-256
`db87fee12a04e46c0d36ddbefd1d6c1f31a22698c5ef1bab0a1232fe6caabf9e`.
The packaged dependency closure contains 19 core/runtime libraries. App libraries
were stripped only in packaging derivatives; allocated sections, dynamic symbols,
build IDs, SONAMEs and dependencies match the qualified inputs. Full and Play APKs
passed 28 boundary/layout checks, including full-only positive controls, physical
exclusion of phone-control/root classes from Play, and 16 KiB ELF/ZIP alignment.
All 140 APK ZIP payloads are unchanged by formal signing.

## Focused verification

- The bridge matrix's stale distinct-pair count was corrected from 85 to 86:
  87 tuples, 86 scope/command pairs, 85 command names; the focused check passed.
- Existing relevant host and JVM evidence was reused for unchanged inputs.
  Eight new first-message projection tests passed. A wider seven-class execution
  initially had two failures; both original failures and the controlled ordering
  reproduction were retained. After fixing only test identities and fixture
  ordering, all 63 cases passed, with zero failures, errors or skips.
- The test-only post-build overlay is
  `app/src/test/kotlin/com/floe/android/host/ConversationOrdinaryPathTest.kt`:
  compiled-snapshot SHA-256
  `d86404fb4b513261e87b6d1801a659b7b9968f573471ac9d83cf701a3becbfec`,
  qualified source SHA-256
  `ced0fcd3093a754f25b7f718acbed91be67cc0666833c1e58a1bd04095caead5`.
  Production inputs and released APK bytes did not change for this fixture repair.
- API37 ARM64 tablet emulator, actual 16 KiB kernel: ordinary first and continuous
  cloud replies; Stop, cold reopen of the paused run and explicit Continue with a
  real reply; temporary-chat explicit Keep and cold persistence; navigating away
  during a temporary run and rejecting late output. Settings list/detail columns,
  provider-edit modal cancellation, and Android Documents picker cancellation back
  to the owning conversation were exercised in the full app.
- Samsung SM-G9810, Android 13/API33, 4 KiB: public Alpha2 directly upgraded to the
  exact final APK without clearing data, retaining the original app UID. Original
  Alpha1 and Alpha2 history/replies were visible in Alpha3; configured model and
  stored credential remained usable without re-entry. New first/continuous cloud
  replies, Stop and cold-reopened history passed. Alpha2's initially empty history
  sidebar did not imply deleted records: Alpha3 displayed the original records.

## Boundaries

These checks qualify this batch, not every G02 operation or final iOS visual parity.
The real tablet/stylus matrix, complete attachment ingestion and broad device matrix
remain later work. Stop acknowledgement does not prove a provider stopped billing.
No local LLM is bundled. In-app update checks remain planned; this alpha updates by
manually installing the APK. Linux/IDE, Office, phone-control, ADB/root and the rest
of the roadmap are not claimed complete by their module markers or this release.

The release contains one signed full ARM64 APK and `SHA256SUMS` only, is a
prerelease, and must use `latest=false`. Publication, independent download hashing
and cleanup are recorded separately after they actually finish.
