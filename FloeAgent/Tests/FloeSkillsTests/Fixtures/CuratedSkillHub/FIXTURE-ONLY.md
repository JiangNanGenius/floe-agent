# FIXTURE ONLY — not a catalog, not a trust root

These files exist so the iOS main thread (A1) and the Android mainline lane
can build and test their schemaVersion-3 parsers, Ed25519 envelope
verification, review-binding chain, package gates and install-offer rules
against the exact wire shape **before** any qualified production content
exists.

- Signed with the deterministic ephemeral key `fixture-only-2026-10`. Its
  private seed is public knowledge (see `scripts/hubcore.py`), so nothing
  signed here attests to any real review, quality, license or publication.
- Every entry id starts with `fixture-` and every feed sets
  `feedStatus: "fixture"`; production parsers must reject fixture feeds when
  asked to activate a production channel, and the fixture key must only ever
  be loaded through an explicitly test-only trust map.
- The layout mirrors the production contract: iOS channel at the bundle root,
  Android channel under `android/`, reviews under `reviews/`, archives
  under `packages/{id}/{version}/{id}.zip`.

Regenerate (never hand-edit): `python3 scripts/make_fixture.py`
Verify unchanged: `python3 scripts/make_fixture.py --check`
