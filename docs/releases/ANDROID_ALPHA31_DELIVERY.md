# Android Alpha31 delivery

- Release: [Android 0.1.0-alpha.31](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.31), code50, GitHub Full prerelease. iOS Latest remains `v1.7.74`.
- Frozen source: `96d16c2db7bfc7595b74150ed51a597798e3a7da`.
- Full ARM64 APK: 163,779,127 bytes, SHA-256 `0fdc613434bd99ef1353cf7397f29658a599b91c248b8961d8a2826d572602f8`.
- Six allowlisted assets: one APK, optional Office component, corresponding source archive, checksums, delta and delta manifest. Published tag/source binding, remote digests and all anonymous download bytes matched; later body-only acceptance updates retained those assets.
- Local Full release build, pinned native byte binding/ARM64/16 KiB/package/signature checks passed. The callback repair passed Full/Play compilation and four focused ownership tests. Unchanged native production evidence was reused from identical inputs.

## Actual Samsung evidence

On Samsung SM-G9810, Android 13/API33, the App downloaded and verified the public full APK, then presented the main App and runtime system confirmations. Play Protect scanned the runtime and allowed installation. Both installed packages became code50 with exact public main/embedded-runtime hashes; their original UIDs remained unchanged. The App displayed installation complete. Existing task history reopened and actual terminal commands printed `FLOE_OTA50_TERMINAL_OK` and `FLOE_OTA50_DONE`; the owned terminal tab was closed afterwards.

The starting code49 updater was a private fixture containing the callback fix, installed separately by ADB. The code50 installation itself used the actual App online flow, with no ADB installation. This proves that fixed flow on this device; an already affected old public Alpha30 installer still needs the documented manual transition. The device used a full APK because its private base hash differed. Public Alpha30→31 delta production reconstructed exact signed bytes on the host; device delta reconstruction remains unverified.

## Remaining scope

The whole N01–N08 goal remains active. Phone pause/resume, real condition-trigger execution, the correct project GUI/software environment and remaining feature/device flows still require acceptance or repair. A network-condition QA schedule was saved, reopened and explicitly paused; no new model/provider/paid call occurred. No persistent auto-unlock credential was configured.

The selected older task terminal did not find `inkscape`; this is not proof that the separate previously tested GUI environment lost its installation. Compare actual environment ownership before drawing that conclusion. The synthetic CAD fixture is retained for the project CAD entry; the global Office picker does not accept STL. Global UI sizing/density work remains deferred until functional wiring is complete. Existing large-image report timeout evidence is retained.
