# Android Alpha32 delivery

- Release: [Android 0.1.0-alpha.32](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.32), code51, GitHub Full prerelease. iOS Latest remains `v1.7.74`.
- Frozen source: `2a5e53a84a06eeb70c138c3bd9bd2d6f31a7eae2`.
- Full ARM64 APK: 163,793,563 bytes, SHA-256 `c12fc7edc2b2ac7badd082b138bd41ae4e65f36bf9dce7283d0673682f639376`.
- Six assets: one APK, optional Office component, corresponding source archive, checksums, delta and delta manifest. Tag/source binding, remote digests and all anonymous public download bytes matched.
- Full release compilation, package/signature, ARM64/16 KiB and 58 native-byte binding checks passed. Relevant Full/Play compilation and four graphical-startup checks passed; unchanged native production evidence was reused.

## Actual Samsung incremental update

Samsung SM-G9810, Android 13/API33, started from the exact public Alpha31/code50 APK. The App prepared the target using the smaller 44,582,123-byte patch, verified the resulting APK, and presented separate system confirmations for Floe and the installed runtime. Play Protect scanned the runtime and allowed installation. The App then displayed “Update installed.” Both packages became code51; actual installed main and embedded-runtime bytes matched the saved target, and their original UIDs were preserved. No ADB installation was used for this update.

This is device incremental acceptance for public Alpha31→32. Alpha31 already has separate full-download installation evidence. The original public Alpha30 lost-confirmation failure remains recorded and may need the documented one-time manual transition; it is not retroactively repaired by these results.

## Functional work continues

Graphical startup failures now preserve a bounded stage and exit code, and local session details can be copied. These paths still need device acceptance. Ordinary task/tool/provider errors remain excluded from automatic reporting; the original four-image upload timeout and missing TIFF preview remain recorded. Global typography, density and control sizing remain deferred until functional wiring is complete.

The user authorized enabling Floe accessibility only for this round of Samsung cross-App QA, without persistent auto-unlock credentials. The correct service was enabled through Samsung Settings. A new fault was observed: Android reports the service enabled and bound, while Floe settings still says “Not granted.” This detection issue is being investigated before making a model control call. The authorization will be restored to its prior state after the bounded QA batch. No new LLM, image or video call was made during this release/update check. The complete N01–N08 goal remains active.
