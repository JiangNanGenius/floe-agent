# Floe 1.8.11 (333) delivery

2026-11-12 (Sydney). Source `d797b5ebb28cd91c1a83fe07f0fc42d57fd3076c`, immutable tag `v1.8.11`.

- Internal TestFlight: Apple `VALID`, unexpired, existing **Floe QA** group `IN_BETA_TESTING`, confirmed by a separate Apple GET after the upload workflow.
- GitHub: normal stable/latest unsigned release and its downloaded IPA passed strict source, version, size and SHA-256 verification.
- Feather: the publication workflow awaited its actual feed job; the live feed matched the same source, version and IPA bytes.
- Public TestFlight: **not submitted**. After source freeze, the user deferred public testing to the next update addressing storage growth and proactive structured questions. The retained frozen review copy is not current submission authorization.
- App Store 315 and withdrawn public TestFlight 331 were not changed.

Unsigned IPA: `916594333` bytes; SHA-256 `fbd968094e16e96137ce55f49ebaeb9a759edfe4ca4f01786b5f659f0f1a6328`.

[Release and installer](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.11). [Signing/upload workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/43157320380). [Publication and awaited Feather workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/43161002731).

Qualification reused scoped evidence: 152 distinct selected App tests have a latest passing execution; the final SDK15 batch actually executed 12 of them. Earlier failed results remain retained. The SDK15 App tree was unchanged by the final review-copy-only commit. Focused Simulator flows were checked; no new physical voice or Duo acceptance is claimed. Original App products and all 19 symbol bundles were preserved before packaging. A signed-artifact download timeout was recovered using the exact already-exported artifact, without rebuilding or uploading again.

Storage investigation and structured-question work continue in the [stable-fix ledger](../../FLOE_IOS_STABLE_FIXES_20261112.zh-CN.md). Their later changes do not alter this tag or installer.
