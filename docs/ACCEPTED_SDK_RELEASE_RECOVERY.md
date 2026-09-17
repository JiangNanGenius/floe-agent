# Accepted-SDK release recovery and the per-device Notes fix

Status: implemented in source, verified by unit fixtures and `actionlint`; **not
dispatched** (no cloud run, no tag move, no push).

Scope of this change:

| File | Change |
| --- | --- |
| `.github/workflows/release-unsigned-ipa.yml` | Split both Notes qualifications into per-device 25-minute steps, add bounded stall diagnostics + a single pre-test retry, add a strict per-device gate, and retain the compiled simulator host before tests. |
| `.github/workflows/accepted-sdk-release-recovery.yml` | Reuses a verified normal-release or recovery simulator host; keeps source and toolchain contracts distinct. |
| `FloeAgent/scripts/verify_accepted_sdk_recovery.py` | Accept both the legacy single Notes step and the newer per-device Notes steps without loosening any other source-run check. |
| `FloeAgent/scripts/tests/test_accepted_sdk_release_recovery.py` | Fixtures for both Notes shapes plus same-source/different-SDK host rejection. |
| `FloeAgent/scripts/tests/test_release_shared_test_hosts.py` | Real-shell control-flow fixtures for the split legs, the strict gate, the pre-test-only retry and host retention. |

`bind_notes_scope.py` continues to derive the source-tag test contract. The new tag also requires real library content covers in `verify_notes_ui_xcresult.py`. The
scope derivation still finds exactly one UI selector and one Office flag in the
tagged release workflow (now four identical invocations), so a caller still
cannot narrow the Notes suite.

## 1. The defect this fixes

The standard release ran both simulator devices inside one Notes step with a
fixed `timeout-minutes: 20`. Build 179 (`v1.7.0-beta.36`,
`a510ea6df8ff4a366e237ad5bad3410e5023c92b`, run `35228451173`) lost that step
while the iPhone leg was still running; the job aborted before
`Normalize reviewed App Store bundle defects before signing`, so no signed
upload happened even though the SDK 27 sibling job and the accepted-SDK device
build were valid.

A new release tag must not repeat this. The Notes qualification is now split
for **both** SDK paths:

* SDK 27 in `build-verify-release`;
* accepted SDK (Xcode 26.6) in `accepted-sdk-build`.

## 2. Per-device Notes legs

Each device runs in its own step (release workflow, accepted-SDK shape shown):

* `Require Notes import on the iPad simulator with the accepted SDK`
  (`release-unsigned-ipa.yml:839`);
* `Require Notes import on the iPhone simulator with the accepted SDK`
  (`release-unsigned-ipa.yml:900`).

Both have `timeout-minutes: 25`. The SDK 27 pair uses the same names with the
`with the SDK 27` suffix (`release-unsigned-ipa.yml:389`, `:451`).

Each leg keeps the original contract, it is not a weaker suite:

* the source tag's selector
  `-only-testing:FloeAgentUITests/NotesWorkspaceImportUITests`;
* the original verifier `verify_notes_ui_xcresult.py --simulator-without-office`
  run against the final attempt's `xcresult`;
* `-parallel-testing-enabled NO -test-timeouts-enabled YES`,
  `-maximum-test-execution-time-allowance 360`,
  `CODE_SIGNING_ALLOWED=NO`; automatic retries of executed test failures are disabled;
* no assertions were removed or skipped.

### Bounded diagnostics

Each attempt runs under the existing
`FloeAgent/scripts/run_test_with_diagnostics.py` wrapper with:

* `--timeout 1320` (about 22 minutes for the whole attempt);
* `--startup-stall-timeout 420` (quiet deadline before the first test starts);
* `--stall-timeout 210` (quiet deadline once tests have started).

### One retry, only for infrastructure

If the wrapper returns `124` and its `summary.json` says
`reason == "stalled"` with `testsStarted == false`, the leg retries **once**
with a fresh diagnostics directory and a fresh `xcresult` path. A real executed
test failure (`testsStarted == true`, or any other non-zero code) is never
retried into a pass.

### Both devices collect evidence; a strict gate blocks packaging

* A failing iPad leg does not stop the iPhone leg: the iPhone step's `if:` is
  `!cancelled() && steps.notes_ipad.outcome != 'skipped'`, so it only runs when
  the iPad leg actually executed.
* No Notes step uses `continue-on-error`.
* An explicit gate follows the legs:
  `Require both SDK 27 Notes device legs to pass`
  (`release-unsigned-ipa.yml:512`) and
  `Require both accepted-SDK Notes device legs to pass`
  (`release-unsigned-ipa.yml:961`). It asserts both
  `steps.notes_ipad.outcome == success` and
  `steps.notes_iphone.outcome == success`.
* The gate fails the job, and every later packaging/signing step is a default
  `success()` step, so the SDK 27 unsigned IPA and the accepted-SDK
  normalize/stage steps cannot run after a partial Notes qualification.
