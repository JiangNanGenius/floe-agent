# Build 241 external/public TestFlight materials (candidate)

Status: **prepared, not submitted / not dispatched.** This directory is the current-round draft for the next public TestFlight review. The older `docs/public-beta` files (`metadata.json`, the 15-page review guide, screenshots and receipts) stop at build 191 and remain historical; they are not Build 241 evidence. Historical records were preserved, not rewritten.

Nothing here claims that Build 241 exists, is uploaded, is qualified or is installable. **Build 241 / marketing 1.7.0 / tag `v1.7.0` is a planned final-source candidate only, not an actual App Store Connect build or tag.** The tag was absent locally and remotely on 2026-10-02, the frozen source SHA is still pending from the main thread, and no external Apple build exists yet. Pending Apple GUI login does not block authorized API operations using the existing credentials. Submission follows the main thread's source, artifact and external-review checks.

## Files

| File | Purpose |
| --- | --- |
| [whats-new.json](whats-new.json) | Bilingual What to Test input for the `public-testflight` helper (`--notes`). |
| [beta-description.json](beta-description.json) | Bilingual Beta App Description input (`--description`). |
| [review-notes.en-US.md](review-notes.en-US.md) | English TestFlight App Review notes, product-facing body with a clear draft banner; the helper rejects it for `submit` until the main thread replaces the banner with frozen facts. |
| [review-notes.zh-Hans.md](review-notes.zh-Hans.md) | Chinese review notes, aligned with the English file; also marked draft and rejected by the helper. |
| [unverified-fields.json](unverified-fields.json) | Machine-readable list of verified facts versus fields that must not be guessed. |

The helper and workflow that consume these files:

- [`FloeAgent/scripts/public_testflight.py`](../../../FloeAgent/scripts/public_testflight.py): fail-closed `inspect` (read-only, default) and explicit `submit`. It verifies the immutable tag/commit, bundle, version, build, `VALID`/unexpired state, `APP_STORE_ELIGIBLE` audience and exactly one existing external group before any write; only an `IOS` pre-release platform can match, `demoAccountRequired` must be confirmed (with both credential fields when true), duplicate locales and pagination cycles fail closed, and an enabled public link is reported only as its real read-back URL. It paginates every list read, reads back every write and reports existing pending/approved submissions instead of re-POSTing, requiring `--allow-resubmit-rejected` for one recovery POST after a rejection. An empty existing Beta App Description covered by the prepared `description` input is repairable by `submit`; empty descriptions on uncovered locales or missing localizations still block.
- [`.github/workflows/public-testflight.yml`](../../../.github/workflows/public-testflight.yml): `workflow_dispatch` only. The private internal Floe QA path in `xcode-cloud-control.yml` is untouched. `submit` needs `operation=submit` plus `confirm=submit-external-review` and a non-empty `review_notes_path`; public-link enablement and rejection recovery are separate default-off options. `review_notes_path` defaults to an empty value so a default `inspect` stays valid and a `submit` must name the final file explicitly.

## Review-notes closure

`submit` requires a prepared review-notes file (`--review-notes`, workflow input `review_notes_path`). The helper validates it as final product text: 1..4000 characters (Apple documents a 4,000-character maximum for Beta App Review notes), UTF-8, and no draft banner, `placeholder`, `TBD`/`FROZEN`/`待核验`-style marker or unreplaced bracketed placeholder. `inspect` compares the prepared text against the existing `betaAppReviewDetail.notes` and reports only `pendingWrite`, `currentNotesPresent`, `currentNotesMatchPrepared` and the character count — never the old or prepared notes text.

On explicit `submit` the helper PATCHes only the `notes` attribute of the already existing `betaAppReviewDetails/{id}`, reads it back and requires a byte-identical match before attaching the external group and creating the review submission. It never creates a review detail and never changes contact or demo-account fields. If the note already matches, no PATCH is issued. While the files in this directory carry the draft banner, **both `inspect` and `submit` reject them**; after the main thread freezes the source, replace the banner with the frozen facts once and dispatch with `review_notes_path=docs/public-beta/build241/review-notes.en-US.md` (or the chosen final file).

## Current-round facts (labeled)

- Internal delivery line: 1.7.0 build 240, immutable tag `v1.7.0-beta.99` (`9bd9a237…`), unsigned IPA SHA-256 `d2dcea33…`; source recorded in [docs/TESTFLIGHT_1.7.0_BETA.md](../../TESTFLIGHT_1.7.0_BETA.md).
- Apple read-only discover run 36903484959 (SUCCESS) reports the highest build as 240 with `APP_STORE_ELIGIBLE`. No Build 241 upload exists.
- Cloud simulator Office editor run 36843561563 passed import/preview/edit/idle/save/reopen. That is editor evidence, not slideshow acceptance.
- The user reports Build 240 as basically stable. This is user-reported context and does not qualify Build 241.
- PowerPoint slideshow: the main thread reviewed a real 22-phase/9-frame strict UI test gate, and a **local single-object patch verification** of the repair exists. Production iOS/iOS-Simulator producer/consumer integration is still being prepared by a separate job and is not published or pinned here; do not cite the old pin or claim a released fix. The frozen build's presentation frames must be re-verified before submission.
- The Linux VM efficiency measurement is not complete; no performance claim is made.
- Downloaded MLX local models are Beta, optional and not recommended as a daily default; core Notes, documents and Canvas work without an AI provider. Apple's system model path is separate and is not labeled Beta.

## Unverified fields

See [unverified-fields.json](unverified-fields.json). In summary, still unknown and not to be guessed: frozen source SHA, Build 241 App Store Connect record/state, external group (`publictest1` is only a historical route/lookup clue; a live read-only inspect must confirm it exists and is the unique external group), support/privacy URLs, feedback email, review contact, the final review-notes text, Build 241 artifact hash, slideshow acceptance on the frozen build and VM efficiency measurements. No tag, build or artifact may be described as existing until actually observed.

## Prepared usage

Read-only preflight (no dispatch was performed by this preparation task):

```
python3 FloeAgent/scripts/public_testflight.py \
  --operation inspect --bundle-id org.floeagent.ios \
  --version 1.7.0 --build 241 --tag v1.7.0 --source-sha <frozen 40-hex> \
  --group-name publictest1 --repo-root . \
  --notes docs/public-beta/build241/whats-new.json \
  --description docs/public-beta/build241/beta-description.json \
  --review-notes docs/public-beta/build241/review-notes.en-US.md
```

The `--review-notes` line only works after the main thread has replaced the draft banner with the frozen facts; while the files are still marked draft the helper exits with a validation error on purpose. The public submission itself is a later, explicit decision for the main thread after the IPA/source acceptance. A successful submission is not proof of public installability; Apple review pending, review rejection and approved-external-testable are separate results.
