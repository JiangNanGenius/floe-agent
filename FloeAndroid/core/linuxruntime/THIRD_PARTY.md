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

## Corresponding-source production tooling (G03-R3)

The distributable complete-corresponding-source archive for the shipped
`libproot.so`/`libproot_loader.so` payloads is produced by
`FloeAndroid/scripts/produce-corresponding-source.py` (offline tests:
`FloeAndroid/scripts/tests/test_produce_corresponding_source.py`). It accepts
the *frozen* recipe tree (`native-build/`), the final native-payloads
`provenance.json`, the byte-exact pinned upstream archives from the producer
cache, the license texts under `licenses/` and `FloeAndroid/licenses/`, and
optionally the talloc relink objects from the producer's `build/` export; it
fails closed unless the recomputed recipe-tree hash, the pinned patch hash,
the producer-script pins and the cached upstream bytes all agree with the
provenance of the run that produced the *shipped* payloads. The final archive
must be executed against final frozen inputs after all source lanes are
terminal; an archive bound to a moving working tree is never a final legal
offer. Publication stays with the release owner.

## Guest DNS resolver helper — `libnss_floe.so.2` (G03-R3 source package)

| Component | Terms (verified) | Where it lands | Build/source boundary |
| --- | --- | --- | --- |
| `native-build/guest-resolver/libnss_floe.c` + `nss-floe.map` | Floe-authored, MPL-2.0 (`SPDX-License-Identifier: MPL-2.0`). Self-contained glibc NSS module; contains **no third-party code** | guest rootfs `/usr/lib/aarch64-linux-gnu/libnss_floe.so.2` (staged by the facilities lane from verified signed-APK assets) | compiled **only** by `guest-resolver/build-guest-resolver.sh` at `--target=aarch64-linux-gnu.2.28` (never an Android bionic target); exports exactly the four `_nss_floe_gethostbyname*_r` ABI entry points via the version script; SONAME `libnss_floe.so.2`; every `PT_LOAD` ≥ 16 KiB aligned |
| glibc public headers (bundled in the pinned Zig 0.14.1: `lib/libc/include/generic-glibc/`, per-arch overlays) | LGPL-2.1-or-later **with the glibc header exception**; used at compile time. The ABI facts relied on (`enum nss_status` values, `struct gaih_addrtuple` member order, the `TRYAGAIN`+`ERANGE`+`NETDB_INTERNAL` buffer-growth protocol, and the caller-buffer/real-pointer `gethostbyname4_r` tuple convention) were verified from the pinned header copy and glibc 2.28-vs-2.36 header/source comparisons, not memory | build-time inputs only; no header text is copied into the module | the producer emits nothing into the source tree; outputs bind through `manifest.json` |
| Zig 0.14.1 (`zig cc`) as the module compiler; NDK `ld.lld`/`llvm-readelf` as linker/inspector | as existing rows above (MIT; SDK-terms host tools; the same pinned cache/URL/sha as `native-build/PINS.md` — the guest producer refuses on pin divergence) | host tools only; the produced `.so` **links against nothing** at build time (zero `DT_NEEDED`, no glibc version-tagged imports): the guest's already-loaded glibc resolves its stable symbol references when glibc `dlopen`s the module | deterministic (`-ffile-prefix-map`, `--build-id=sha1`, fixed flags); measured byte-identical across repeated scratch runs on 2026-10-22 — the authoritative producer run, asset staging and device acceptance remain Main's steps |

Scope limits (product truth, not a legal statement): the module intercepts the
guest glibc NSS path only — `getaddrinfo`/`gethostbyname` traffic such as
Python, Node `dns.lookup`, curl, apt/pip/npm. NSS-bypassing clients (Node
c-ares/`dns.resolve*`, dnspython, `dig`, raw DNS sockets) never call it, and
numeric literals are short-circuited before NSS; the package intentionally
does not expand into a PRoot syscall redirector. There is no fallback
resolver, no host-network path and no fabricated positive record inside the
module: any failure is an honest NSS refusal. The earlier pre-frozen
loopback/nonce draft has been retired from the product source tree; only
the canonical filesystem-socket module is shipped.

Corresponding-source: the helper is MPL-2.0 Floe-owned, but its public
source/protocol/producer and the producer `manifest.json` (source hashes,
`sourceTreeSha256`, toolchain pin, binary hash — frozen schema in
`native-build/guest-resolver/PROTOCOL.json`) can additionally be bundled
into the GPL offer archive via
`produce-corresponding-source.py --guest-resolver-dir … --guest-resolver-manifest …`
(all-or-none; without those flags the proot/talloc archive is bit-for-bit
unchanged from the original recipe bindings).

## Gradle-resolved library dependency (G03-R2 installer)

| Component | Terms (verified from the primary source) | Where it lands | Obligations |
| --- | --- | --- | --- |
| XZ for Java 1.12 (`org.tukaani:xz`) | 0BSD (SPDX header and `licenses/license` in the published POM; upstream `COPYING` at tag v1.12). Verified 2026-10-22 against repo1.maven.org; jar/pom SHA-256 pinned in `FloeAndroid/gradle/verification-metadata.xml` | `:core:linuxruntime` JVM classpath only (streaming XZ decode in `install/`); no transitive dependencies | Retain `licenses/xz-0BSD-LICENSE` (exact upstream text) with binary materials; note the multi-release `META-INF/versions/9` layout for D8 during App integration |
