# Build 241 external/public TestFlight materials

Status: **Build241 submitted for external TestFlight review; waiting for Apple approval.** The normal [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0) remains bound to immutable `v1.7.0` / source `1ddd8e81a6019e2e7e1d3053ef7c88eb5284f31b`. No App rebuild, upload or tag change was needed.

**Privacy policy:** bilingual [PRIVACY.md](../../../PRIVACY.md) is published on public `main` (policy commits through `56ec29bf`, effective 2026-10-02) at <https://github.com/JiangNanGenius/floe-agent/blob/main/PRIVACY.md>, the raw content anonymously verified over HTTPS against the repository (sha256 `63661fa9fa007cd9026677891e4128cfef43d192d480b2e021be34ede9369fff`). This URL was used in both submit attempts. If GitHub's rendered blob page is unavailable (its frontend served an outage/Unicorn page during one 2026-10-02 check while the API was healthy), the raw fallback verified HTTP 200 on 2026-10-02 — same bytes, anonymous HTTPS — is <https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/PRIVACY.md>; Apple's URL field takes one address, so the GUI submission used the verified raw URL.

**Earlier API submission attempts (2026-10-02, before the GUI submission below):** the fail-closed helper was run through `public-testflight.yml` in [run 36977707786](https://github.com/JiangNanGenius/floe-agent/actions/runs/36977707786) and [run 36978183559](https://github.com/JiangNanGenius/floe-agent/actions/runs/36978183559). Both failed identically at the first metadata write, `PATCH /v1/betaAppLocalizations/{id}`, with sanitized Apple error **HTTP 403 `FORBIDDEN_ERROR`**. The same API key can read all TestFlight resources and can write build-level beta localizations and the internal group, The app-level write was forbidden for the current API credentials; the exact account-role or endpoint restriction was not established by this error alone. The [final read-only inspect 36978473975](https://github.com/JiangNanGenius/floe-agent/actions/runs/36978473975) (exit 0, `ok: true`) proves no partial write occurred: zero `betaAppReviewSubmissions`, build unattached to `publictest1`, public link disabled, privacy URL still unset, zh-Hans beta app localization still absent, review notes/demo flag unset. Build What's-New is bilingual from the private delivery.

## GUI submission completed on 2026-10-02

After the user signed in, the GUI saved English and Simplified Chinese beta descriptions, the verified raw [privacy policy URL](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/PRIVACY.md), and concise English review notes covering the prepared walkthrough. Existing feedback and review-contact details were retained. No Floe account or demo login is required. Build241 was added to the existing external group `publictest1` and submitted once; automatic tester notification was disabled.

Independent GET-only [inspect 37000944505](https://github.com/JiangNanGenius/floe-agent/actions/runs/37000944505) passed at 11:25:57 UTC: one `pending_review` submission, external `WAITING_FOR_BETA_REVIEW`, attached to `publictest1`, `VALID`, unexpired, `APP_STORE_ELIGIBLE` and internal `IN_BETA_TESTING`. Both beta app locales have descriptions and the same privacy policy URL; required metadata is complete and `demoAccountRequired=false`.

The GUI then enabled and read back the public link: **<https://testflight.apple.com/join/nz6qeT2J>**. Apple explicitly says testers cannot join until this group has an approved build. The API readback preceded this link change and correctly recorded it as disabled then. **Submitted and link created do not mean approved or publicly installable.** No new group, tester invitation or App Store production action was performed.

双语资料、隐私政策和审核备注已保存，Build241 已提交现有 `publictest1` 外部测试组，当前“正在等待审核”。公开链接已建立，需 Apple 审核通过后才能加入。原始 API 403 失败与提交前零部分写入证据保留，已不再是当前提交状态。

## Prepared product text

| File | Purpose |
| --- | --- |
| [whats-new.json](whats-new.json) | Bilingual What to Test, matching the Build 241 release input. |
| [beta-description.json](beta-description.json) | Bilingual Beta App Description. |
| [review-notes.en-US.md](review-notes.en-US.md) | Final English review instructions; no Floe account or demo login is required. |
| [review-notes.zh-Hans.md](review-notes.zh-Hans.md) | Matching Chinese review instructions. |
| [unverified-fields.json](unverified-fields.json) | Verified facts, evidence boundaries and remaining submission inputs. |

Both reference files pass the existing 1..4000-character and placeholder checks. The GUI submitted a concise English version (1,365 characters) and read it back; it is not byte-identical to the longer reference file.

## Verified on 2026-10-02

- A genuine local FloeApp simulator run passed the repaired PowerPoint slideshow flow, including changing slides, returning to editing, idle, saving and reopening. The 22 phases, nine GUID-bound frames, trace and four-slide persistence gates passed. The merged Build 241 App passed the same complete scene at source e8a62b03. New device-host [run 36957310043](https://github.com/JiangNanGenius/floe-agent/actions/runs/36957310043) passed and its retained full ZIP was pinned after source, resource, provenance and actual arm64 IOS platform checks. These results do not replace physical-device feedback.
- Linux VM qualification [run 36953899923](https://github.com/JiangNanGenius/floe-agent/actions/runs/36953899923) passed S0–S5. Equal-workload median elapsed time was 1.94 seconds with one hart and 1.32 seconds with two, about 1.47× faster. These are qualification results, not a physical-device speed guarantee.
- Actual Settings/local-model UI captures show downloaded MLX models as Beta / Experimental and not recommended as the daily default. Apple's system model remains separate. This does not qualify real MLX inference or every tool.
- Shared Apple metadata was inspected with GET-only [run 36952958653](https://github.com/JiangNanGenius/floe-agent/actions/runs/36952958653) and [run 36955676879](https://github.com/JiangNanGenius/floe-agent/actions/runs/36955676879), then [36978473975](https://github.com/JiangNanGenius/floe-agent/actions/runs/36978473975). Those earlier inspections found one existing external group named `publictest1`, then disabled and unattached. The GUI submission and newer readback above supersede that state. All four review-contact fields and the existing en-US feedback email are present. Their values are not included here.
- The published [PRIVACY.md](../../../PRIVACY.md) URL is ready for the beta-app Privacy Policy URL field. The GUI completed the zh-Hans beta localization, no-login confirmation, review notes, group attachment and submission; independent GET readback verified them. The AppInfo (App Store page) privacy URL and the App Privacy "nutrition label" declaration are separate fields and were not written by this task.

Historical Build 191 materials and the Build 240 delivery record remain historical. No old artifact or editor-only run substitutes for the new slideshow/source qualification.

## Submission path

[`public_testflight.py`](../../../FloeAgent/scripts/public_testflight.py) and [`public-testflight.yml`](../../../.github/workflows/public-testflight.yml) retain the immutable tag/source, bundle/version/build, IOS platform, VALID/unexpired status, APP_STORE_ELIGIBLE audience, unique existing external group, pagination and readback gates.

The default `inspect` is GET-only. Explicit `submit` needs `confirm=submit-external-review` and a final review-notes path. Its optional metadata completion supports explicit no-login confirmation, localization creation from existing feedback settings and the caller-confirmed privacy URL. The GUI has already completed those fields for this build. No contact details, credentials or policy address will be invented. Duplicate pending/approved submissions are reported without a second POST; rejected recovery remains explicit.

The source and verified IPA are frozen. The GUI submission reused the immutable tag SHA, Build241 and existing verified IPA. Do not submit again while its review is pending. The metadata report alone does not verify IPA bytes. Apple writes, group attachment, review submission and any public-link change must be checked through their actual readbacks.

A successful review submission can remain pending. Report the public test as installable only when Apple approves the intended VALID, unexpired build and it is available to the intended external group. Pending GUI login does not block authorized API operations using existing credentials.
