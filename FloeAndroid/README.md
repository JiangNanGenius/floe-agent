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
G01 and G02 code-stage handoff and cleanup are closed. G03-R1 execution
qualification and G03-R2 environment, jobs and workspace source integration
are complete; product App qualification belongs to G03-R3. Current
public status and limits are recorded in
[the implementation record](../docs/FLOE_ANDROID_PROGRESS.zh-CN.md). Workspaces
shown as being prepared are not implemented product capabilities. Android has no
local LLM backend.

## Android Alpha

[Download 0.1.0-alpha.7](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.7)
contains one signed ARM64 APK and SHA256SUMS. Install updates manually for now.
Alpha7 fixes attachment publication, real native-handle forwarding and Home-to-thread
ownership; the first model turn receives committed attachment names without changing
persisted user text. It also fixes MCP creation/no-auth setup, stale permission messages,
approval-card retirement and fresh privacy counts. Approval currently offers only the
call-bound decision that the native producer supports.

127 relevant JVM cases passed across focused source cohorts; 44 affected native
launch/repair tests passed, with unchanged MCP and other boundaries reused. The exact
final API37 / 16 KiB APK completed attachment first-send, actual approved MCP output
and approval retirement. A signed earlier cohort proved positive live-grant clearing
and connection interruption before client timeout; that unchanged lifecycle evidence
is retained separately. Original data was restored, then Alpha6-to-final-Alpha7 upgrade
and fresh-process counts were checked. This App qualification made no paid cloud calls.
Public tag/source, certificate, APK download hash and the two release assets were read back.

G02 code and representative integration are closed, with every canonical operation
accounted for in [the exit ledger](planning/G02_EXIT_LEDGER.json). This is not a claim
that all 41 operations passed individual App acceptance. Samsung remains on Alpha4;
full device, visual and input qualification stays with G12/G13/G14. Reusable task,
project and host approval scopes need the native authority contract before being exposed.
Linux, IDE, Office, system control and automatic updates remain later targets.
See [the implementation record](../docs/FLOE_ANDROID_PROGRESS.zh-CN.md) and
[current sequential targets](../docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md#g02-current-plan).
Later targets are a backlog, not prequeued worker tasks.

G03-R2 uses a separate-UID Linux runtime component; Core retains credentials,
conversation storage and the original persistent-job authority. PRoot provides
Linux compatibility, not a security sandbox. Workspace transfer and foreground
service wiring are source-stage work; model execution remains unavailable until
product qualification. Current Full/Play App and runtime Kotlin compilation,
15 foreground-lifecycle tests and 16 workspace JVM tests passed. Host Swift 6
object compilation and all 111 selected tests passed (19 workspace, 61 shell,
31 job tests), with original failures retained. Both Android ARM64 shared
libraries and JNI consumers also compiled and linked with 16 KiB alignment;
the runtime authority excludes the full Core backend. Actual App qualification
is pending; these checks built no new
product APK and made no paid App-provider calls. G03-R3 consumes the frozen batch
for product integration and the next Android Alpha.

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
# Optional full shared host suite; run only when the changed boundary requires it.
# Routine iteration uses affected cohorts and reuses unchanged evidence.
# Keep host scratch separate from Android builds:
"$FLOE_SWIFT_BIN/swift" test --build-system native --package-path FloeAndroid/shared \
  --scratch-path "$FLOE_ANDROID_CACHE_ROOT/swift-host-native" --jobs 6
# Pin the device; never use a bare adb when several are attached:
adb -s DEVICE_SERIAL install -r /absolute/path/to/app-full-debug.apk
SH
```

Complete a coherent source batch before integrated compilation and affected
behavior checks. Do not rerun the full host/device matrix after every small fix,
and do not use paid provider calls for deterministic local execution checks.

The plan, fixture and generator checks are read-only. G01 evidence combines them
with the five-APK artifact checks, host tests and real JNI/device smoke; a green
build or checker alone is not product or visual acceptance.

Android instrumentation in `core/swiftbridge` verifies the real compiled Swift
policy across JNI, Unicode and rejection paths. App instrumentation checks that
Play cannot load the full-only classes. Device flows, screenshots, logs, native
alignment and artifact hashes are recorded separately from build success.
Do not use the user's unrelated connected devices. Shut down only task-owned
emulators after capturing evidence; retain SDKs needed by the next goal.
