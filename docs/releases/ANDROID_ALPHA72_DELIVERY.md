# Android Alpha72 delivery — 2026-11-10

Android `0.1.0-alpha.72` / code98 is an intermediate GitHub prerelease. The N01–N08 goal remains active.

## Source and package / 源码与安装包

- Immutable source: `48a44a19226fce1fa59fdff7e8e0f947513a6d10`; native34; one actually built Full ARM64 APK.
- [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.72).
- APK: `Floe-Android-0.1.0-alpha.72-full-arm64-v8a.apk`, 164666423 bytes.
- SHA256: `1c61b8a72f69bab98eda9eeabc1a56dcb0170d87de3806dfda9e2d4c2648ffc3`.
- Seven clean assets: one APK, matching optional Office/CAD components, verified71→72 delta, checksums, update manifest and corresponding source. iOS Latest remains `v1.8.6`.

## Changes / 更新

已授权任务可通过现有手机工具填写已提供的密码，不读取密码框已有内容。工具卡片、保留事件与恢复记录使用脱敏副本；实时执行保留原始输入，未结算的敏感输入不会从脱敏记录自动重放。旧记录兼容读取，已结算取消保留原拒绝回执。

Linux 下载解压完成但终端仍不可用时，按真实就绪状态提供重新检查和可复制的诊断详情，保留已安装环境及用户文件。普通界面继续区分“安装完成”和“终端可执行”。

Authorized tasks can enter supplied passwords through the existing phone tool without reading protected contents. Tool cards, retained frames and durable recovery records use scrubbed copies; live dispatch preserves exact input. Unpaired sensitive input is not replayed from redacted history; older checkpoints and settled cancellation receipts remain readable.

Post-extraction Linux recovery exposes a real readiness recheck and copyable diagnostic details, preserving the installed environment and user files. Archive completion remains distinct from terminal readiness.

## Qualification / 验证

- 60 focused cases passed: 25 phone-policy/field cases, 10 sanitizer cases, 5 actual runtime/checkpoint/SQLite/facade cases and 20 App argument/catalog/recovery cases. Unchanged input evidence is reused without rerunning it.
- Actual ARM64 native production objects/linking, Full/Play release Kotlin, 58 raw/packaged native bindings, 16 KiB/package checks and exact App/runtime APK signatures under API28/29 verification passed.
- The71→72 host delta reconstructed the exact target APK. All seven anonymous public downloads, asset digests, immutable tag/source and the current/retained Alpha65 production discovery parsers passed read-back.
- Samsung completed a real public71→72 in-App update, including both Android installation confirmations and the normal PlayProtect scan. Main/runtime code98 installed bytes match the public payloads; original UIDs remain. No engineering replacement, downgrade or uninstall was used for Floe.
- Samsung reopened the original five tasks, two projects and existing installed Linux environment. The actual device transfer mode was not captured; host delta reconstruction is separate evidence.

## Limits and follow-up / 限制与后续

Sony XZ/Android9 post-extraction startup remains unconfirmed. This release supplies the recheck/diagnostic path, not a claim that the customer's hardware failure is fully repaired. Fresh Linux-download metering and automatic unlock/relock still need their own hardware evidence.

索尼的具体启动根因仍待实际诊断；不能把新入口、Android9签名检查或三星已有环境当作索尼恢复证据。整轮其余定时、跨 App、图形与恢复场景继续逐项修复。

The first Samsung known-password fixture run used only Ark Plan / `ark-code-latest`. Observe, launch and fresh observe succeeded; `setText` omitted the required `observationId` and was rejected as `invalid_arguments`. It stopped on that first tool failure, without retry, provider switch, Verify click or PASS. The original 49-record export was saved and byte-checked before the task, fixture and device export were removed. Accessibility, app scope and temporary power settings were restored. The failed fill is not device-qualified; the tool-contract repair continues. No real account password was used.

首次填写实测未通过；原始失败保留，公开“已知问题”已追加这一结果。工具记录中的敏感输入已脱敏；用户自己输入的假密码测试消息不作为工具记录泄露。不能用单元检查或成功打开 App 代替完整填写验收。

Two small corrections discovered after publication are source follow-ups, **not included in the immutable Alpha72 APK**: refresh the installed-app list on activity resume, and align the old phone-boundary footer with authorized known-password entry. Their Full/Play Kotlin and affected XML compilation passed; the next APK will carry them.
