# Floe 1.7.39 (build 280): published readback repair (2026-10-19)

Status: repair implemented and locally tested; not yet dispatched. The source,
tag and published artifact are unchanged. **Delivery is not yet complete.** The
strict published-release readback and the awaited AltStore/Feather feed refresh
still have to run and pass.

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
2. `repair-release-readback.yml` is a dispatch-only, read-only recovery for an
   **already public, stable** App release. It takes `tag`,
   `expected_source_sha` and `expected_ipa_sha256`, checks out that exact tag,
   requires the annotated tag object and tag commit to equal the expected
   source, requires the release to be published, stable, `latest` and to carry
   the expected provenance record, then downloads only the canonical IPA,
   sidecar and `PROVENANCE.json`. It re-runs the existing strict
   `verify_github_release_publication.py` with the staged unsigned/identity/
   sidecar and arm64 `iphoneos` executable audit plus the actual remote digest,
   and verifies the original publisher attestation for the same bytes (source
   digest and signer workflow). It has `contents: read`-level job permissions,
   never creates an attestation, and never creates, edits, uploads or deletes a
   release, asset or tag. Evidence is retained on success and failure. Only
   after a passing readback does one job-level call run the existing
   `publish-feather-source.yml` in the same workflow run, so a feed failure
   fails the recovery instead of a detached run.

The normal `release-unsigned-ipa.yml` route remains the primary publishing path;
this recovery only finishes the strict post-publish verification and feed
refresh for the existing attested public build. It adds no digest-only trust
exception: the full verifier, the real bytes and the original attestation all
have to pass.

## Still required

1. Review and commit the workflow/test/documentation change.
2. Dispatch `repair-release-readback.yml` once with the three verified inputs.
3. Read back its evidence artifact (passing `report.json`, attestation output)
   and the live `feather.json` feed entry for `v1.7.39`, build 280.
4. Only then record delivery as complete. The Gitee mirror request is a
   separate delivery gate and is not performed by this recovery.

The original failed run is retained as evidence; its failed step is not rewritten
or hidden, the tag is not moved, and the published bytes are not replaced.
