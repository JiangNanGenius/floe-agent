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
