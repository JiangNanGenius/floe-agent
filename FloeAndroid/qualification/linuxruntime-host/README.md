# Linux runtime qualification host

Development-only App for G03-R1. It consumes the production
`:core:linuxruntime` source, runs as an ordinary non-debuggable App UID with
zero Android permissions, and has a distinct package
`com.floe.linuxruntime.qualhost`. It is not the Floe product App or a release
asset. Do not install it over `com.floe.agent.full`.

The checks cover packaged helper execution, expected data-directory exec
rejection, observed kernel capabilities, PTY input/resize/Ctrl-C/EOF, owned
cancellation, bounded output, real Debian output and exit 23, and cancellation
of a Linux process that deliberately starts a separate session. The latter
requires the reviewed PRoot `EXITKILL` patch. Kernel capability observations
are not sandbox qualification. PRoot remains a same-UID compatibility layer.

## Build and run

Run from the repository root. Use the existing ARM64 target; preserve its
apps and data. No emulator creation/reset or root/ADB privilege grant is
needed. Source the environment in Bash first:

```sh
source FloeAndroid/scripts/env.sh
bash FloeAndroid/core/linuxruntime/native-build/build-bootstrap.sh \
  --out "$PWD/Local/Artifacts/android-g03-r1/bootstrap"
mkdir -p FloeAndroid/core/linuxruntime/src/main/jniLibs/arm64-v8a
cp Local/Artifacts/android-g03-r1/bootstrap/lib/*.so \
  FloeAndroid/core/linuxruntime/src/main/jniLibs/arm64-v8a/
"$FLOE_ANDROID_ROOT/gradlew" -p FloeAndroid/qualification/linuxruntime-host \
  :app:assembleRelease --offline --max-workers=6 --console=plain
```

The host uses managed internal build outputs under
`$FLOE_ANDROID_BUILD_ROOT/linuxruntime-qualification/`. The APK is
`app/outputs/apk/release/app-release.apk` beneath that directory. The default
development signing identity permits device testing; it is not product
release signing. Executable payloads are generated, ignored files and must
never be committed. Production APK packaging must retain library extraction
for these helper executables.

The Debian fixture source is the ARM64 bookworm image from
[proot-distro v4.7.0](https://github.com/termux/proot-distro/releases/tag/v4.7.0):
`debian-bookworm-aarch64-pd-v4.7.0.tar.xz`, SHA256
`4baa32280cc70b67e2c650777c1d974349f0cdf23afaabc305ad3bc6182b8df8`.
Convert it with `prepare-fixture.py SOURCE OUTPUT`; this verifies the source,
removes the top directory and device/FIFO entries, and normalizes metadata
without extracting files on the host. The qualified gzip fixture is
`9341829d5fe914635e92bcb3f216f29ff31722b0097a10f191b04eae82cd24b9`
(71,868,558 bytes). The App checks that hash before extraction. Different
Python/zlib tar/gzip producers must be deliberately reviewed rather than
silently accepted. The extractor is for this fixed development fixture; it
is not the production environment installer.

Install the host APK, then push `debian-rootfs.tar.gz` to
`/sdcard/Android/data/com.floe.linuxruntime.qualhost/files/`. Open the host and
press **Run Linux-runtime self-test**. For fixed local checks without user
interaction, launch `com.floe.linuxruntime.qualhost/com.floe.linuxruntime.host.MainActivity`
with Boolean intent extra `autorun=true`. String extra `scope=linux` limits
the run to identity and Linux checks; it does not accept arbitrary commands.
Read `selftest-report.json` from that same app-specific external directory.
Remove an old exported report only after preserving it, so a stale report
cannot be mistaken for the current run. Keep the exact APK hash, source,
device API/page size, report, and any original failure together.

No network or model/provider access occurs. This host does not prove Floe
service/UI integration, rootfs installation transactions, package management,
background notifications, reboot recovery, or full environment isolation.
Those are subsequent G03 integration outcomes.
