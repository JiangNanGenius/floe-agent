# Reproduce the G01 macOS ARM64 toolchain

Versions and hashes are pinned in `toolchains.lock.json`. These are build tools;
none of the JDK, compiler or emulator is an application dependency. Install under
the repository's ignored `Local/Private/android-toolchains/`, or explicitly set
`FLOE_ANDROID_TOOLCHAINS` to an equivalent managed location. Do not commit local
paths, tool downloads, SDK licenses or signing keys.

1. Obtain Temurin JDK 21 for macOS ARM64 from the upstream Adoptium release matching
   the lock. Verify its SHA-256 before extraction under `jdk/`, retaining the
   release's `Contents/Home` structure.
2. Obtain Google command-line tools revision 22.0 for macOS ARM64. Verify the
   locked SHA-256 and place the archive's `cmdline-tools` contents under
   `android-sdk/cmdline-tools/22.0/`.
3. Source `scripts/env.sh` from Bash. Using that SDK root and JDK, accept the applicable
   development SDK terms and install these exact packages:

   ```sh
   sdkmanager --sdk_root="$ANDROID_HOME" \
     'platform-tools' 'platforms;android-37.0' 'build-tools;37.0.0' \
     'ndk;30.0.16248370' 'cmake;3.22.1' 'emulator' \
     'system-images;android-37.0;google_apis;arm64-v8a'
   ```

4. Download the matching open-source Swift macOS installer from `swiftHostURL`
   in the lock. Check the SHA-256 and `pkgutil --check-signature`. For a task-local
   installation, `pkgutil --expand-full` into ignored scratch, then move its inner
   package's `Payload` directory to `swift-6.4.1.xctoolchain/`. Do not run a global
   installer or change `xcode-select` merely to build Android.
5. Download the Android Swift SDK from
   `https://download.swift.org/swift-6.4.1-release/android-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_android.artifactbundle.tar.gz`.
   Verify the locked hash; extract its artifact bundle alongside the host toolchain.
   Run `python3 FloeAndroid/scripts/configure-swift-sdk.py` after sourcing `env.sh`.
   It links the SDK to the installed NDK and registers it in the local SDK search
   directory. Paths containing spaces are supported; no global Swift SDK is changed.
6. Write the SDK path into ignored `FloeAndroid/local.properties` as `sdk.dir=...`.
   For an established development install, also set `floe.debug.keystore` to its
   retained existing absolute key path. App and bridge instrumentation targets
   share that development identity; do not remove it with caches or assume
   AGP's implicit key stays the same across different Android user homes.
   Run `build-swift.sh`, then `./gradlew` inside `FloeAndroid/`. The wrapper validates
   its exact Gradle distribution checksum; project dependency verification/locks
   apply to subsequent builds. Never generate a new lock merely to pass `--check`.

The G01 Swift script explicitly selects SwiftPM's native build system. Swift 6.4.1
warns that this option is deprecated; it remains pinned and works for this stage.
Changing SwiftPM/SDK versions requires rechecking output discovery, JNI runtime
dependencies and device loading rather than assuming source compilation suffices.

## Tablet AVD

Create `Floe_G01_Tablet_API37` using `pixel_tablet` and the locked ARM64 system image,
inside `$ANDROID_AVD_HOME`. The launch request uses two cores and 2 GiB RAM, but
the installed API37 emulator raises the effective guest RAM to 4 GiB; account for
that actual minimum when measuring host pressure. Preserve the real 2560×1600,
320 dpi tablet layout. Run
`emulator -accel-check`, then boot and install a real APK: successful AVD creation
alone is not verification. Never select a connected target implicitly.

The current system image may omit an optional `devices.xml`; avdmanager can emit
that warning while creating the selected built-in hardware profile. Record it and
verify the resulting config and actual boot. Do not fabricate an SDK device file
or suppress a real startup failure to make the warning disappear.

SDKs, NDK, AVD data and the matching compiler are retained while needed by G02 and
later goals. Remove verified download/extraction staging after preserving hashes.
Per the user's latest 2026-10-18 clarification, Gradle and native build caches may
use the checkout-specific internal-SSD cache from `env.sh` for speed; SDKs and AVDs
stay on the external disk. Export APKs, symbols, logs and evidence to repository-owned ignored
artifact/private directories before cleaning a finished build.
