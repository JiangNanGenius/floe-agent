# Third-party components — :core:linuxruntime

Floe-owned code in this module (Kotlin API, `floe_pty_jni.c`,
`floe_probe.c`, CMake, `native-build` scripts including the vendored
`compat/musl-compat.h`, this repo's docs) is **MPL-2.0**. The module ships
third-party binaries as separate executable payloads. Exact pins, hashes,
the one pinned patch and full provenance: `native-build/PINS.md`.

## Per-component terms (verified from the pinned sources, not filenames)

| Component | Terms (actual, per-file verified) | Where it lands | Obligations when shipping `libproot.so` |
| --- | --- | --- | --- |
| PRoot, Termux maintained fork v5.1.107.98 | Every source file header: “GPL version 2 **or (at your option) any later version**” (STMicroelectronics lineage); bundled `COPYING`. The earlier bare “GPL-2.0” shorthand and the “GPL-2.0 safe floor” choice were both incomplete/incorrect | `libproot.so` (statically linked PRoot+talloc ELF; separate child process, never linked into JNI) + `libproot_loader.so` (same source) | The combined binary is **offered under GPL-3.0-or-later** by exercising the per-file “or later” option — required because LGPL-3.0-or-later talloc is statically linked and the combined work's terms must be compatible with it. Original notices (per-file headers, bundled COPYING text) are preserved untouched inside the pinned archive/CCS; provide complete corresponding source = pinned archive + the pinned `patches/tracee-event-exitkill.patch` + the exact recipe in `native-build/` (the build instructions), offered alongside the binary |
| talloc 2.4.2 | `talloc.c`/`talloc.h`: LGPL-3.0-or-later; `lib/replace` carries its own LGPL notices | statically linked **inside `libproot.so` only** | LGPL-3 static linking: ship the same CCS offer so recipients can modify and relink; the producer additionally exports `talloc.o`, `replace.o`, `libtalloc.a` and the staged prefix under the output `build/` dir as the concrete relink path. |
| `sys/queue.h` | BSD-3-Clause (Regents 1991/1993 + contributors, classic Berkeley 8.5 lineage). Source: Android NDK 30.0.16248370 sysroot, byte-identical to AOSP bionic tag `android-16.0.0_r1`; vendored adapted copy keeps the full notice verbatim | macros compiled into the helper; source header retained | Retain the complete notice in source and binary distribution materials (source retained: `native-build/compat/queue.h` + `.patch` record). The canonical producer stages this pure BSD header into the talloc include prefix; the earliest qualification probe whose talloc was built against the Apple/APSL header is historical lineage only — shipping payloads must come from the clean BSD-input rebuild |
| `tracee/event.c` EXITKILL patch | Floe-captured one-line upstream delta (`native-build/patches/tracee-event-exitkill.patch`), before/after hashes pinned in `build-bootstrap.sh` | patched into the PRoot build; the file keeps its original GPL-2.0-or-later notice | Patch + resulting source form ship inside the complete corresponding source; lifecycle control for PTY cancellation, not a sandbox claim |
| `compat/musl-compat.h` | Floe-authored MPL-2.0 build-time header (`TEMP_FAILURE_RETRY`, guarded `MSG_COPY`) | compile-time `-include` only; nothing shipped | none beyond keeping it in the recipe/CCS |
| Zig 0.14.1 tool and bundled runtime | Tool: MIT; statically incorporated musl and Zig compiler builtins retain their original notices | Zig executable is a host tool; musl/builtins are incorporated into the static helper | Preserve `licenses/Zig-LICENSE` and the complete `licenses/musl-COPYRIGHT` with binary materials; the pinned Zig archive retains runtime source. Do not describe incorporated libc as absent from the binary |
| Android NDK 30.0.16248370 | Android SDK license (tooling); used, not redistributed, except the independently BSD-licensed `sys/queue.h` header retained with its notice | build host tool only | comply with SDK terms for the toolchain itself |
| Debian bookworm aarch64 rootfs (proot-distro v4.7.0 image) | aggregation of Debian binary packages under their individual DFSG licenses; proot-distro tooling GPL-3.0 | NOT built by this module; guest content policy decision is Main's | any redistribution passes through Debian package terms; keep the pinned tarball provenance |
| macOS SDK `sys/queue.h` | APSL-2.0 notice over BSD Regents text | **rejected — not an input** (do not reintroduce; the producer fails if Apple/APSL text appears in recipe inputs) | — |

## Boundary statement

The Floe launcher (MPL-2.0 Java/Kotlin + `libfloepty.so` JNI) invokes
`libproot.so` strictly as a **separate subprocess** (exec channel:
installed APK native-lib dir). GPL internals are not grafted into Floe-owned
JNI code; no Floe-owned library links PRoot/talloc. PRoot is path/syscall
virtualization over the app UID — not a sandbox.

Device status (Main, 2026-10-22, target37/Android17/16KiB cohort): the
PTY/launch transport passes, and with this maintained-fork helper an
actual Linux guest ran (`id`/`uname`/`os-release`, owned kill/reap,
`r1/DEVICE_PROBE_A14.json`). File-backed `PROT_EXEC` mmap of guest
libraries **does succeed** on the app data dir with translation active
(A12) — there is no blanket mmap impossibility. What remains is a
*generic-helper incompatibility*, now superseded: the generic proot-me
v5.5.0 cross build mismatched its disabled feature probes and tracing path,
leaving loader paths untranslated (ENOENT, A10); with translation restored,
the guest encountered inherited Android SIGSYS behavior (A12/A13); the maintained fork handles that lineage. Diagnostic
`PROOT_NO_SECCOMP`/`GLIBC_TUNABLES` were investigation-only and are not
used in final runs; nothing here weakens the OS seccomp policy. The
adapter additionally uses `--kill-on-exit` for normal root-command exit,
and the pinned EXITKILL patch covers cancellation of interactive/detached
children (lifecycle control, not a sandbox claim).

PRoot upstream docs list `PROOT_LOADER` as the supported env override; the
standalone loader payload (`libproot_loader.so`) comes from the same
pinned source and carries the same obligations as `libproot.so`.
