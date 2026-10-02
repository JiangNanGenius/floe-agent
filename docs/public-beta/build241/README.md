# Build 241 external/public TestFlight materials

Status: **Build241 delivered; external review not submitted.** The normal [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0) is published at immutable `v1.7.0` / source `1ddd8e81a6019e2e7e1d3053ef7c88eb5284f31b`. The accepted-SDK device App and retained full unsigned IPA passed verification. Apple Build241 is VALID, unexpired and IN_BETA_TESTING in the existing private Floe QA group. Feather points to the same source/size/hash. Public review remains blocked on the actual privacy-policy URL; private availability does not mean public installability.

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
- Shared Apple metadata was inspected with GET-only [run 36952958653](https://github.com/JiangNanGenius/floe-agent/actions/runs/36952958653) and [run 36955676879](https://github.com/JiangNanGenius/floe-agent/actions/runs/36955676879). Exactly one existing external group named `publictest1` exists; its public link is disabled. All four review-contact fields and the existing en-US feedback email are present. Their values are not included here.
- The zh-Hans Beta App Localization, demo-account confirmation and review notes need completion. Both beta-app and AppInfo privacy-policy URLs are absent. The website marketing homepage is not a privacy policy; an actual published policy URL remains a required input.

Historical Build 191 materials and the Build 240 delivery record remain historical. No old artifact or editor-only run substitutes for the new slideshow/source qualification.

## Submission path

[`public_testflight.py`](../../../FloeAgent/scripts/public_testflight.py) and [`public-testflight.yml`](../../../.github/workflows/public-testflight.yml) retain the immutable tag/source, bundle/version/build, IOS platform, VALID/unexpired status, APP_STORE_ELIGIBLE audience, unique existing external group, pagination and readback gates.

The default `inspect` is GET-only. Explicit `submit` needs `confirm=submit-external-review` and a final review-notes path. Metadata completion will confirm `demo_account_required=false`, create the missing localization with the actual existing en-US feedback email, and use only the confirmed privacy-policy URL. No contact details, credentials or policy address will be invented. Duplicate pending/approved submissions are reported without a second POST; rejected recovery remains explicit.

The source and verified IPA are frozen. Once the actual privacy-policy URL is provided, submit with the immutable tag SHA, Build241 and verified IPA digest. The metadata report alone does not verify IPA bytes. Apple writes, group attachment, review submission and any public-link change must be checked through their actual readbacks.

A successful review submission can remain pending. Report the public test as installable only when Apple approves the intended VALID, unexpired build and it is available to the intended external group. Pending GUI login does not block authorized API operations using existing credentials.
