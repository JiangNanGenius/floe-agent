# Floe for Android

Native Compose application with a Swift shared-core overlay. Development follows
[the agreed plan](../docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md#23-目标模式执行顺序先代码完整-再集中调试).
G01 establishes the build, shared contracts and iPad-style visual foundation.
The original sparse navigation shell was rejected as a visual baseline. Compose
Cupertino 3.3.1 (RobinPcrd) is pinned behind Floe wrappers and one custom shell;
its standalone probe and the integrated five-APK batch passed. The first device
review returned seven material fixes; after one repair batch and two targeted
review rounds all seven IDs were resolved for the G01 representative foundation
(`ship`). That acceptance covers those representative pages only. Whole-product
visual parity and full CJK IME/TalkBack are not claimed. That G01 evidence did not
cover 16 KiB runtime behavior; the later Alpha3 device coverage is listed below.
G01 source, handoff and cleanup closure are complete; G02 is the active goal. Current
public status and limits are recorded in
[the implementation record](../docs/FLOE_ANDROID_PROGRESS.zh-CN.md). Workspaces
shown as being prepared are not implemented product capabilities. Android has no
local LLM backend.

## Android Alpha

[Download 0.1.0-alpha.5](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.5)
contains one signed ARM64 APK and SHA256SUMS. Install updates manually for now.
Alpha5 fixes settings result races and privacy-summary recovery, with focused
local tests and actual API37 / 16 KiB tablet-emulator checks using a local
provider fixture. Its public APK and checksum were independently downloaded
and verified. The physical Samsung SM-G9810 remains on Alpha4; Alpha5 phone
acceptance is not claimed. Earlier Alpha3/4 compatibility evidence is retained
in [the implementation record](../docs/FLOE_ANDROID_PROGRESS.zh-CN.md).

G02 remains active. R1–R6 stage deliveries are complete; **G02-R7** is repairing
managed private-workspace cleanup and recovery of memory, personalization and
usage settings. The cleanup adapter is already bound: relative-path validation
and history-clear integration with the existing ownership/retry lifecycle need
repair. A directory-cleanup failure is not a successful deletion. The current
code batch will receive focused integrated checks before another stage release.
See the [current sequential targets](../docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md#g02-current-plan).
Later targets are a backlog, not prequeued worker tasks. Alpha delivery does not
close the full 41-operation G02 scope.

## Layout and ownership

| Module | Responsibility |
| --- | --- |
| `app` | Task-first phone drawer/tablet sidebar, platform lifecycle and distribution assembly |
| `core/contracts` | Explicit task/run/job/environment ownership, revisions and platform interfaces |
| `shared` | Narrow Swift package reusing existing iOS source through relative source links |
| `core/swiftbridge` | Bounded versioned JSON over JNI/C, native library packaging |
| `core/designsystem` | Floe semantic theme; light/dark, text scaling and Android input/insets |
| `feature/phonecontrol` | Full APK only; service implementation belongs to G08 |
| `feature/rootsystem` | Full APK only; optional user-authorized enhancement belongs to G08 |
| `planning` | Ownership of all 85 implementation-plan work packages |

`playImplementation` never depends on either restricted module. Both the runtime
classpath and APK contents must be checked; hiding controls is insufficient.
G01 registers no AccessibilityService, root daemon or elevated permissions.
Available tool discovery excludes modules whose backend is not implemented.

## Toolchain and builds

Exact versions and SDK checksums are recorded in `toolchains.lock.json`.
Tool installations default to the repository's ignored `Local/Private/android-toolchains/`.
Task-local environment settings live in `scripts/env.sh`; no global Xcode or shell
profile changes are needed. Build output and Gradle caches use a checkout-specific
internal-SSD cache, retained only while useful for the next goal. Do not commit `local.properties`, signing keys, downloaded SDKs
or generated native libraries.

Run the environment script in Bash (it uses `BASH_SOURCE`), including when your
interactive shell is zsh:

```sh
bash <<'SH'
source FloeAndroid/scripts/env.sh
bash FloeAndroid/scripts/build-swift.sh
cd FloeAndroid
./gradlew :app:assembleFullDebug :app:assemblePlayDebug --console=plain
SH
```

Reuse unchanged shared native outputs for subsequent UI-only builds. For stable
development upgrades, configure `floe.debug.keystore` in ignored `local.properties`
to an existing absolute keystore path shared by the app and bridge test targets.
Keep the key private and retain it when clearing build caches. Changing the SDK
user-home directory must not silently change the signing identity. Release signing
is separate from this development setting.

The Swift SDK must first be registered in `$FLOE_SWIFT_SDKS` using the matching
open-source Swift compiler; Apple's Xcode compiler is not interchangeable.
Read [Swift's Android setup](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html).
The initial build targets ARM64, API 37, with API 28 as the code compatibility floor.
Only tested API/ABI combinations constitute verified support.

## Contracts

The bridge uses `version`, `operation` and `requestID`; responses include `ok`
and preserve correlation. G01 exports only `handshake` and `policy.inspect`.
Requests are bounded to 64 KiB in standard UTF-8; JNI converts UTF-16 correctly,
including supplementary characters. Protocol errors fail closed. Binary payloads
will use owned files/streams, not this JSON channel. Never send secrets to diagnostics.

`TaskPolicy.swift` is the original source, not a second policy implementation.
The overlay avoids resolving the iOS package's unrelated binary dependencies.
Adding shared files requires auditing their transitive dependencies. JNI must not
expose actors, database handles, host shell execution or arbitrary native symbol calls.
The G02 runtime will remain the single task authority; Android adapters own only
platform services. Environment IDs and revisions are mandatory for later execution
and mutations; no implicit environment selection or escalation to the host is allowed.

## Verification

```sh
bash <<'SH'
source FloeAndroid/scripts/env.sh
python3 FloeAndroid/scripts/check-plan.py
python3 FloeAndroid/scripts/check-fixtures.py --check
python3 FloeAndroid/scripts/check-settings-domain.py --check
python3 FloeAndroid/fixtures/generate.py --check
# Host policy/protocol tests (use a distinct scratch path from Android builds):
"$FLOE_SWIFT_BIN/swift" test --build-system native --package-path FloeAndroid/shared \
  --scratch-path "$FLOE_ANDROID_CACHE_ROOT/swift-host-native" --jobs 6
# Pin the device; never use a bare adb when several are attached:
adb -s DEVICE_SERIAL install -r /absolute/path/to/app-full-debug.apk
SH
```

The plan, fixture and generator checks are read-only. G01 evidence combines them
with the five-APK artifact checks, host tests and real JNI/device smoke; a green
build or checker alone is not product or visual acceptance.

Android instrumentation in `core/swiftbridge` verifies the real compiled Swift
policy across JNI, Unicode and rejection paths. App instrumentation checks that
Play cannot load the full-only classes. Device flows, screenshots, logs, native
alignment and artifact hashes are recorded separately from build success.
Do not use the user's unrelated connected devices. Shut down only task-owned
emulators after capturing evidence; retain SDKs needed by the next goal.
