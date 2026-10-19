# Floe 1.7.39 (build 280): published readback repair (2026-10-19)

Status: the strict repair and its registered-entry fallback are implemented and
locally tested; neither has been dispatched. The source, tag and published
artifact are unchanged. **Delivery is not yet complete.** The strict
published-release readback and the awaited AltStore/Feather feed refresh still
have to run and pass.

## Observed state

- The normal local-first publish run `39202881875` was dispatched at the frozen
  annotated tag `v1.7.39` (tag object `f1db091b3b33e165ee322cb5145b82ccd1b307c6`,
  committing to `0c9b0864d6e5bbae48f3f4917d5175fcd542b25c`). Its `local-publish`
  job packaged, audited, attested and published release `416921466` as a stable
  (`draft=false`, `prerelease=false`), `latest` release carrying exactly the
  canonical unsigned IPA, its `.sha256` sidecar and `PROVENANCE.json`. The IPA
  SHA-256 is
  `461f2d59e42da38e5546e87e3393702ff8f285f5ef084906fe0ea64e0e14f48c`.
- The next step, `Read back the published release as an installable delivery`,
  failed before invoking the strict verifier with:

  ```
  line 21: MODE_ARGS[@]: unbound variable
  ```

  The awaited `feather-local-release` job was skipped; no Feather run followed
  the release event, and the live `feather.json` feed still serves 1.7.24
  (build 265).
- The original publisher attestation exists for those exact bytes: source
  digest `0c9b0864...`, signer workflow
  `.github/workflows/release-unsigned-ipa.yml`. It was verified read-only after
  publication; no new attestation is needed or created by this repair.

## Root cause

The macOS GitHub runner executes `run:` steps with `/bin/bash` 3.2. Under
`set -euo pipefail`, expanding an empty array with `"${arr[@]}"` is treated as
an unbound variable on that shell. A stable dispatch fills `LATEST_ARGS` and
leaves `MODE_ARGS` empty (a prerelease or beta-pattern dispatch does the
reverse), so the readback's `"${LATEST_ARGS[@]}" "${MODE_ARGS[@]}"` could never
run on either branch. All three readback steps shared the unguarded spelling:
the cloud publish route, the lean route and the local-first `local-publish`
route used by this release.

## Repair

1. Those three readback steps in `release-unsigned-ipa.yml` now pass the
   optional arrays as `"${LATEST_ARGS[@]+"${LATEST_ARGS[@]}"}"` and
   `"${MODE_ARGS[@]+"${MODE_ARGS[@]}"}"`. The guard adds no empty argument and
   changes nothing else: the publish, attestation, verification arguments and
   release-mode selection are untouched. Comments were kept outside the
   backslash-continued verifier command.
2. `repair-release-readback.yml` is a read-only recovery for an **already
   public, stable** App release. It takes `tag`, `expected_source_sha` and
   `expected_ipa_sha256`, checks out that exact tag, requires the annotated tag
   object and tag commit to equal the expected source, requires the release to
   be published, stable, `latest` and to carry the expected provenance record,
   then downloads only the canonical IPA, sidecar and `PROVENANCE.json`. It
   re-runs the existing strict `verify_github_release_publication.py` with the
   staged unsigned/identity/sidecar and arm64 `iphoneos` executable audit plus
   the actual remote digest, and verifies the original publisher attestation
   for the same bytes (source digest and signer workflow). It has
   `contents: read`-level job permissions, never creates an attestation, and
   never creates, edits, uploads or deletes a release, asset or tag. Evidence
   is retained on success and failure. Only after a passing readback does one
   job-level call run the existing `publish-feather-source.yml` in the same
   workflow run, so a feed failure fails the recovery instead of a detached
   run. The file now exposes both its dispatch trigger and a job-level
   `workflow_call` trigger with exactly the same three required string inputs.

