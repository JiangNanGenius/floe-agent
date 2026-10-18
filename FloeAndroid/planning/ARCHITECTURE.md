# Android foundation decisions — G01

Status: implementation in progress, 2026-10-18. Initial iOS source: `19ab263a`.

## Native shell and shared core

Compose is the primary Android UI. It follows the actual task-first sidebar/drawer
in `FloeAgentApp.swift`, rather than relying on stale comments about five phone tabs.
Semantic colors, typography hierarchy, grouped opaque surfaces and selection are
mapped from `FloeTheme.swift`; Android platform controls, back, insets, accessibility
and 48 dp hit targets remain functional. Explicit Cupertino components sit behind
Floe wrappers; neither Material defaults nor wallpaper colors replace the
specified iOS visual identity. The Cupertino 3.3.1 component probe compiled and
ran on API37; product integration and paired visual acceptance are in progress.

The source baseline comprises `FloeApp/App/FloeAgentApp.swift`,
`FloeApp/Shell/AppDestination.swift` and `FloeApp/Design/FloeTheme.swift`. Sources,
hashes and the mapping are frozen in `visual-baseline.json`. Existing historical
screenshots are references only. G01 requires real iOS references and paired
representative-page acceptance before further feature pages; G14 is the final
whole-product review. Fresh portrait/landscape home and settings references were
captured from the canonical existing iPad; the installed binary matches its
source receipt and the relevant UI source remains unchanged. Private qualification
record titles in those images must not be hardcoded as Android user data.

The first shared source is `FloeModels/TaskPolicy.swift`. A standalone Swift package
uses a relative source link, keeping the iOS target and package manifest unchanged.
The JVM calls a narrow JNI C++ adapter and exported C functions in a dynamic Swift
library. G01 proves actual policy behavior, not only an echo implemented in Kotlin.
Protocol version and correlation are explicit and bounded. Provider/runtime code
will be added in G02 only after dependency and platform storage/transport audits.

## Distribution

`full` and `play` are compile-time product flavors, with full-only dependency
edges to phone control and root modules. Separate source sets assemble platform
capability sources. No reflection/plugin download can restore excluded modules
to Play. G01 module markers are unavailable, not model-callable placeholders.
The foundation does not claim policy approval, signing readiness or store delivery.

Development IDs are `com.floe.agent.full.dev` and `com.floe.agent.dev` to avoid
colliding with future signed installs. Production ID/signature permanence is a
G15 release decision; debug signing never becomes the upgrade contract by accident.

## Development debug signing identity

AGP resolves its implicit debug keystore from `$ANDROID_USER_HOME` and otherwise
from `~/.android`, and silently generates a fresh keypair wherever none exists.
G01 found two different default keypairs in the normal and externalized Android
user homes. The initial and corrected APKs used different certificates, so
`adb install -r` of corrected
APKs over installed packages failed `INSTALL_FAILED_UPDATE_INCOMPATIBLE` even
though applicationId, versionCode and the AndroidDebug DN were unchanged. Both
`:app` and `:core:swiftbridge` therefore honor `floe.debug.keystore` (ignored
`local.properties` or `-Pfloe.debug.keystore`): when configured, the `debug`
signing config must point at that existing absolute file — it fails closed rather
than regenerating — so every debug variant and androidTest APK shares one stable
development identity across environment and cache relocations. The key file and
path stay outside the public scope (`Local/Private`); the referenced alias and
password constants are AGP's documented public default-debug values. `check-apk.py`
can verify continuity opt-in (`--require-identical-signer`, `--expect-cert-sha256`,
`--test-apk`) without touching the default boundary report. This pins only the
development identity; release key policy remains the separate G15 decision.

## Data, execution and future adapters

The contracts carry task/run/environment/job identity, event cursor, revision and
host-authored grant reference. G02 supplies durable state and Android Keystore
storage; an in-memory fallback is not an acceptable credential store. G03 supplies
the environment execution owner; PRoot isolation limitations remain explicit.
Office and geometry remain native services, not arbitrary code execution aliases.
No local LLM component is introduced.

Cross-device document exchange and eventual real-time sync remain separate from
sharing source and synchronizing feature releases. G11 must implement required
import/export; replacing iOS CloudKit or adding a sync backend needs the scoped
decision already identified in the main plan.

## Build and acceptance

Pin the toolchain and resolved dependencies. Compile ARM64 libraries for API 28
with 16 KiB ELF alignment; verify both source outputs and the packaged APK. Target
API 37 does not establish that every new Android API is being used: feature-specific
new and fallback branches belong to their implementation goals and G13 acceptance.
Build heavy native components and run emulators serially under measured resources.
G01 acceptance includes both variant builds/installations and real shared-core
round trips. Full functional parity remains G02–G15 work.

## Native loading regression discovered on devices

The first APKs compiled and aligned correctly but failed JNI loading on both
API 33 and API 37: the imported Swift library had no ELF SONAME, so the JNI
library recorded a host absolute path in `DT_NEEDED`. The Swift build now gives
`libFloeAndroidCore.so` an explicit SONAME and the CMake import handles libraries
without SONAME safely. APK verification must reject dependency names with path
separators and unresolved non-system dependencies, in addition to ELF/ZIP alignment.
Device instrumentation, rather than a successful linker invocation, closes this
regression. Original failures remain in private evidence.
