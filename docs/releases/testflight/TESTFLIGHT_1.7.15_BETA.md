# Floe Agent 1.7.15 (256) delivery

## Immutable source

- Tag: `v1.7.15`
- Source: `98d50a5475a7c9dd84ed5a3f1dc800fb8ca9d098`
- Bundle: `org.floeagent.ios`
- The stability branch was merged into `main` and pushed on 2026-10-05; its merged local and remote branch references were removed.
- Release preflight passed, including bilingual copy, four target versions, localization and the pinned Office host.

## Live delivery gates

- [Release workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/37267032312): running; normal qualification route, no requested test waiver.
- [Immutable-tag CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/37267499177): running.
- [Pre-upload Apple inspection](https://github.com/JiangNanGenius/floe-agent/actions/runs/37267184006): no Build 256 present yet; inspection exits nonzero when the expected build is absent.
- Signed upload, Apple processing, internal Floe QA availability, external `publictest1` review and Feather distribution remain pending.

## Changes and acceptance

See [release notes](../notes/RELEASE_NOTES_1.7.15_BUILD_256.md), [focused repair evidence](../repairs/FLOE_256_STABILITY.md), and [external review copy](../../public-beta/build256/README.md).

Full App compilation and the local terminal simulator screenshots were retained before release preparation. Physical iPad Linux recovery, Office continuous strokes/save/reopen and crash diagnosis remain separate acceptance items. The available conversation export is not an iOS crash stack.
