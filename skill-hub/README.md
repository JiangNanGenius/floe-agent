# Official Skill Hub / 官方技能中心

Only `JiangNanGenius/floe-agent/skill-hub` may update the three reserved official
IDs: `floe-pdf`, `floe-office`, `floe-network`. Other guides remain app-owned.
三个官方 ID 仅从本目录更新；其他系统指南随 App 发布。

`sources/` is the source of truth. Each skill has `SKILL.md`, `floe.json`, and
publication-only `release.json` (name, description, minimumAppVersion, bilingual
releaseNotes). `release.json` is not included in the installable ZIP.

`python3 skill-hub/build.py --check` verifies reproducible ZIP bytes, the signed
catalog and generated Swift definitions without a private key. Requires Python
3 and `cryptography`. Change a skill version before changing published content.
ZIPs contain files only (no directory/link entries), sorted, timestamped 1980,
stored without host-dependent compression. Never overwrite a published version.

Publication requires the `FLOE_SKILL_HUB_SIGNING_KEY` GitHub Actions secret. It is
an Ed25519 private key and must never enter source, artifacts, logs, or a skill.
The builder validates it against `public-key.json`. The app pins that public key;
the catalog cannot supply or rotate trust roots. New roots require an app release.

After pushing reviewed source changes to a trusted branch, dispatch the existing
CI workflow on that branch with `publish_skill_hub=true`. The publisher signs and
commits only generated catalog/ZIP/Swift artifacts on the selected branch. Then
run normal CI on the resulting commit; a publisher run is NOT app/release CI.

发布需要 GitHub Actions 签名 Secret；更新审核只授予明确列出的权限。
Skill 包不能分发原生库、运行时或动态安装 App 功能。最低 App 版本不满足时
拒绝安装，先通过 TestFlight/App Store 更新应用。

The publisher/catalog fields reserve a future marketplace boundary. This is
not a third-party marketplace, payment system or native plugin loader.
