# Android Alpha57 / code83 delivery

[Published Android prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.57). N01–N08 remains active. iOS Latest stays on the iOS channel.

## Immutable source and package

- App source: `f8b6df6d94d2e0b1557189e8c6a3f8eb0e0aa71d`.
- Full ARM64 APK: `Floe-Android-0.1.0-alpha.57-full-arm64-v8a.apk`, 164,221,791 bytes.
- SHA-256: `34cfc93b1021851f96ccf6c8154daeb56e15d39293c700dc78858f8a02d6bd4c`.
- Native19 producer source: `40814e557ef586dea07367a24c0b8c66dcb81c4c`; native inputs matched the App snapshot. Both changed ARM64 products were object-compiled and linked, with exact raw libraries and symbols retained.
- Related Full/Play Kotlin compilation, 12 JVM regressions and four native host contracts passed. Full packaging, signature/version, ARM64/JNI, native strip/allocated-section identity and 16KiB checks passed. Unchanged component evidence was reused.

## Implementation and Samsung boundary

`workspace.externalEdit` now connects the ordinary model tool registry to the existing Android editor service. Open/status/finish/cancel retain task and workspace ownership, file access, save checks, conflict handling and recovery copies. Claimed native work drains before retirement. An uncertain launch acknowledgement cannot be silently replayed under another model call.

An untouched file remains editing rather than being labelled saved. A previous verified modification remains recorded; incomplete source saves remain pending. Twelve JVM regressions include restart and unknown-launch recovery. Four native contracts cover the real registration/dispatch, trusted ownership, cancellation and settlement path.

Samsung received the exact main APK and its embedded runtime83 through ADB multi-package update. Installed bytes matched the saved artifacts; both original UIDs and existing project/task data were preserved. This qualifies engineering installation, not a new App online-install run.

A fresh authorized Ark `ark-code-latest` task discovered the actual tools and opened its empty project file in X-plore. The native receipt reported launched=true, saved=false and completed=false. Phone observation then waited for the real user-presence answer. After answering in Floe, the model launched X-plore's main page. A subsequent node click required manual approval because no approval model was configured. Returning to Floe and answering presence confirmation made that old observation stale; dispatch refused it. The exported run contains six tool results, five successful and one failed, with no tool requests after the first failure. It retained the external-editor session and did not attempt typing or Save.

**Automatic external editing did not pass.** The workflow must arrange screen handover before opening the editor and handle approval without acting on an old page. Freshness, owner, lock-screen and protected-page checks remain required. The prior Alpha56 manual edit and actual model read-back are separate successful evidence, not a substitute for this failed automation case.

Temporary accessibility, selected control apps, automatic phone control and stay-awake settings were restored. Auto-unlock and floating controls stayed off; no lock credential was enrolled. No emulator was used for this case.

## Publication and updates

All seven allowlisted attachments were independently downloaded without authentication and matched their actual byte counts and SHA-256. The annotated tag binds to the frozen App source. The production updater classes executed against the live anonymous release list, selected Alpha57 from Alpha56, read the checksum/manifest and displayed the known issues; an already current Alpha57 has no newer candidate. iOS Latest remained `v1.8.5` at read-back.

The actual Alpha56/code82→Alpha57/code83 delta reconstructed the exact target APK with matching version and signer checks. Full-package downloads remain available across versions. The updater itself is unchanged from Alpha55's real Samsung mirror-switch/download/system-install evidence; no new Alpha56→57 online installation is claimed.

Assets remain one main APK plus the Office/CAD components, checksum, delta/manifest and matching corresponding-source archive. Original failed private evidence is excluded. The release description includes the actual automation failure; immutable source and package bytes stay fixed.

## Cleanup and next work

Completed source stages and exact redundant artifact copies were retired after export: two external-volume cleanup events measured 279,228,416 and 138,145,792 bytes reclaimed. Nineteen completed merge/strip/package copies measured 2,713,366,528 internal bytes reclaimed. These are event measurements; concurrent work can change later free space. Current/rollback packages, original failures, source, native symbols, SDK/AVD/user data and caches with a concrete next use remain. APFS clones and hard links are not independent backups; retired staging paths are no longer valid inputs.

Next: repair the authorized model/native-editor continuation, continue the existing scheduling/background and project-software cases, and finish the remaining lightweight previews and shared UI work. Do not replay this failed run, weaken observation checks, restart the full 183-item audit or add independent iOS heavy editors to this round.

---

Alpha57/code83已公开，固定源、精确包、七附件完整字节及实际生产更新发现均已读回，保留iOS Latest。新增模型原生编辑器通路并修正未修改文件误报保存；三星联合工程安装及模型实际打开X-plore通过。后续点击因人工审批后的界面记录过期被拒绝，自动填写／保存尚未通过；原始六次工具回执和恢复会话保留，首次失败后无重试。临时权限与配置已恢复。完成暂存已清理，整轮N01–N08继续。