* Evidence is retained even on failure: `FloeSDK27-Notes/` +
  `FloeSDK27-NotesDiagnostics/` and `FloeStable-Notes/` +
  `FloeStable-NotesDiagnostics/` are uploaded under
  `sdk27-notes-ui-*` / `accepted-sdk-notes-ui-*` with `if: always()`.

The downstream `testflight` job still `needs: [build-verify-release,
accepted-sdk-build]`, so both SDK jobs must succeed before any signing key is
installed.

## 3. Compiled-host retention before tests

Both SDK jobs now retain the complete compiled simulator host immediately after
`build-for-testing` and before the first UI test, in the same archive format as
the vetted `ci.yml` / recovery host:

| SDK | Retain upload artifact | Job |
| --- | --- | --- |
| SDK 27 | `sdk27-simulator-host-<source_sha>` | `build-verify-release` |
| accepted SDK 26 | `accepted-sdk26-simulator-host-<source_sha>` | `accepted-sdk-build` |

Each archive contains `Products.tar.gz`, `Products.tar.gz.sha256`,
`SOURCE-SHA.txt`, `TOOLCHAIN.txt`, `SOURCE-RUN.txt` and `SOURCE-ATTEMPT.txt`
with `retention-days: 7` and `compression-level: 0`. The prefixes are distinct,
so an SDK 27 host can never be confused with the accepted Xcode 26.6 host.

Reuse is still gated by `FloeAgent/scripts/verify_compiled_test_host.py`, which
pins the source SHA/run/attempt, the toolchain text, the artifact prefix and the
`Products.tar.gz` digest. A host whose `TOOLCHAIN.txt` is a different SDK is
refused even when the source SHA matches (see
`test_same_source_different_sdk_host_is_not_reused`).

The recovery controller accepts exactly two pinned host origins: the normal
release workflow (source-SHA binding) or this recovery workflow (controller-SHA
binding plus verified tagged-source checkout steps). It selects a fixed verifier
contract from verified run metadata; arbitrary workflow paths or step names are
rejected. The archive still must match the requested source, run, attempt,
Products digest and toolchain before extraction. This reuse path has fixture
coverage but has not yet been exercised by a cloud recovery run.

## 4. Recovery source-run contract (legacy and split tags)

`FloeAgent/scripts/verify_accepted_sdk_recovery.py` no longer hardcodes a single
Notes step name. `_resolve_notes_steps` accepts:

* the legacy shape `Require iPad and iPhone Notes import with the accepted SDK`
  (build 179 and earlier), or
* the split shape with **both** per-device steps.

Mixing the two shapes, or omitting one per-device leg, is rejected. Every other
check is unchanged: repository/workflow/event/tag/SHA/attempt, SDK 27 sibling
success, the required accepted-SDK steps, the three staging steps still
`skipped`, no existing distribution input, and artifact id/digest pins. The
report keeps `notes_step_conclusion` and adds `notes_steps`.

The legacy build 179 run still verifies (`failed_steps ==
["Require iPad and iPhone Notes import with the accepted SDK"]`), and a new run
reports the failed leg directly, e.g. `failed_steps ==
["Require Notes import on the iPad simulator with the accepted SDK"]`.

## 5. Other recovery-controller facts (unchanged)

* Source tag and executing controller are separate checkouts; the verifier and
  the Notes scope binding come from the controller, the app verifier and source
  metadata come from the tag.
* Notes selector and Office scope are derived from the tagged release workflow
  by `bind_notes_scope.py`; they are not dispatch inputs.
* `workflow_dispatch.inputs` count is 16, within the current GitHub limit of 25.
* The device build and App diagnostics are downloaded with `actions: read` and
  `gh api`; the live artifacts API nests the owner under `workflow_run.id`,
  which `_artifact_run_id` accepts (and still accepts flattened metadata).
* Real macOS `ditto` AppleDouble metadata is accepted; a genuine symlink archive
  member is still refused (safe/loud).
* The controller never tags, pushes, publishes, rebuilds the device application
  or rebuilds SDK 27, and never uses the expedited waiver.

## 6. Verification performed for this change

```
python3 -m unittest discover -s FloeAgent/scripts/tests -p 'test_*.py'
# Ran 258 tests ... OK (skipped=1)

actionlint .github/workflows/release-unsigned-ipa.yml \
           .github/workflows/accepted-sdk-release-recovery.yml
# exit 0
```

`test_release_shared_test_hosts.py` executes the real leg shell with controlled
`xcrun`/`xcodebuild`/`python3` drivers and proves: an iPad real failure still
lets the iPhone leg run, the other device's evidence is written, the strict gate
then fails, a pre-test stall retries once in a fresh directory, and a real
executed failure is not retried.

## 7. Remaining work

* The new tag is not created, pushed or dispatched here; that is an
  owner/primary-agent decision.
* The `verify_notes_ui_xcresult.py` update owned by the Notes UI worker should
  be integrated by the primary agent before the next release tag.
* Wiring the recovery controller to a normal-release host is the optional
  follow-up described in section 3.
