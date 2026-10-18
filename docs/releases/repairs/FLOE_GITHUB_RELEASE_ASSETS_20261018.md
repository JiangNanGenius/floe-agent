# GitHub App release assets: installable IPA gate (2026-10-18)

Status: repair implemented and locally tested. The historical 275 candidate
remains private; no App version is published by this repair. This record documents why v1.7.34 (build 275) is a
source-only public release and what now prevents a normal App release from
silently completing without an installable unsigned IPA.

## Observed state

- Release `414521170` (`v1.7.34`, build 275) is a stable, published, **latest**
  release with **zero assets** (`published_at=2026-10-17T19:35:02Z`). It was
  published by a manual `gh release edit --draft=false` after the draft's eight
  private transport chunks were removed; the decision was an explicit historical
  fallback, not an intended delivery mode.
- The repository's `feather.json` feed on `main` still lists 1.7.24 (build 265).
  The `publish-feather-source` run triggered by the 275 publication failed at its
  own `Require a public unsigned-only asset set` gate because the release has no
  `*-unsigned.ipa`. AltStore and Feather therefore cannot offer builds newer than
  265, which is the user-visible symptom.
- The `v1.7.35` tag exists (build 276); no GitHub release was published for it in
  that beta round, and none is published here.
- Older app releases (for example `v1.7.24`) carried the unsigned pair plus
  evidence, and their publication path was the release workflow with its asset
  assertions.

## Root cause, separated honestly

1. **Intentional historical fallback (275)**: the source-only publication was a
   deliberate round decision. It is not the new requirement and not a precedent.
2. **Guard gap (the real defect)**: the manual publication path had no repository
   read-back gate. A published stable release with zero assets could own the
   `latest` pointer and complete as if it were a delivery. Downstream gates
   (Feather provenance/asset checks, Gitee mirror) correctly failed, but only
   *after* the release was already public and `latest`.
3. **Route gap**: the local-artifact route used for 275/276 ended at TestFlight
   signing; it had no minimal Actions step that packages the archived unsigned
   build, attests those exact bytes, publishes the normal release and refreshes
   the feed. The lean route's dispatch default was a prerelease that never became
   `latest`, so even an asset-carrying release could leave AltStore/Feather on an
   older build.

## What changed

- `FloeAgent/scripts/verify_github_release_publication.py` (new, read-only):
  verifies the live published release from `gh api` JSON dumps — stable, not a
  draft, tag→source commit bound from the actual tag ref and annotated tag
  object (the ref must be `refs/tags/<tag>`, the tag object's SHA and name must
  match the ref and expected tag), exactly one canonical
  `Floe-Agent-<version>-build<build>-unsigned.ipa` plus its `.sha256`, uploaded
  state, remote sha256 digest/size bound to the audited local bytes, no
  signed/simulator/transport/symbol assets, and (for stable tags) the
  `releases/latest` pointer on that tag. The staged IPA must also be a real iOS
  device build: the plist must name the iphoneos SDK/platform and the app's
  actual main executable must be an arm64 Mach-O with an iOS device
  `LC_BUILD_VERSION` (or legacy `LC_VERSION_MIN_IPHONEOS`) load command. A
  simulator binary renamed to the canonical asset fails even when its identity
  and digest match. It refuses `--mode source-only` for App-shaped tags, so a
  source archive can never satisfy an App release.
- `release-unsigned-ipa.yml`: all three normal publish jobs (`publish-release`,
  `lean-publish`, `local-publish`) run that read-back after publishing and
  before Gitee synchronization, and each has a downstream job-level
  `uses: ./.github/workflows/publish-feather-source.yml` gated on its success
  (`needs:` + `if: needs.<publisher>.result == 'success'`). GitHub only supports
  reusable workflows at `jobs.<id>.uses`; they are not called from steps. Stable
  tags publish stable + `latest`; only `-beta.N` tags or an explicit
  `github_prerelease=true` keep the historical prerelease mode, and the lean
  input default is now the normal stable latest release.
- New `local-publish` job (same workflow): a verified private transport
  (`local-device.zip` or its bounded parts, digest and provenance bound to the
  frozen tag) is unpacked, the unsigned IPA is packaged from the archived device
  `.app`, attested with the workflow identity
  (`actions/attest-build-provenance`), published stable/latest, read back, and
  followed by the existing Gitee continuation and the awaited Feather job.
  - The create-job source context must be the frozen tag: the route is
    dispatched with `--ref <vX.Y.Z>` and fails before transport download,
    attestation or publication when `github.sha`/`github.ref` do not equal that
    tag commit. The Actions attestation source digest is the dispatch-ref
    commit, so a `--ref main` dispatch would attest the wrong source. Future
    tags cut from the landed workflow therefore contain this file.
  - `transport_tag` is required for this route and must differ from the public
    release tag. A private draft transport release on the public tag would be
    treated as the public release and could never pass the canonical-asset and
    `draft=false` checks. The signing-only local route may still reuse the tag.
  - Public assets are exactly the unsigned IPA, its `.sha256` and a minimal
    `PROVENANCE.json` (tag/version/build/source/bundle/asset/digest/bytes/
    unsigned/appRebuilt). Raw `provenance.json`, `bundle-normalization.json`,
    the pdfium report, symbols and the transport archive stay in private
    workflow evidence. An existing published release is verified byte-for-byte
    against the packaged IPA and never rewritten; a draft/partial release is
    never converted or clobbered and a partial upload fails the read-back
    instead of being reported complete (an authorized recovery must finish or
    remove it without moving the tag).
  No App build, no signing credentials, no parallel publisher, and no
  digest-only trust mode.
