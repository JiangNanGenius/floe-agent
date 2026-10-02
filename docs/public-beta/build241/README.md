# Build 241 external/public TestFlight materials

Status: **Build241 delivered; privacy policy published; external review not yet submitted — blocked on an App Store Connect key permission (human step).** The normal [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0) is published at immutable `v1.7.0` / source `1ddd8e81a6019e2e7e1d3053ef7c88eb5284f31b`. The accepted-SDK device App and retained full unsigned IPA passed verification. Apple Build241 is VALID, unexpired, `READY_FOR_BETA_SUBMISSION` externally and IN_BETA_TESTING in the existing private Floe QA group. Feather points to the same source/size/hash. Private availability does not mean public installability.

**Privacy policy:** bilingual [PRIVACY.md](../../../PRIVACY.md) is published on public `main` (docs commit `0c522013`, effective 2026-10-02) at <https://github.com/JiangNanGenius/floe-agent/blob/main/PRIVACY.md>, anonymously readable over HTTPS and byte-verified against the repository (sha256 `33c603a6335c9a861a8e6cd1b37601044686de239263b0587baa2d009fa5b4d7`). This URL was used in both submit attempts. If GitHub's rendered blob page is unavailable (its frontend served an outage/Unicorn page during one 2026-10-02 check while the API was healthy), the always-served raw fallback — same bytes, anonymous HTTPS — is <https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/PRIVACY.md>; Apple's URL field takes one address, so the human submitting should confirm the primary rendered page loads first and keep the raw URL as the verified fallback.

**Submission attempts (2026-10-02):** the fail-closed helper was run through `public-testflight.yml` in [run 36977707786](https://github.com/JiangNanGenius/floe-agent/actions/runs/36977707786) and [run 36978183559](https://github.com/JiangNanGenius/floe-agent/actions/runs/36978183559). Both failed identically at the first metadata write, `PATCH /v1/betaAppLocalizations/{id}`, with sanitized Apple error **HTTP 403 `FORBIDDEN_ERROR`**. The same API key can read all TestFlight resources and can write build-level beta localizations and the internal group, so this is a role/authority boundary for app-level beta app localizations, not a validation error. The [final read-only inspect 36978473975](https://github.com/JiangNanGenius/floe-agent/actions/runs/36978473975) (exit 0, `ok: true`) proves no partial write occurred: zero `betaAppReviewSubmissions`, build unattached to `publictest1`, public link disabled, privacy URL still unset, zh-Hans beta app localization still absent, review notes/demo flag unset. Build What's-New is bilingual from the private delivery.

**Remaining human step:** a team member with App Store Connect App Manager/Admin role (logged-in GUI session; the current browser session is at the Apple login page) sets, in the app's TestFlight metadata: beta app description for en-US and zh-Hans, Privacy Policy URL = the PRIVACY.md URL above, Feedback Email for zh-Hans copied from en-US, Beta App Review contact (already present), Demo Account Required = No, and the prepared review notes ([review-notes.en-US.md](review-notes.en-US.md) / [review-notes.zh-Hans.md](review-notes.zh-Hans.md)), then adds Build 241 to the existing external group `publictest1` and submits for beta review once. After that, re-running the helper `inspect` verifies the state; no new group, public-link enablement, tester invitation, or App Store production action is part of this task.

## Prepared product text

| File | Purpose |
| --- | --- |
| [whats-new.json](whats-new.json) | Bilingual What to Test, matching the Build 241 release input. |
| [beta-description.json](beta-description.json) | Bilingual Beta App Description. |
| [review-notes.en-US.md](review-notes.en-US.md) | Final English review instructions; no Floe account or demo login is required. |
| [review-notes.zh-Hans.md](review-notes.zh-Hans.md) | Matching Chinese review instructions. |
| [unverified-fields.json](unverified-fields.json) | Verified facts, evidence boundaries and remaining submission inputs. |

Both review files pass the existing 1..4000-character and placeholder checks. Preparing them does not submit them.

## Verified on 2026-10-02

- A genuine local FloeApp simulator run passed the repaired PowerPoint slideshow flow, including changing slides, returning to editing, idle, saving and reopening. The 22 phases, nine GUID-bound frames, trace and four-slide persistence gates passed. The merged Build 241 App passed the same complete scene at source e8a62b03. New device-host [run 36957310043](https://github.com/JiangNanGenius/floe-agent/actions/runs/36957310043) passed and its retained full ZIP was pinned after source, resource, provenance and actual arm64 IOS platform checks. These results do not replace physical-device feedback.
- Linux VM qualification [run 36953899923](https://github.com/JiangNanGenius/floe-agent/actions/runs/36953899923) passed S0–S5. Equal-workload median elapsed time was 1.94 seconds with one hart and 1.32 seconds with two, about 1.47× faster. These are qualification results, not a physical-device speed guarantee.
- Actual Settings/local-model UI captures show downloaded MLX models as Beta / Experimental and not recommended as the daily default. Apple's system model remains separate. This does not qualify real MLX inference or every tool.
- Shared Apple metadata was inspected with GET-only [run 36952958653](https://github.com/JiangNanGenius/floe-agent/actions/runs/36952958653) and [run 36955676879](https://github.com/JiangNanGenius/floe-agent/actions/runs/36955676879), then [36978473975](https://github.com/JiangNanGenius/floe-agent/actions/runs/36978473975). Exactly one existing external group named `publictest1` exists; its public link is disabled and Build 241 is not attached. All four review-contact fields and the existing en-US feedback email are present. Their values are not included here.
- The published [PRIVACY.md](../../../PRIVACY.md) URL is ready for the beta-app Privacy Policy URL field. The zh-Hans Beta App Localization, demo-account confirmation, beta review notes and group attach/submit still need a role permitted to write app-level TestFlight metadata (current key: HTTP 403 FORBIDDEN_ERROR; see status above). The AppInfo (App Store page) privacy URL and the App Privacy "nutrition label" declaration are separate fields and were not written by this task.

Historical Build 191 materials and the Build 240 delivery record remain historical. No old artifact or editor-only run substitutes for the new slideshow/source qualification.

## Submission path

[`public_testflight.py`](../../../FloeAgent/scripts/public_testflight.py) and [`public-testflight.yml`](../../../.github/workflows/public-testflight.yml) retain the immutable tag/source, bundle/version/build, IOS platform, VALID/unexpired status, APP_STORE_ELIGIBLE audience, unique existing external group, pagination and readback gates.

The default `inspect` is GET-only. Explicit `submit` needs `confirm=submit-external-review` and a final review-notes path. Metadata completion will confirm `demo_account_required=false`, create the missing localization with the actual existing en-US feedback email, and use only the confirmed privacy-policy URL. No contact details, credentials or policy address will be invented. Duplicate pending/approved submissions are reported without a second POST; rejected recovery remains explicit.

The source and verified IPA are frozen. Once the actual privacy-policy URL is provided, submit with the immutable tag SHA, Build241 and verified IPA digest. The metadata report alone does not verify IPA bytes. Apple writes, group attachment, review submission and any public-link change must be checked through their actual readbacks.

A successful review submission can remain pending. Report the public test as installable only when Apple approves the intended VALID, unexpired build and it is available to the intended external group. Pending GUI login does not block authorized API operations using existing credentials.
