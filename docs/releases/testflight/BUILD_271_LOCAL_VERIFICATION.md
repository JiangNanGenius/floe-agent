# Build 271 local hotfix qualification

Version 1.7.30 (271), immutable tag `v1.7.30`, source `bdb79bf8751ba67676e2a57e6916fd6ca8d6d151`.
Local Xcode 27.0 (27A266a), iOS Simulator 27.0, compatibility deployment target iOS 26.

## Executed checks

- Complete App Debug compilation succeeded. Initial 42 provider/save regressions passed; after adding punctuation coverage, 43 relevant tests passed with zero skips.
- iPad save/relaunch UI acceptance passed. iPhone save/relaunch acceptance passed after correcting the test to open the compact sidebar; the initial navigation failure remains recorded.
- A complete custom Chat Completions provider was saved through the real App UI: name `DeepSeek_v4.1-compat-test`, model ID `deepseek-v4-flash`, display name `DeepSeek_v4.1-Flash`, enabled text/tool support, default model, context 131072 and maximum output 4096. Model IDs and display punctuation survived storage unchanged.
- Real provider discovery returned two models. Credentials were entered only in the authentication field, persisted in Keychain, and successfully reused after reopening the provider. After restarting the App, the configured model returned the synthetic expected response `FLOE271OK` and the turn completed. SQLite readback independently confirmed the configuration and limits.
- The initial real-key save failed because the unsigned simulator executable lacked simulated Keychain entitlements. A locally signed arm64 simulator build resolved that test-environment failure. No production Keychain policy was weakened.
- Localization catalog, native-runtime project audit, pinned Office artifact and release preflight passed. The existing unqualified Office capabilities remain unqualified; this hotfix does not change Office.

## Limits

Physical BLE authorization and accessory connections were not exercised. Apple supplied no crash-feedback submissions for the inspected previous builds, so a unique field-crash cause is not established. This release defers CoreBluetooth startup authorization and rejects malformed GATT UUIDs before the exception-raising API. Simulator tests do not establish physical-device acceptance or iOS 26 runtime acceptance.

The local Release device archive succeeded with six compiler jobs. App/dSYM UUID: `DC35A10D-5E43-39A8-9C2C-B90EADF425D1`; App executable SHA-256: `b2369b77376bc7c3801df6e84a56b719bbf235a271a244f25a22d9e52cfd552b`. The retained normalized device transport is 859765102 bytes, SHA-256 `052290d8038db81184e6e05203906952fe0c1b841c3cc7a53d75689b2beb7892`. The original archive and matching symbols are retained; packaging did not change the executable. Distribution reuses this artifact without recompilation. Apple states are recorded after confirmation; no full cloud test matrix is required.

## Apple delivery confirmed · 2026-10-12 05:48 UTC

[Signing/upload run 38208178806](https://github.com/JiangNanGenius/floe-agent/actions/runs/38208178806) reused the retained local artifact without an App rebuild. All eight private transport parts matched their local size and SHA-256 before signing; the runner also verified the combined archive SHA-256. Signing, package validation and upload succeeded. Apple build `18c767e2-d974-40a2-86de-505c151e3382` is `VALID`, unexpired and `IN_BETA_TESTING` in existing Floe QA.

The authenticated web submission added this build to existing publictest1. [Independent GET-only inspection 38209568536](https://github.com/JiangNanGenius/floe-agent/actions/runs/38209568536) confirmed `WAITING_FOR_BETA_REVIEW`, one `pending_review` submission, attached external group, matching 3865-character review notes, complete EN/ZH testing notes and zero issues. External installation is pending Apple approval. Build 269 remained internal-only.

Signed upload recovery is retained in private workflow artifact `testflight-1.7.30-build271` (ID `11728985389`); local exact-source xcarchive, matching symbols and normalized transport are retained. Finished task-only simulator/device caches and transfer chunks were removed after exporting evidence: measured free-space increase 12,635,705,344 bytes (about 11.8 GiB), excluding unmeasured duplicate staging removal. Simulator apps/data/Keychain and unrelated artifacts were preserved; no devices remain booted.
