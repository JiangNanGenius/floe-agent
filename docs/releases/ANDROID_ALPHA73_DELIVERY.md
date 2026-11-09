# Android Alpha73 preparation — 2026-11-10

Planned version: `0.1.0-alpha.73` / code99. This record starts at the verified source-checkpoint stage; it does not claim an APK, device fill or public release yet. The immutable source will be the matching `android/v0.1.0-alpha.73` tag when qualified for publication.

## Changes / 更新

针对 Alpha72 首次实测暴露的漏传观察凭据问题，明确所有非启动动作的 `observationId` 要求，并将这一情况与其他无效参数区分。保留从当前已授权页面启动应用的兼容通路、既有观察新鲜度、任务／应用／窗口授权和敏感输入保护。

新装应用在活动恢复时重新读取列表；手机设置的中英文边界文案与已授权已知密码填写保持一致。App、运行组件、Office／CAD 组件和对应源码链接统一为本轮版本。

The phone contract now leads with the observation-token requirement for every non-launch action and returns a precise missing-observation code. Authorized launch compatibility, freshness, ownership, window checks and sensitive-input protection remain. Installed apps refresh on activity resume, and the phone-boundary copy matches authorized known-password entry. Matching App/runtime/preview/source-offer versions advance together.

## Source qualification / 源码检查

- 27 focused App JVM cases passed, including 9 new observation-contract cases plus sensitive-input, catalog and bounded-error regressions. Actual Full/Play Kotlin compilation passed; original results and exact input hashes were retained.
- The actual shared schema validator accepts a closed keyword subset. Conditional-schema keywords would invalidate the whole tool catalog, so this change uses the supported catalog guidance and enforced host rule; it does not advertise unsupported schema validation.
- No shared Swift/native input changed. Reuse of native34 must still pass exact input and package identity checks for the actual candidate; the successful source checks are not a substitute for that artifact proof.
- The failed Alpha72 task remains retired with its original evidence. A new neutral-package local fixture is prepared for a fresh device case; no real account password or provider call was used for this source qualification.

## Known issues / 已知问题

The new APK and end-to-end password fill remain pending at this source stage. Sony XZ/Android9 post-extraction startup, fresh download metering, automatic unlock/relock and the other N01–N08 scenarios retain their existing open status. Nothing here rewrites the Alpha72 package, tag or first failed case.

源码检查通过不代表密码填写已完成实机验收。后续使用实际 Full APK，经正常系统安装后另建测试任务；失败保留现场并停止原用例。索尼具体启动根因仍未确认，N01–N08总目标继续。

## Delivery appendix / 交付补记 — 2026-11-10

[Alpha73/code99](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.73) is now public from immutable source `b0722808df5e006b5f035d4a2f43e2a8c1f3490e`. The source-stage statements above describe the frozen preparation stage; this appendix records subsequent production and device evidence.

- The actual Full APK is 164,670,359 bytes, SHA-256 `ff75e3e201e95e9c836e6a5bddec9c90282d05992f20a3f9d3a76bbaf5b06896`. Native34 was reused only after exact input matching. All 58 package bindings, actual API28/29 main/runtime signature checks and exact72→73 host reconstruction passed. These signature checks are not Sony hardware execution.
- Seven allowlisted public assets, their immutable tag/source binding and anonymous download bytes were read back. Actual compiled current and retained65 update parsers discover this prerelease and its complete known issues. The later device note changes only release-body text; all seven asset identities and iOS Latest remain unchanged.
- Samsung used “下载完整更新” in public Alpha72, downloaded the complete APK through its selected GH-Proxy route and accepted the normal runtime/main system confirmations and Play Protect scan. Both installed packages are code99 with exact published bytes and their original UIDs. Five baseline task rows and both project names remain visible. No ADB replacement, downgrade or uninstall of Floe was used.
- The new local test app appeared after activity resume in the same Floe process. A fresh Ark Plan / `ark-code-latest` run performed three phone actions and one observation; every tool result was successful. The protected field exposed metadata only, each non-launch action used its matching fresh observation, and the actual fixture returned PASS. The exact 49-record export was read back before removing its device copy. Durable tool input is redacted; the public synthetic text may still appear in user text/model summaries. The prompt explicitly requested observation tokens, so no natural-prompt or real-account-password qualification is claimed.
- The single test task, fixture and verified device export were removed. Five baseline tasks remain; app scope, automation, accessibility and temporary power settings were restored, and the phone was put to sleep. The failed Alpha72 case remains separate and retired.
- Twenty finished packaging outputs and two source/delta staging directories were retired after exporting exact assets and eight producer receipts. The two whole-volume deletion windows measured 3,169,742,848 bytes of additional internal free space; concurrent APFS activity can affect that measurement. Current73, required72 rollback, native34 symbols, original failures, SDK/AVD and useful warm dependencies remain.

三星真实完整包升级、同进程应用列表刷新和本地密码填写链路已通过；工具记录脱敏的验证边界如上。源码、标签和公开安装字节固定，测试残留及过期构件已清理。索尼XZ／Android9解压后的具体启动根因、新下载计量、自动解锁／重锁及其他N01–N08事项仍开放，整轮目标继续。
