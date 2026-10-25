# CuratedSkillHub contract fixtures — provenance (public-safe)

These files are an EXACT byte-for-byte copy of the fixture-only signed sample
emitted by the fixed H1 Skill Hub contract tree:

- Source repository: `JiangNanGenius/floe-skill-hub` (private coordinator
  checkout at the time of copy), commit `139b9bd86a2b2eded290eceac83536adc7f7c801`.
- Source directory: `tests/catalog/fixtures/` — regenerated only by
  `python3 scripts/make_fixture.py` (verify: `--check`). Never hand-edit;
  refresh from the coordinator's pinned hub commit when H1 re-emits.

SHA-256 of every fixture byte is recorded in `FIXTURE-MANIFEST.sha256`
(computable with `shasum -a 256 -c FIXTURE-MANIFEST.sha256` from this
directory). The two channel feed digests are the verified H1 inputs:
iOS `catalog.json` = `df0fe20bd55977b160dc8144c0b04bd7ac982547998b0174f4c29c30924cd30b`,
Android `android/catalog.json` = `40cca611ef3361a4295c64e5b6563c5c1243fe42b8e10d6338f896713198a6cc`.

All three entry ids start with `fixture-` and both feeds set
`feedStatus: "fixture"` with `sourceCommit: null`. The signing identity is
the deterministic ephemeral `fixture-only-2026-10` key whose seed is public
knowledge (derived in the hub's `scripts/hubcore.py` from a fixed label).
Nothing signed here attests to any real review, license, quality or
publication, and this key must only ever be loaded through an explicitly
test-only trust configuration (`CuratedSkillTrustMode.fixtureTestOnly`).
It is never production trust material, and production paths never see it.

## Legacy public test inputs (`legacy/`)

`legacy/catalog.json` and `legacy/catalog.sig` are EXACT tracked copies of the
App repository's released legacy four-item feed
(`JiangNanGenius/floe-agent` → `skill-hub/catalog.json` / `.sig`,
schemaVersion 2, keyID `official-2026-09`), copied only so the boundary
regression is runnable inside the app-hosted test bundle without depending on
the host worktree layout. They remain REAL production-signed public bytes
(the tests verify the legacy decoder accepts them, then that the curated
client fails them closed on the schemaVersion-3 gate — no synthesized legacy
bypass). Hashes are recorded in `LEGACY-MANIFEST.sha256`; the real legacy
feed itself was not modified by this lane. These two files plus the 14 H1
fixture files are TEST-bundle resources only and must never enter production
App resources.

## License / provenance

- Fixture payloads (feeds, signatures, review records, ZIPs,
  `fixture-public-key.json`, `FIXTURE-ONLY.md`) were produced by Floe-authored
  hub tooling, licensed MPL-2.0; the full license text is copied here as
  `HUB-LICENSE-MPL-2.0.txt` (from the hub repository root `LICENSE`).
- The fixture ZIPs contain only synthetic guide/script samples created by
  `scripts/make_fixture.py`; no third-party upstream content is represented
  (`references/NOTICE.md` inside each archive says so).
- These fixture bytes are safe to carry in the repository test tree: they
  include no secrets, no personal data and no production content. The
  embedded private-key-equivalent is an intentional public ephemeral test
  seed documented by the contract itself.
