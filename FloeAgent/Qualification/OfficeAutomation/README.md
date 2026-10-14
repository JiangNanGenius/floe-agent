# Office automation qualification (T4)

Native macOS proof for the authorized automatic Office copy executor, the
persisted formula cached-result verifier and the action-aware native job
policy. Synthetic fixtures only (`Fixtures/`, written by `make_fixtures.py`
with fixed ZIP timestamps); no engine binary, no user content.

## What it proves (8/8 cases)

| Case | Proof |
| --- | --- |
| `automatic-copy-verified` | An approved automatic apply writes a verified `<name>.edited.xlsx`, reopens it (row delta verified) and leaves the source byte-identical; the session is released. |
| `selection-relative-refused` | A selection-dependent command is refused before any engine session opens. |
| `recalc-stale-refused` | The engine "saves" an unchanged stale SUM cache: the reopened check refuses it and writes no output. |
| `recalc-fresh-verified` | A recalculated cache passes the persisted value/type/dependency check and the published copy reopens clean. |
| `output-conflict-refused` | An existing different output is never overwritten. |
| `replay-idempotent` | A repeated request replays the receipt without re-opening a session and with the same digest. |
| `tool-authority-gate` | `document.office.edit` apply without runtime authority returns an error and has no host effect; a genuinely minted authority for the exact call executes the automatic copy. |
| `native-job-admission-preflight` | `media.project apply` is refused as a job, a stale `expectedSHA256` is refused before persistence, and an admitted job runs on its frozen workspace. |

## Run

```sh
python3 FloeAgent/Qualification/OfficeAutomation/make_fixtures.py   # regenerate fixtures
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build --package-path FloeAgent/Qualification/OfficeAutomation \
  --scratch-path ~/Library/Caches/CodexBuild/Floe/capability-closure-20261014/automation/officequal \
  --jobs 3 --disable-automatic-resolution
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ~/Library/Caches/CodexBuild/Floe/capability-closure-20261014/automation/officequal/debug/FloeOfficeAutomationQualification <work-dir>
```

The last command writes `qualification-final.json` into `<work-dir>` and exits
non-zero when any case fails. The work directory is disposable; every run uses
a fresh `run-<uuid>` subdirectory so earlier outputs can never be mistaken for
this run's replay evidence.

## Scope limits

- The device app engine session (`FloeOfficeNative`) is not compiled here; the
  qualification substitutes a fixture-backed session. The real session's
  open/readiness/save/release path is exercised only by the primary's full-App
  build on a device/simulator.
- No model provider, no network and no paid endpoint is used.
