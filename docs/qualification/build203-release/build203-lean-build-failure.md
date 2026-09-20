# Build 203 lean release — cloud App build failure evidence

Date: 2026-09-19/20 (UTC). Source: `9e64d2a3cb96b9388994ac163bb0d3cba024d3ac` on
`codex/build202-device-feedback`, immutable tag `v1.7.0-beta.60` (created by the
run at the dispatched commit; tag unmoved by this record). The dispatched source is
the Build 203 metadata commit `f6dfe28740d4ce271e890d1954f85f342ac27a89` plus the
single authorized pre-dispatch notes repair `9e64d2a3` (bilingual section headers
required by the lean publish step; no product source changed).

## Outcome

[Run 35476640882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476640882)
(`release-unsigned-ipa.yml`, lean route: `lean_release=true`, `publish=true`,
`direct_testflight=false`, `github_prerelease=false`) **failed** in the lean-build
job [105986924093](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476640882/job/105986924093)
at step **"Rebuild the exact tag with the accepted App Store SDK"**
(`testflight-direct.yml`) with `xcodebuild` **exit 65** (`** BUILD FAILED ** (3
failures)`). The failure-only diagnostics artifact
`rebuild-diagnostics-run35476640882` (artifact `10595125735`) retains the complete
8.4 MB `rebuild-xcodebuild.log` and `FloeRebuild.xcresult` captured by the
full-log/xcresult rebuild diagnostics added in `2d3f27fa`/`0d4e6b0f`.

Consequences, all verified from the run record:

- No unsigned IPA artifact was retained; the recovery/Feather artifact, dSYM
  capture, signing, TestFlight validation and upload were never reached
  (all later steps skipped).
- `lean-publish` was skipped: nothing attested, no GitHub release created,
  no Feather dispatch.
- Nothing was uploaded to App Store Connect; no Apple build ID exists for
  build 203.
- The single-run rule was honored per attempt: exactly one cloud App build ran for
  the `9e64d2a3` source; after the failure no unchanged-source retry was dispatched.
  The replacement attempt increments to build 204 / `v1.7.0-beta.61`
  ([build 204 delivery](../build204-release/build204-delivery.md)).

## Exact compiler diagnostics (recovered)

Unique error in the complete diagnostics log (the "(3 failures)" are three failed
frontend commands for the same `FloeAgent` target compile):

```
FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift:1153:32:
error: escaping closure captures non-escaping parameter 'timeoutError'
        let timeoutTask = Task { @MainActor in
                               ^
note: parameter 'timeoutError' is implicitly non-escaping
        timeoutError: @autoclosure () -> NSError,
note: captured here
            receipt.resolve(.failure(timeoutError()))
```

This Office native-deadline helper (`01ec01dd`) had never before been compiled in CI:
the SDK 27 source job and the accepted-SDK Release job both first ran it in the
build 202/203 accepted-SDK builds, and build 202 stopped at the earlier
`SourceControlView.swift:293` error before the frontend reached this file.

## Repair (minimal, concrete)

`OfficeDocumentEditorView.swift:1149` — mark the parameter `@escaping`:

```swift
timeoutError: @escaping @autoclosure () -> NSError,
```

Both call sites (`prepareNativeRuntime`, `saveWorkingCopy`) pass `NSError(...)`
autoclosure expressions and are unchanged; no product behavior change. Repair and
build/tag increment landed in `1f654c3e59ba18856006ea0c778986bf37072feb`
("fix(office): mark withNativeDeadline timeoutError escaping; prepare build 204 /
beta.61"). Focused checks: `release_preflight.sh v1.7.0-beta.61` (localization +
version/build consistency), release-notes section greps, whats-new JSON validity
and length, `swiftc -parse` of the edited file.

## Input-error precursor (preserved)

Before this run, an incorrectly parameterized dispatch
([run 35476566659](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476566659))
was cancelled by the coordinator within ~49 s, before the tag-binding step; no tag
`v1.0-beta.60` was ever created (verified 404 / `ls-remote`). No build resources
were consumed.
