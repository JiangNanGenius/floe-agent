# Build 226 — Linux template basic component distribution (D4)

Date: 2026-09-24
Scope: publish the already-qualified BASIC Floe Linux template image and its
complete corresponding source as a new GitHub component prerelease. This is a
component-distribution step only — it is not an App/TestFlight release and it
claims no on-device Linux acceptance.

## What was published

- Component tag: `floe-linux-template-basic-20260923.1` (no leading `v`, never
  `latest`), targeting commit `706413fd816ee6c4197dd7e5184f6fc14fc2f762` on
  `main` — the exact commit the qualifying CI run built from.
- Release state: published **prerelease** (`draft: false`, `prerelease: true`,
  `latest: false`). The prior component releases
  (`floe-linux-guest-20260920.1`, `floe-linux-guest-20260921.1`,
  `floe-linux-guest-20260922.2`) are untouched.
- Workflow: `.github/workflows/linux-template-distribute.yml`
  (`workflow_dispatch` publishes; push only runs the read-only preflight).

## Immutable provenance

| Item | Value |
| --- | --- |
| Component CI run | `35928017233` (success) @ `706413fd816ee6c4197dd7e5184f6fc14fc2f762` |
| Image ID | `floe-debian13-riscv64-202609202607-basic-r572a77382feb-b35928017233` |
| Image candidate artifact | `10780173063` (`linux-guest-image-candidate-35928017233`, 528931782 bytes) |
| Candidate archive sha512 | `d5548351a7a26c688b7db21b18b82a23bf548b4b543243ebcb258be8f9a689626c24a5abde226c5533d4ca6f8464a15a8800922fa82e52b0aaec6c8a91ec43da` |
| Candidate archive bytes | `547188315` |
| Disk sha512 (16 GiB logical sparse) | `34952a2d0cfc147a08a0f21eb4632e6e90560792084250f8d980a0da371ba47b9029e096972b2cfb92598ee0ce893ec6df338033c7a7d7bb9737a6aa0ad65039` |
| Image evidence artifact | `10780098263` |
| Template qualification artifact | `10780182944` (basic: qualified, 19/19 requirements) |
| Upstream sources artifact | `10780128817` (upstream + runner-relink + toolchain-source) |
| Debian source shard artifact | `10780870977` (3135 mapped files, 0 gaps) |
| Source evidence artifact | `10780696519` |
| Basic recipe sha512 | `c66ac0502f050424dee5524698621b936929cc3d09a15c21e103374d5d0c9f460c2d1c72b5464d2a446d49d9b7b1c4c485d9515a05348106b51116284f3216e6` (matches `FloeAgent/LinuxGuest/image/templates/basic.json` at the target commit) |

The released image archive is the qualified candidate repacked with a
provenance-only `manifest.json` change (release-tag source URLs,
`distributionAllowed: true`); bbl/kernel/disk bytes and digests are unchanged.
The App's Runtime v2 template stager reads the manifest from inside the
archive, so the manifest travels in the zip.

## Gates enforced by the workflow

Preflight (read-only; runs on push and before any publish):

- pinned run SHA/conclusion, artifact IDs, names, byte sizes, expiry, producer
  job success, exact Debian shard set;
- evidence bytes: candidate zip sha512, disk sha512, manifest id/qualification/
  template block, template qualification report (qualified, no missing /
  below-minimum / PyPI failures), `template-verify.json`, Debian source-map gap
  count = 0, `SOURCES-MANIFEST.md` sha512 sidecar and `gap_packages=0`;
- tag/release free-or-own state (never overwrite; `--clobber` is never used);
- dispatch target commit resolves, contains `FloeAgent/LinuxGuest` and the
  basic recipe, and the runner sources plus the basic recipe are byte-identical
  to the image run commit (recipe sha512 must equal the manifest template block).

Distribute (`workflow_dispatch` only, never from a failed preflight):

- streaming re-verification of the image archive and members, evidence digest
  cross-checks, provenance rewrite with a real `distributionAllowed` flip;
- full corresponding-source verification (0 Debian gaps, every mapped file
  sha256/size verified, exact cross-glibc `.dsc` files with their
  Checksums-Sha256, runner relink object + toolchain records, kernel/bbl
  upstream pins, license texts);
- staged boot-file association provenance: the image build and the source
  collection each record their own `boot-association.json` with different,
  stage-specific fields. Both are kept per-origin as
  `image-evidence/boot-association.json` and
  `source-evidence/boot-association.json` in the merged source tree; the
  verifier requires a consistent shared identity (same image run, matching
  boot-file pins against the shipped-binary evidence, source_ref = run commit)
  instead of byte equality, and any other merge conflict fails closed with an
  explicit relative path and source bundle (duplicates are never overwritten
  or ignored).
- fail-closed release creation (existing tag or foreign release stops the
  run), no asset overwrites, post-upload verification of every asset name,
  size and digest, plus an anonymous public download-URL probe per asset.

## Evidence retained

- Distribution workflow run (preflight + distribute success):
  https://github.com/JiangNanGenius/floe-agent/actions/runs/35935814778
  (branch `codex/linux-template-distribute`, commit `428b009b`).
- Release: https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-template-basic-20260923.1
  — published prerelease (`draft: false`, `prerelease: true`, never latest),
  tag target `706413fd816ee6c4197dd7e5184f6fc14fc2f762`, 14 assets; asset sizes
  and sha256 digests verified against the live release API, and the public
  image asset URL verified anonymously.
- Final (repacked) image archive recorded by the run:
  sha512 `773ea79e613b73024f66269beaf3469c4d997a9ce60cc6666efec02163bd7e019817261a88fce96240dc30cf5f6afff2677f3efbe0d7fba2128bf57403ba8f30`,
  sha256 `7ed98f62419e1eb7dddd0ca9f83049694661064cefc1f659eecd599e9d769e27`,
  547070503 bytes (the manifest.json provenance rewrite is the only byte
  change from the qualified candidate `d5548351…`).
- Preflight record artifact: `linux-template-distribution-preflight-35935814778`.
- Package hash record: `linux-template-distribution-package-hash-35935814778`.
- Distribution record: `linux-template-distribution-record-35935814778`
  (`distribution.json`, `RELEASE-NOTES.md`, `SOURCE-OFFER.md`, `SHA256SUMS`,
  `manifest.json`, image `SHA512SUMS`, `package-hash.json`, `release.json`,
  `image.json`, `sources.json`).
- The release itself: release notes, source offer and per-asset sha256 sums are
  release assets; the workflow run summary prints the package hash and the
  release record.

## Notes

- The repository caps `GITHUB_TOKEN` at read (`default_workflow_permissions:
  read`), which overrides the workflow's `contents: write` declaration; the
  release step therefore authenticates with the repo-scoped authorized token
  from the `FLOE_RELEASE_GH_TOKEN` secret (never logged), falling back to
  `github.token` where the repository allows write.

- GitHub is the primary distribution; a Gitee mirror is a separate, nonblocking
  long-tail task.
- The App-side pin table (`RuntimeV2OfficialTemplatePinnedArtifacts`) is filled
  from this release's `distribution.json` catalog entry in a follow-up step;
  no unqualified image is pinned by this task.
- Component qualification (cloud image build + boot verification) is not
  on-device Linux acceptance; device acceptance remains a separate App-level
  gate.
