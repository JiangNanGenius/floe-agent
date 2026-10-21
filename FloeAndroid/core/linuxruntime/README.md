# FloeAndroid :core:linuxruntime (G03-R1)

Reusable ARM64 Linux/PTY **launch transport** for Floe Android. Launch
transports only: PTY creation, owned fork/exec, bounded output read, resize,
Ctrl-C, exit reporting, cancellation. It is NOT a security sandbox and NOT an
environment/job database — environment/task/project identity is an explicit
caller input (`RunOwnership`, carried verbatim; `FloeEnvironments` remains the
authority).

## Layout
- `src/main/java/com/floe/android/linuxruntime/` — `LinuxRuntimeBackend`,
  `DefaultLinuxRuntimeBackend`, `PtySession`, `LaunchSpec`, `PRootLaunchSpec`, `RunOwnership`,
  `PosixBridge` (thin JNI).
- `src/main/cpp/floe_pty_jni.c` — bionic-only JNI (posix_openpt PTY,
  fork/execve with CLOEXEC error pipe bounded by the spawn timeout, waitpid,
  TIOCSWINSZ, UTF-16→strict-UTF-8 bridging, child closes all inherited fds).
- `src/main/cpp/floe_probe.c` — synthetic self-test child (identity / seccomp +
  Landlock ABI probe in the owned child only / echo / sleep / flood).
- `src/main/jniLibs/arm64-v8a/` — shipped executable payloads:
  `libfloeprobe.so` (static bionic, built by `native-build/build-probe.sh`)
  and `libproot.so` (Termux-maintained PRoot fork v5.1.107.98 + talloc
  2.4.2, static musl; see provenance). Executables live here because the
  installed APK native-lib dir (`apk_data_file`) supports this packaged
  execution channel; targetSdk≥29 data-directory execution is restricted.
  This does not prohibit ordinary Android system executables.
- `src/main/cpp/CMakeLists.txt` — builds `libfloepty.so` (16 KiB page-aligned).

## Platform facts that shape this module (AOSP main, fetched 2026-10-22)
- targetSdk 37 → SELinux domain `untrusted_app` (`minTargetSdkVersion=34`).
- `execute` on `app_data_file` exists only for targetSdk≤28
  (`untrusted_app_27.te`); guest binaries under filesDir cannot exec at 37 —
  direct kernel execve is rejected; the packaged PRoot loader provides the
  separately measured execution path (self-test T8).
- `isolatedProcess` cannot open `app_data_file` (`isolated_app_all.te`
  neverallow) and is not used here.
- Anonymous exec memory (`self:process execmem`) is allowed for app domains.
  Earlier blanket statements that file-backed executable mappings were
  impossible have been **retired**: Main's A12 device measurement shows a
  glibc guest's file-backed `PROT_EXEC` mmap of its own libraries from the
  app data dir **succeeds** once PRoot translation is active (target37 /
  16 KiB pages / App UID). The remaining blocker was helper-specific, not a
  platform mmap denial: the generic proot-me v5.5.0 cross build mismatched disabled feature
  probes and its tracing path (untranslated loader open, A10); restoring
  translation then exposed Android SIGSYS compatibility behavior. The
  failing syscall was not independently identified, and rseq tunables alone
  changed nothing (A13). The maintained Termux fork handles
  that lineage, and A14 achieved actual Linux guest success with it
  (`id`/`uname`/`os-release`, owned kill/reap). No OS seccomp policy is
  weakened anywhere in this path.

## Rebuild
- JNI lib: any Gradle build of a consumer (CMake via externalNativeBuild).
- Probe: `bash native-build/build-probe.sh` (NDK pinned in build.gradle.kts).
- Bootstrap producer (canonical Termux PRoot fork + talloc + loader + probe,
  reproducible from pinned public sources): `bash native-build/build-bootstrap.sh
  [--out DIR] [--cache DIR] [--work DIR] [--jobs 6]` — verifies sha256 of
  every input, applies the one pinned `tracee/event.c` EXITKILL patch
  (before/after hashes enforced), builds in a **whitespace-free work tree**
  (default under `FLOE_ANDROID_CACHE_ROOT`; whitespace paths are rejected,
  never worked around with symlinks; reset only of fresh/empty or
  marker-owned directories), emits binaries only into a caller-provided
  Git-ignored `--out` dir (never jniLibs), gates outputs on
  `llvm-readelf -lW` (wide format, nonzero-LOAD assertion, ≥16 KiB align),
  static/EXEC/AArch64 and exact object-set checks (the fork makefile can
  exit 0 while recipes fail, so the exit code alone is never trusted), and
  writes `MANIFEST.sha256` + `provenance.json` plus relink/CCS evidence
  under `$OUT/build/`. All pins, the complete applied-delta list (one
  pinned patch + env/flags/shims; zero other upstream source edits; the
  pure-BSD `sys/queue.h` input with the Apple/APSL header permanently
  rejected) and the verified-qualification-flag reconstruction are recorded
  in `native-build/PINS.md`; per-component license obligations and notices
  in `THIRD_PARTY.md`.
- Loader payload: the producer packages the standalone fork loader as
  `libproot_loader.so` (installed into the APK native-lib dir like the other
  payloads). Upstream's `PROOT_LOADER` env var points PRoot at that file
  instead of the copy embedded in `libproot.so`.
- Cancellation lifecycle: the adapter passes `--kill-on-exit` for normal
  root-command exit; the pinned EXITKILL patch additionally makes a
  tracer death at PTY cancellation also terminate traced children
  that changed process groups (both `PTRACE_SETOPTIONS` attempts retain
  `PTRACE_O_EXITKILL` and fail closed on an unsupported kernel; Android
  min28 kernels support it). This is lifecycle control, not a sandbox claim.
- Lineage correction (historical): the earliest parent qualification build
  (`Local/Private/android-g03-20261022/r1/backend/`) compiled against a
  macOS SDK `sys/queue.h` miscoded as BSD-3 (it carries an APSL-2.0 notice),
  and an early generic v5.5.0 producer was reviewed here with a “GPL-2.0
  safe floor” term choice and several path/verification defects (all four
  corrected in this repair round). This recipe is the canonical clean
  rebuild path going forward: pure BSD header, fork source, EXITKILL patch,
  corrected licensing.

## Status

The canonical source producer was built and its actual payloads were
consumed by the non-debuggable target37 qualification host. The same APK
passed nine local checks on Samsung API33/4KiB and tablet-emulator
API37/16KiB, including real Debian output/exit23 and cancellation of a
setsid child in a separate process group. Installed payload hashes match
the APK; no paid model calls or OS/root privilege changes were used.
See `../../qualification/linuxruntime-host/README.md` for reproduction.
Product installation, jobs/notifications, credential separation and model
routing remain the next integration batch; no product capability is
registered by this library alone.
