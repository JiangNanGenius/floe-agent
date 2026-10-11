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

The one authorized **API** submission ([38139521326](https://github.com/JiangNanGenius/floe-agent/actions/runs/38139521326))
was refused by Apple at the first write — `PATCH /v1/betaAppReviewDetails/6801209053`
— with **HTTP 403 `FORBIDDEN_ERROR`**: the API credential can read the build and
group state but cannot write the app-level beta review detail (final review
notes). The helper is fail-closed; nothing was attached and nothing was
submitted. A post-failure GET-only readback
([38139655286](https://github.com/JiangNanGenius/floe-agent/actions/runs/38139655286))
confirmed zero partial writes (`READY_FOR_BETA_SUBMISSION`, count 0). This
first 403 attempt and the draft-marker validator failure
([38139250336](https://github.com/JiangNanGenius/floe-agent/actions/runs/38139250336),
before any Apple call) are retained as history.

The submission then completed through the existing authenticated App Store
Connect web flow: the final review notes were saved and read back at 3,588
characters, matching the repository file exactly (the file is 3,588 bytes
including its single trailing newline; the API helper compares the stripped
3,587-character text, which is why its report shows an exact-string mismatch
while the browser readback matches). Build 270 was attached to the existing
`publictest1` group and submitted once
(`WEB-SUBMISSION.json`, primary screenshot 36).

Independent GET-only API readback
([38141425415](https://github.com/JiangNanGenius/floe-agent/actions/runs/38141425415))
confirms: `VALID`, `expired false`, `APP_STORE_ELIGIBLE`, `IN_BETA_TESTING`,
`publictest1` `attachedToBuild true`, submission count 1 with `pending_review`,
external state **`WAITING_FOR_BETA_REVIEW`**, `ok true`. External approval is a
separate gate and is **not** claimed; nothing is externally installable until
Apple approves. No public-link, group or permission change was made.
<!-- /EXTERNAL-STATE -->

## Documentation and website sync

- `docs/CURRENT_STATUS.md`, the bilingual unified-design migration pages, the docs index and
  `docs/releases/notes/RELEASE_NOTES_1.7.29_BUILD_270.md` were updated on `main` (commits
  `13d4dfc0`, `880004f1`, `a8383379`) to state the observed facts: internal availability,
  the API 403 external-submission block, and the precise iPad layout qualification.
- The private website source (commit `b136881`) adds the two migration routes to the
  public PAGES map and re-renders all ten public documents from `a8383379`. Deployed image
  `floe-official:1.2.29-docs270`
  (`sha256:38507a8c286b4837dea70276cbadaf4695811393c22884372f5d35c4d8e2bc15`),
  rollback `floe-official:rollback-pre-docs270-20261011T124001Z` and
  `backups/deploy-docs270-20261011T124001Z`.
- Origin and public `/healthz` both `ok`; all eleven checked files (`status.html`,
  `unified-design-zh/en.html`, `zh/en.html`, `index.html` and five Markdown downloads)
  matched byte-for-byte across local, origin loopback and public HTTPS
  (`website-verify.json`, `all_match: true`).

## Cleanup

- Removed the task's build cache `~/Library/Caches/CodexBuild/FloeAgent/t7c-local`
  (11,891,828 KB / ~11.34 GiB) after checking no process held it open; the internal data
  volume gained 10,864,300 KB (~10.36 GiB) of reported free space (`df -k` before/after
  recorded in the T8 evidence). The one-off `Local/Scratch/t8-device-build.log` was
  removed after exporting a copy into the T8 evidence directory.
- Retained: `Local/Artifacts/build270` (raw device app + normalized transport + provenance,
  matching the build269 retention shape), all T1–T8 evidence, the draft transport release,
  the immutable tag and the previous build 269 artifacts as the rollback version.
- No simulator was booted, installed to, shut down or deleted by this task. The booted
  iPhone 18 Pro `ED94CEF5` was started at 20:39 by an unrelated `CallRelay.xcodeproj`
  test run (`xcodebuild` pid 94307, its own cache path) and was deliberately left
  untouched. The retained iPad `6366F0FB` was released and shut down by the primary.
