# Build 202 lean release — cloud App build failure evidence

Date: 2026-09-19 (UTC). Source: `0450b2aeb52ee4a1bad2fce4ef76f1ecd2fcdd49` on
`codex/build202-device-feedback`, immutable tag `v1.7.0-beta.59` (created by the
run at the dispatched commit; tag unmoved by this record).

## Outcome

[Run 35474286467](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467)
(`release-unsigned-ipa.yml`, lean route: `lean_release=true`, `publish=true`,
`direct_testflight=false`, `github_prerelease=false`) **failed** in the lean-build
job [105980757911](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467/job/105980757911)
at step **"Rebuild the exact tag with the accepted App Store SDK"**
(`testflight-direct.yml`) with `xcodebuild` **exit 65** (`** BUILD FAILED ** (3
failures)`). The step ran 2026-09-19 22:47:47Z → 23:09:22Z on the accepted
upload toolchain (Xcode 26.6 / 17F113, iPhoneOS 26.5 SDK).

Consequences, all verified from the run record:

- No unsigned IPA artifact was retained; the recovery/Feather artifact, dSYM
  capture, signing, TestFlight validation and upload were never reached
  (all later steps skipped).
- `lean-publish` was skipped: nothing attested, no GitHub release created,
  no Feather dispatch.
- Nothing was uploaded to App Store Connect; no Apple build ID exists for
  build 202.
- The single-run rule was honored: exactly one cloud App build was started for
  the frozen SHA; after the failure no retry or second build was dispatched.

## Exact compiler diagnostics (recovered)

`gh run view --log/--log-failed` truncated the step tail under GitHub's
single-step log limit; the complete diagnostics were recovered from the raw
job-log endpoint (`GET /repos/{owner}/{repo}/actions/jobs/105980757911/logs`,
22,033 lines). Unique error (the "(3 failures)" are three failed frontend
commands for the same `FloeAgent` target compile):

```
FloeAgent/FloeApp/Workspace/SourceControlView.swift:293:90:
error: cannot convert value of type
'KeyPath<SourceControlChangeTreeNode, Array<SourceControlChangeTreeNode>>'
to expected argument type
'KeyPath<SourceControlChangeTreeNode, [SourceControlChangeTreeNode]?>'

OutlineGroup(SourceControlChangeTree.build(stagedChanges), children: \.children) { node in
                                                                                        ^
note: arguments to generic parameter 'Value'
('Array<SourceControlChangeTreeNode>' and '[SourceControlChangeTreeNode]?')
are expected to be equal
```

Failing command: `swift-frontend -frontend -c -filelist …Objects-normal…`
(Release-iphoneos `FloeAgent` target). The keypath `\.children` on
`SourceControlChangeTreeNode` is non-optional
(`Array<SourceControlChangeTreeNode>`) while the SDK 26 `OutlineGroup`
children requirement is `[SourceControlChangeTreeNode]?`. This is new IDE
source-control code from `01ec01dd`; it passed the focused syntax/target
checks recorded in `docs/RELEASE_NOTES_1.7.0_BUILD_202.md` but had not been
through a full device Release build on the accepted SDK.

Repair ownership: a Swift source fix (make the `children` keypath optional,
e.g. `\.children.optional` via an optional-typed accessor or
`{ $0.children }` adapted to `[SourceControlChangeTreeNode]?`) plus a new
immutable tag is required; per release policy the frozen tag `v1.7.0-beta.59`
and its evidence are preserved and never moved.

## Gate integrity

The failure was not hidden or weakened: the job exited non-zero, downstream
distribution was blocked by the existing skip conditions, and no gate was
bypassed. No simulator/UI qualification was run (lean scope), and this build
is not internal TestFlight evidence. Physical-device acceptance remains with
the user on a future fixed build.

## Follow-up in this branch

`testflight-direct.yml` now tees the rebuild `xcodebuild` to a full log file
and writes `-resultBundlePath`, prints an error/warning summary and log tail
on failure, and uploads a diagnostics artifact on failure only. The step still
exits with the real build status. See the branch commit for the diff.
