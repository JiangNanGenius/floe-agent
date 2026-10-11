# Build 270 — local exact-source release verification (1.7.29)

- Source: `3286444c2c167f2a49305785dc78a06f60402ece`, immutable tag `v1.7.29`, version 1.7.29 (270).
  The tag was created at the version checkpoint on top of the accepted feature commit
  `3c0e6fbd` (unified 3D workbench, design workflow hardening, provider/runtime delivery and
  the CAD fullscreen camera/lifecycle fixes). An earlier local tag attempt pointed directly
  at the feature commit and was corrected to the version checkpoint before anything was
  pushed; that initial wrong SHA was never published and is retained only in private
  evidence.
- Toolchain: Xcode 27.0 (27A266a), iPhoneOS 27.0 SDK; six compiler jobs; all regenerable
  build output on the internal SSD.
- `FloeAgent/project.yml` is the source of truth: all four App/extension targets use
  1.7.29 (270); `gen_project.sh` regenerated the committed Xcode project and the release
  copy preflight (`release_preflight.sh v1.7.29`) passed, including the bilingual
  release-notes and TestFlight-notes gates.
- The same-branch checkpoints shipped here: `444fa5f7` (feature), `d3fc45d0`, `3bbab76b`
  and `3c0e6fbd` (CAD lifecycle and camera fixes); `e419845f` (lean CI policy) and
  `cb4a32ec` (policy docs) are the CI/doc-policy commits. No source file was changed after
  the tag; distribution copy fixes live on `main` and never move the tag.

## Recoverable device artifact (saved before signing)

- Release device build `** BUILD SUCCEEDED **` with signing disabled; the app was never
  rebuilt for distribution.
- App binary `Floe Agent` SHA-256: `7519d466c6fab7f4054c52a1a7dc86d96e1a90702fccfe5f8a6fbd6965fec1ea`.
- App/dSYM UUID: `F12587B9-E443-3105-92C0-46D18B12BE22` (match verified by `dwarfdump`).
- Transport `Local/Artifacts/build270/local-device.zip`: 877,827,483 bytes,
  SHA-256 `5d1f00eef5f6e3b10c1659dfada91274c7a8388a76e36d18114a946fff4c9fa5` (ZIP integrity
  verified, 5,458 entries, includes `provenance.json` and matching dSYMs).
- Raw pre-normalization App archive `Local/Artifacts/build270/raw-device-app.zip`
  SHA-256 `8dd79462796e182c8f9a129bc0470d1d826e1821855f7e47f8352a61dd198167`.
- Provenance records source SHA, version/build, `xcode_build 27A266a`, `sdk iphoneos27.0`
  and the executed qualification statement. Extension bundles inside the payload
  (`Floe Screen Share.appex`) also carry 1.7.29 (270).
- The same artifact was uploaded as a private draft GitHub transport and never regenerated;
  any distribution retry reuses this exact archive.

## Executed qualification consumed for this release

| Check | Result |
| --- | --- |
| FloeCADKit suites (T7W) | 29 tests / 0 failures (handoff 4, thumbnail isolation 3, viewport 2, store recovery 14, proposal 6); pre-fix control 3 tests / 10 failures retained |
| Focused App CAD suites (T7) | 44 tests / 0 failures (creation incl. fullscreen cancel, backup, workbench, document, proposal persistence) |
| Full App suites (T7Q/T7R) | 121 App + 22 Runtime and 47 App + 25 Runtime, 0 failures on the integrated tree |
| Full App Swift 6 build (T7W) | `** BUILD SUCCEEDED **` on the fixed tree; device Release build for this release also succeeded |
| Primary actual UI | iPhone PNG26–30: FRONT camera survives fullscreen, RIGHT inside fullscreen returns to presenter, parent Isometric works, existing-node Done saves without alert, fresh-new fullscreen cancel leaves the original two nodes and no alert |
| Exact-source CI | Supplementary only; not used as the release gate (user-authorized local-first route). No full cloud matrix was rerun |

Original failures (T7S missing-thumbnail save error PNG18, T7T empty-draft PNG21, T7W
camera reset PNG24/25) are retained in their evidence directories and were not rewritten.
On the retained iPad, the largest **standard** text size passed on the Creative home and
design form (PNG31); accessibility extra-large text was not tested; split-window remains
unqualified after an unconfirmed windowing black frame (process alive, no specific crash
report, device restarted with data preserved and Floe normal, PNG32/34). Physical-device
fluidity belongs to the user.

## TestFlight delivery

- Signing/upload run
  [38137064773](https://github.com/JiangNanGenius/floe-agent/actions/runs/38137064773)
  (`release-unsigned-ipa.yml` local-artifact lane, `publish=false`) succeeded **without
  rebuilding the App**: it downloaded the draft transport, verified the pinned SHA-256,
  signed with the existing distribution identity and profiles, ran the native-runtime
  audit, `altool --validate-app` and `--upload-app`.
- Recorded apple-internal evidence (`local-v1.7.29-apple-internal` artifact):
  `buildID 198a207d-3e96-4e88-8fef-3840e509a385`, version 1.7.29, build 270,
  **processing VALID**, **expired false**, group **Floe QA**, `internalBuildState
  IN_BETA_TESTING`, beta notes verified for `en-US` and `zh-Hans`.
- The upload receipt alone is not availability; independent readback and the external
  submission state are recorded below and in [CURRENT_STATUS.md](../../CURRENT_STATUS.md).
  Build 269 remains internal-only and was never promoted.

<!-- EXTERNAL-STATE -->
## External (publictest1) submission

One authorized API submission ([38139521326](https://github.com/JiangNanGenius/floe-agent/actions/runs/38139521326))
was dispatched from `main` with the corrected review notes. Apple refused the
first write — `PATCH /v1/betaAppReviewDetails/6801209053` — with
**HTTP 403 `FORBIDDEN_ERROR`**: the current API credential can read the build
and group state but cannot write the app-level beta review detail (final
review notes). The helper is fail-closed, so nothing was attached and nothing
was submitted. A post-failure GET-only readback
([38139655286](https://github.com/JiangNanGenius/floe-agent/actions/runs/38139655286))
confirmed zero partial writes: `READY_FOR_BETA_SUBMISSION`, submission count 0,
`publictest1` attachedToBuild false, `VALID`, unexpired, `IN_BETA_TESTING`,
issues empty.

This is an API-permission limitation, **not** an Apple review rejection and
**not** a submission. The remaining step is the same existing App Store Connect
web flow used for builds 241/243/255/262/263 (save the final review notes from
`docs/public-beta/build270/review-notes.en-US.md`, attach build 270 to the
existing `publictest1` group, submit for Beta App Review, read back). No
public-link, group or permission change is part of it. The first submission
failure (draft-marker validator, run 38139250336) happened before any Apple
call and is retained as evidence.
<!-- /EXTERNAL-STATE -->

## Cleanup

Recorded in [CURRENT_STATUS.md](../../CURRENT_STATUS.md) and the T8 private evidence
directory; regenerable build caches were measured and removed only after their last use.
