# Floe 1.7.32 (273) — application pin gate repair

Status: **post-delivery repository repair. The delivered artifact and its tag are unchanged.**

Build 1.7.32 (273) was archived from the frozen source `29937dc025267bacd89434cc092b3906c99b93ee`
(tag `v1.7.32`), signed and uploaded without an App rebuild, and independently read back
from Apple as build `f0b719ad-c418-4c50-bba0-48ab45aa4147` (`VALID`, unexpired, internal
Floe QA, `IN_BETA_TESTING`). This repair corrects the repository pin/license gate and the
next round's packaging declaration; it changes no dependency, lock, App source or runtime
behavior, and nothing is re-uploaded.

## Defect (retained as observed)

The round added a direct, test-only ZIPFoundation package to `FloeAgent/project.yml` so the
FloeAppTests bundle can `import ZIPFoundation` for two Office automatic-execution suites:

```yaml
url: https://github.com/weichsel/ZIPFoundation.git
exactVersion: 0.9.20
```

`resolved_pins.application_pins` requires every remote Xcode package to declare an
immutable 40-hex revision, so `license_inventory.sh --check` failed on the frozen source:

```
ValueError: Xcode package must use an immutable revision: ZIPFoundation
```

The exact failure output for the delivered source is retained unchanged with the private
delivery evidence; the frozen tag was not edited to force the gate. Two cases in
`scripts/tests/test_resolved_pins.py` failed on the same source.

## Correction

- `project.yml` declares the already-resolved revision
  `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` (0.9.20) instead of `exactVersion`. The
  regenerated Xcode project records `kind = revision` for the same repository and commit;
  the resolved dependency, the two locks and all runtime sources are unchanged.
- `resolved_pins.py` compares a revision-only application declaration with the committed
  lock by repository identity and exact revision. XcodeGen cannot express a semver next to
  a revision, so the committed lock state (including the display version) remains the
  authority for the distribution inventory; a different revision, repository or identity
  still fails, and the committed lock is never rewritten.
- `scripts/check_application_pins.py` (new; read-only, no package checkouts) is called by
  `scripts/release_preflight.sh` before any expensive App archive, so a mutable or drifted
  declaration fails in seconds instead of only surfacing after packaging.

## Verification at the repair commit

| Check | Result |
| --- | --- |
| `bash scripts/license_inventory.sh --check` with the real pinned checkouts (all 32 lock pins verified at their locked revisions) | OK — 234 components, 36 bundled notices, 38 Swift package rows (31 verified checkouts, 1 repository notices, 0 recorded reuse, 0 unknown, 1 vendored package notices, 4 verified FloeCAD checkouts, 0 reviewed FloeCAD copies, 1 bundled OpenShape3D notice) |
| `python3 scripts/tests/test_resolved_pins.py` | 10/10 OK |
| `bash scripts/pin_check.sh` | OK — 32 dependencies pinned to versions or revisions |
| `python3 -B scripts/check_application_pins.py` | OK — 2 immutable Xcode package revisions match `HEAD:FloeAgent/Package.resolved` (32 distribution pins) |
| Generated project (`xcodegen 2.46.0`) | only the ZIPFoundation requirement changed (`exactVersion 0.9.20` → `revision 22787ffb…`); no other project churn |

The license gate was checked read-only: `FloeAgent/Package.resolved` (schema 1, 32 pins),
the app workspace lock, the generated project and the tracked license artifacts were
re-hashed after the run and are byte-identical.

## Source-to-artifact distinction

The delivered binary remains source `29937dc0` / tag `v1.7.32`. The pin correction lands
after that source freeze, so it is **not** part of the delivered 273 binary and does not
retroactively claim the old tag passed the gate. The delivered build was verified through
the packaging, signing and independent Apple readback path recorded in the private
delivery receipt; this repair adds the repository check that the next round must pass
before its archive starts.