The normal `release-unsigned-ipa.yml` route remains the primary publishing path;
this recovery only finishes the strict post-publish verification and feed
refresh for the existing attested public build. It adds no digest-only trust
exception: the full verifier, the real bytes and the original attestation all
have to pass.

## Registered-entry fallback

The new module exists on the default branch, but the Actions service still
returns 404 for its workflow API record (`GET` and `POST` on
`/actions/workflows/...`) and the workflow UI reports "This workflow does not
exist", while other registered workflows operate normally. The underlying
registration cause is not established here and this repair does not guess at
it. Directly dispatching the new module is therefore still unavailable even
though the file is valid and passes actionlint.

To avoid a second verifier or feed generator, the already registered
`release-unsigned-ipa.yml` now exposes the same recovery through three
appended dispatch inputs:

- `published_readback_only` (boolean, default `false`)
- `expected_source_sha` (optional string, default empty)
- `expected_ipa_sha256` (optional string, default empty)

With the flag true, one `published-readback-recovery` job calls
`./.github/workflows/repair-release-readback.yml` at job level with the same
three proofs. The fallback uses the same file at the same commit; it does not
copy the verifier, the provenance checks, the original-attestation check or the
Feather generator. The caller grants only `contents: write`, `actions: read`
and `attestations: read`, which the awaited nested Feather call needs to push
the feed. It grants no `id-token`, no `attestations: write`, and performs no
release, asset, tag or attestation write.

Every legacy build, signing, TestFlight, publish, recovery and Feather job is
gated off while the flag is true. A dedicated no-op route-gate job is skipped
when the flag is true; each legacy root depends on it, and every remaining
legacy job already depends on a gated root. GitHub skips jobs whose needs were
skipped unless the selector uses `always()`, `failure()` or `cancelled()`, and
no legacy job does at job level, so a skipped job's `always()` evidence steps
cannot run either. With the default `false` the gate succeeds and every
original selector, argument and permission is unchanged; the only added legacy
edges are the gate dependency on those roots.

The workflow-level `floe-release-${{ github.ref }}` group is unchanged for
normal and recovery runs. The recovery job itself joins
`floe-release-refs/tags/<tag>`, the same group a normal release run holds when
it is dispatched at the immutable tag, so recovery cannot overlap publication
for that tag. Because that is the only job selected on a recovery run, it also
serializes the run. The repair module uses
`floe-published-readback-<tag>` and the Feather generator keeps
`floe-feather-source`; neither shares the recovery job's group, so the nested
calls cannot deadlock.

The fallback has not been executed yet. While direct workflow registration is
unavailable, it is the only supported way to finish this readback.

## Still required

1. Review and commit the workflow, focused test and documentation change.
2. Dispatch the registered `release-unsigned-ipa.yml` once with
   `--ref main` and `published_readback_only=true`, `publish=false`,
   `tag=v1.7.39`,
   `expected_source_sha=0c9b0864d6e5bbae48f3f4917d5175fcd542b25c`,
   `expected_ipa_sha256=461f2d59e42da38e5546e87e3393702ff8f285f5ef084906fe0ea64e0e14f48c`.
   Direct dispatch of the new module remains unavailable.
3. Read back its evidence artifact (passing `report.json`, attestation output)
   and the live `feather.json` feed entry for `v1.7.39`, build 280.
4. Only then record delivery as complete. The Gitee mirror request is a
   separate delivery gate and is not performed by this recovery.

The original failed run is retained as evidence; its failed step is not rewritten
or hidden, the tag is not moved, and the published bytes are not replaced.


## Primary independent readback

The primary downloaded the published IPA and checksum and ran the unchanged strict verifier locally. It passed with no violations: arm64 iOS device executable, version 1.7.39/build 280, annotated tag source `0c9b0864d6e5bbae48f3f4917d5175fcd542b25c`, matching remote SHA-256 and stable latest pointer. The original publisher attestation also verified for these exact bytes and source. This establishes the published asset independently; the automated recovery and awaited live feed remain separate pending checks.