- `publish-feather-source.yml`: also a user-triggerable and reusable
  (`workflow_call`) workflow, keeping the one generator, permissions,
  concurrency group (`floe-feather-source`) and feed writer. After committing
  the feed, the live `raw.githubusercontent.com/.../main/feather.json` is fetched
  with a bounded timeout and cache-busting query and retried until the newest
  entry matches the expected tag, version, tag-commit source, build, exact
  `downloadURL` (equal to the release asset's `browser_download_url`, not just a
  same-named file), sha256 and size. A stale cache, skipped push or wrong URL
  fails instead of silently leaving users on an older build. A repaired existing
  release still needs an explicit `publish-feather-source.yml` dispatch — see
  below.

## Supported normal-release invocations

- Local-first (preferred for locally qualified builds). Dispatch at the
  immutable release tag itself (after landing, the tag created from `main`
  contains this workflow):
  `gh workflow run release-unsigned-ipa.yml --ref <vX.Y.Z> -f tag=<vX.Y.Z> -f transport_tag=<private-draft-tag> -f local_artifact_sha256=<local-device.zip sha256> -f publish=true`
  The App source is checked out at the frozen tag, and `--ref <vX.Y.Z>` makes
  the attestation source digest equal that same commit. `transport_tag` must be
  a different private draft tag. `github_prerelease` omitted means stable +
  latest.
- Cloud lean route, dispatched at the release commit. When the tag already
  exists, use the tag: `gh workflow run release-unsigned-ipa.yml --ref <vX.Y.Z>
  -f tag=<vX.Y.Z> -f lean_release=true -f publish=true`. When this route must
  create the tag, dispatch at the frozen release commit (typically the then
  `main` head); `lean-source` creates the tag at that dispatched commit and
  requires the same commit as its attestation source.
- The older full cloud route is manual-only as well: dispatch with
  `--ref <vX.Y.Z> -f tag=<vX.Y.Z> -f publish=true` only when that cloud route is
  needed. Its preflight refuses a dispatch commit different from the App tag.
  A tag push alone starts no release build. Local-first remains the default.

Private transport drafts and their symbols stay private; they are never
published assets or feed entries.

## Repairing an existing release (275 or a partial publish)

Attach the verified unsigned pair to the existing release without moving the
tag, then re-run the read-back and refresh the feed:

1. Upload `Floe-Agent-<version>-build<build>-unsigned.ipa` and its `.sha256`
   sidecar to the existing release (same release ID, same tag).
2. Run `verify_github_release_publication.py` against that tag; it must report
   `installableDelivery: true`. Pass `--staged-dir` with the audited IPA/sidecar
   so the device-binary and byte binding are exercised, not only remote names.
   A local-build IPA without an Actions attestation cannot feed Feather: the
   existing provenance check still runs `gh attestation verify`.
3. `gh workflow run publish-feather-source.yml --ref main -f tag=<vX.Y.Z>` (the
   feed is not refreshed by an `edited` event), then confirm the live feed
   read-back. The same file is the reusable workflow the release jobs call.
4. Gitee mirrors on `published`/`edited`; large attachments remain subject to
   the Gitee storage quota.

The historical 275 unsigned candidate is not covered by any new workaround: a
local-build IPA without a GitHub Actions attestation cannot pass the existing
Feather provenance contract, and no digest-only exemption is added. Per the
future-first decision the candidate stays private; the normal-release path above
is the supported fix for the next release.

## Verification

Local qualification: 130 focused tests passed (29 publication, 46 workflow,
4 feed, 8 provenance, 17 retained-artifact and 26 mirror tests), with actionlint
passing for both changed workflows. No new App build or live publication was
performed; the next authorized release still needs end-to-end remote readback.

- `FloeAgent/scripts/tests/test_verify_github_release_publication.py`: missing
  IPA, wrong build, signed/simulator/transport names, partial upload state,
  modified bytes, wrong tag ref name, wrong annotated-tag object SHA/name, wrong
  tag peel, simulator binaries behind canonical names and matching metadata,
  missing/legacy Mach-O platform commands, fat arm64 device binaries, draft,
  prerelease, stale latest, explicit non-App source-only, and idempotent
  attach-then-reverify.
- `FloeAgent/scripts/tests/test_release_review_workflows.py`: stable/latest
  defaults, legacy mode switch, all three post-publish read-backs, job-level
  only reusable-workflow calls (`steps` can never reference
  `.github/workflows`), awaited `needs`/`if`/tag-output wiring for the three
  publisher jobs, the local-first tag-ref/source-context guard, the distinct
  explicit transport tag, the public asset allowlist/minimal provenance, and the
  feed read-back's exact `browser_download_url`/tag/version/source binding.
- `FloeAgent/scripts/tests/test_feather_source.py` and `test_feather_provenance.py`
  remain unchanged and green (the reused generators/attestation checks were not
  weakened). `actionlint` passes on both changed workflows.
