# Android 1.0.8 (116) delivery — 2026-11-14

Published independently as a [GitHub Full prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v1.0.8). The Android release preserves iOS Latest (`v1.8.24` at read-back); no iOS tag or distribution setting was changed.

## Immutable source and installer

- Source/tag: `861c856cdbf844c3543936a36e846fb55c507061` / `android/v1.0.8`.
- APK: `Floe-Android-1.0.8-full-arm64-v8a.apk`, 166,491,407 bytes.
- SHA-256: `da82f7371a43c7c4dbfc40857aa3572df9b2e735d237cf2135888056f9a099e7`.
- Exactly five assets: one APK, optional Office and CAD components, corresponding-source archive, and SHA256SUMS. All five anonymous download bodies, published digests, tag object and source binding were independently read back.
- Complete-package updates only for this release. Actual current116 and retained115/114/113/108/65 production update parsers discover it from older alpha/1.0 versions, retain known-issue text and checksums, offer no delta, and identify 1.0.8 as current.

## Changes and focused verification

The device control panel starts as a draggable 48dp bubble, spins during real operations, expands on tap, and collapses after four seconds without interaction. The browser injection and JavaScript return-value envelope are fixed. Navigation requests are consumed by the resumed app instance. External preview checks wait for an actual window transition. Repeated catalog queries after real progress no longer incorrectly stop the entire task; existing stagnation and repeated-failure guards remain.

- Actual Full release compilation with JDK21/API37/NDK30; native54 was built with Swift6.4.1 from exactly matching native inputs. Verified 58 packaged native bindings, ARM64/16KiB alignment and API28–29 signatures. Five new core guard methods and six targeted JVM methods passed. The desktop restart interrupted only the wrapper receipt; the actual producer saved its successful result and exact APK, which were verified without rebuilding.
- Samsung SM-G9810/Android13: normal signed preserving-data upgrade retained package UIDs, tasks and configuration. This is ADB upgrade evidence, not a new OTA-install claim or Android9 physical acceptance.
- Actual native browser results contain seven visible semantic nodes and an enabled link. The page title is Example Domain; its current visible DOM has no heading node, and no heading was invented to satisfy the fixture.
- Correct Samsung Calculator target: eight structured device actions produced and read 513. A prior wrong Google Calculator target remains a recorded failure; the corrected-target case is separate.
- Task Linux produced a hash-verified 176-byte PNG. Background handoff from Calculator to Gallery returned `viewerVisible=true`; an additional native-tree observation read the real Gallery, and the image was physically visible. Finishing revoked the temporary grant and removed the copy. Read-only viewing did not claim a saved edit or business completion.
- The real bubble, expansion, idle collapse, dragging, failure/done indicators and animated operation frames were captured on the same APK. Existing pause/resume authority behavior is reused; it was not newly exercised in this visual check.
- Prior C3 browser failure and foreground-handoff unknown visibility remain preserved. These functional checks do not establish zero-assistance promotional-video acceptance. Original Full115/Full10 remains failed; a fresh recording must use this exact116 package and a new task/project.

## Remaining limits and cleanup

Complex cross-app video/calendar outcomes and hardware-specific pen/radio/USB/Root behavior retain their separate acceptance records. Foreground viewer receipts can remain unknown; background visible receipts and later observations are reported separately. Earlier unknown paid image/video outcomes were not resubmitted.

Successful device actions still showed 7.5–29.4 seconds of queue delay despite approximately0.1–0.55 seconds of actual platform execution; this is a measured next-iteration performance issue, not a passing latency result.

Retired source-pack staging was removed only after full archive/asset/receipt read-back. Three duplicate phone exports were removed after complete private native exports were verified. Current/rollback installers, native originals/symbols, source, SDK, next-use caches and original failure/recording evidence remain protected. The recording owner must explicitly adopt the phone lease and any temporary power/control settings before the coordinator stops device input.
