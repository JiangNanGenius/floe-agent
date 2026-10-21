# native-build pinned inputs, recipe deltas and licenses

Canonical maintained helper: the **Termux PRoot fork v5.1.107.98** built
static musl aarch64 by `build-bootstrap.sh`, plus the hand-built static
talloc 2.4.2, the fork's loader payload and the synthetic probe. This
supersedes the generic proot-me v5.5.0 baseline producer (see
§Lineage below): device evidence showed the generic build is incompatible
with glibc guests on Android, while the maintained fork reached actual
Linux guest success in the A14 run (Main device evidence:
`Local/Private/android-g03-20261022/r1/DEVICE_PROBE_A14.json`).

Machine-consumable pins live in `build-bootstrap.sh` (sha256-verified at
fetch time); this file is the reviewed human record. Downloads land in
the caller's task cache (`--cache`, default
`Local/Scratch/floe-linuxruntime-bootstrap/dl`, Git-ignored; the verified
qualification cache under the internal build root may be reused to avoid
re-download) — never in a global SDK location or a sibling checkout.

## Producer invocation

```bash
bash FloeAndroid/core/linuxruntime/native-build/build-bootstrap.sh \
  [--out DIR] [--cache DIR] [--work DIR] [--jobs 6]
```

- `--out` is the repository-owned artifact directory (Git-ignored private
  scope). Produces `$OUT/lib/libproot.so`, `$OUT/lib/libproot_loader.so`,
  `$OUT/lib/libfloeprobe.so`, `$OUT/MANIFEST.sha256` (LC_ALL=C sorted) and
  `$OUT/provenance.json`, plus relink/reproducibility evidence exported
  under `$OUT/build/` (talloc objects/archive/staged prefix, the full
  70-object PRoot `.o` set, generated `build.h` + `loader/loader-info.c`,
  the patched source and the make log).
- `--work` is the GNUmake build tree and **must be whitespace-free**.
  PRoot's GNUmakefile interpolates VPATH/SRC-derived paths and env CFLAGS
  strings into recipes *unquoted*; with the repository volume name
  "IOS AI AGENT" in the path, recipes split into
  `/bin/sh: /Volumes/TECLAST-512/IOS: Permission denied` **hundreds of
  times while make still exited 0** (verified failure preserved at
  `r1/termux-bootstrap/build-second.log`). The work tree therefore
  defaults to the no-space   internal cache
  `$FLOE_ANDROID_CACHE_ROOT/floe-linuxruntime-bootstrap/work`; the
  producer rejects any whitespace-containing work path outright and never
  creates a `/tmp` symlink workaround. Destructively reset directories (the
  work tree and `$OUT/build/`) must be fresh/empty or carry the producer's
  `.floe-linuxruntime-owned` marker; nonempty unmarked contents are never
  auto-adopted, and the marker survives each reset. Binaries and relink
  evidence are exported into the repository-owned OUT directory.

## Pins

| Input | Pin | Origin | License |
| --- | --- | --- | --- |
| PRoot (maintained fork) | tag `v5.1.107.98`; archive sha256 `9de61bddd6f5016d065e2755b72ff4747290e5f992562f031785b107b51d02ba` | https://github.com/termux/proot/archive/v5.1.107.98.zip (hash-verified copy reused from the prepared qualification cache; zero-drift vs the `r1/termux-bootstrap` tree) | per-file notices “GPL version 2 **or (at your option) any later version**” (STMicroelectronics lineage); bundled `COPYING`. Combined-binary terms: **GPL-3.0-or-later**, see obligations below |
| talloc | 2.4.2; tarball sha256 `85ecf9e465e20f98f9950a52e9a411e14320bc555fa257d87697b7e7a9b1d8a6` | https://download.samba.org/pub/talloc/talloc-2.4.2.tar.gz (re-fetched 2026-10-22, exact match) | `talloc.c`/`talloc.h`: LGPL-3.0-or-later; `lib/replace` per-file LGPL notices |
| Zig | 0.14.1; tarball sha256 `39f3dc5e79c22088ce878edc821dedb4ca5a1cd9f5ef915e9b3cc3053e8faefa`; bundled clang 19.1.7 | https://ziglang.org/download/0.14.1/zig-aarch64-macos-0.14.1.tar.xz | MIT. Build host tool only; never shipped |
| Android NDK | 30.0.16248370 (pinned by `FloeAndroid/scripts/env.sh`) | local task toolchain under `Local/Private/android-toolchains` | SDK terms; the only NDK *file* redistributed inside the recipe is `sys/queue.h` below (its own BSD-3 license) |
| `sys/queue.h` | NDK 30 sysroot `/usr/include/sys/queue.h`, sha256 `09ee5ac8c68c0498a4f8ce93a5d0e989959f5d43a3fbe28f7b42fa1381828c8f` — byte-identical to AOSP bionic `libc/include/sys/queue.h` at tag `android-16.0.0_r1`; vendored adapted copy `compat/queue.h` sha256 `2f17fe601093b9f3733045442213603973e906a255de87926a0022927a0f79c9`; patch record `compat/queue.h.cdefs-adapt.patch` | BSD-3-Clause (Regents, full notice preserved) | build-time include only, not shipped in outputs. The canonical producer stages this pure BSD header; the earlier qualification probe whose talloc was built against the Apple/APSL header is historical and must not be reused as the shipping payload |
| `compat/musl-compat.h` | sha256 `6e25a7aee80088871397b2672f22edb5cf6dea122169003354dba570ba966e58` | Floe-authored build-time compat header: `TEMP_FAILURE_RETRY` (absent in musl), `MSG_COPY` guarded. Macro contents byte-carried from the verified internal qualification tree; the repair round added a `#ifndef __ASSEMBLER__` guard because a *clean* rebuild also `-include`s it into `loader/assembly.S`, where musl `errno.h`'s extern declarations are not valid assembler (Main's verified incremental build never recompiled loader with compat, so the clash was latent). C-TU semantics are unchanged | MPL-2.0 (Floe-owned); `-include`d at compile time, not shipped |
| `patches/tracee-event-exitkill.patch` | patch sha256 `7e512b801861e520d9449025daab07261e74ea0a002ae545c9fd529e24ca48ca`; `src/tracee/event.c` before `69041eb86eaf34e3cbc12d3b741fb231ef18be7451ca7ac5bd766cf9cbcc34fa` → after `7eea115f58c7fd3ed0b9583cf35d9f6b7d666d21074a9784534d7bac092c0f7b` | the ONLY upstream-file edit: adds `PTRACE_O_EXITKILL` to `default_ptrace_options` | captured upstream patch; the file keeps its original GPL-2.0-or-later notice; the patch ships inside the complete corresponding source |
| Debian guest rootfs | `debian-bookworm-aarch64-pd-v4.7.0.tar.xz` sha256 `4baa32280cc70b67e2c650777c1d974349f0cdf23afaabc305ad3bc6182b8df8` (https://github.com/termux/proot-distro/releases/tag/v4.7.0) | Debian binary packages under individual DFSG licenses; proot-distro tooling GPL-3.0 | NOT an input to this producer; packaging/redistribution decisions belong to Main with device evidence |

Rejected input (correction of the earliest recipe): the macOS SDK
`MacOSX27.0/usr/include/sys/queue.h` begins with an APSL-2.0 notice over
the BSD text; it must not be used or described as a BSD-only input.
`build-bootstrap.sh` fails if any `compat`/`config`/`cross` input contains
Apple/APSL text.

## Applied build deltas (complete list)

The upstream archive is used pristine except for exactly one pinned patch
(the EXITKILL delta above, with before/after hashes enforced by the
producer; zero drift otherwise, verified 2026-10-22 against the fresh zip
extraction). All remaining deltas are environment/flags/shims — captured
from the verified qualification run (`r1/termux-bootstrap/build-*.log`,
internal work tree):

1. `cross/aarch64-linux-musl-*` shims (zig cc musl forwarding; `-Wl,-Ttext`
   loader links routed to NDK `ld.lld`; llvm-objcopy/objdump; fake-ld
   version probe; pkg-config facade retained as reviewed material although
   the fork makefile has **no pkg-config query**). `cross/readelf` is a
   PATH shim answering the fork's bare `readelf -s` in the loader-info.c
   rule; it forwards to NDK `llvm-readobj` exactly like the verified
   internal `cross-bin/readelf`, and reproduces `loader-info.c`
   byte-exactly (sha256 `5870a6f1a1634f9fc5885e92cfd49da7b71e5f9ffbc9d0ec995bf4d95a744a6d`,
   re-verified 2026-10-22 by re-running the pipeline against the verified
   loader ELF).
2. `make CC=… CROSS_COMPILE=… HAS_LOADER_32BIT= CHECK_FEATURES="" -j6`,
   invoked as `make -f <abs>/GNUmakefile` from `src/` so VPATH/SRC are
   absolute and whitespace-free.
   - `CC=` **must** be passed explicitly: the fork's `CC ?=
     $(CROSS_COMPILE)gcc` never fires, because GNU make's `?=` does not
     replace the built-in default `CC=cc` (origin "default" ≠ "undefined").
     Without it every TU silently compiles with host macOS cc (no
     `<linux/*>` headers) — observed in this repair round; make still
     exited 0 (.IGNORE) and only the artifact gates caught it.
   - `HAS_LOADER_32BIT=`: ARM64-only. The verified payload links the m32
     blob symbols **weak-undefined** (`w _binary_loader_m32_exe_start`),
     so forcing empty is what reproduces it; the producer re-checks this
     symbol shape.
   - `CHECK_FEATURES=""`: the fork's `.check_%.res` rule marks a
     capability when the probe binary merely *exists* (compiled), which
     would fake-detect `HAVE_PROCESS_VM`/`HAVE_SECCOMP_FILTER` from
     cross binaries that can never run on macOS. With an empty list
     `build.h` carries **no defines** (sha256 `60dd78f83b02c4bbb3525be31f9226151ab508f342ca71346b862483b07984ed`,
     matching the verified tree), and the capabilities are declared
     explicitly below instead — Android min28 kernels support both.
   - env `CFLAGS +=` (never on the command line — command-line variables
     defeat the makefile's own `CPPFLAGS +=`, which drops `-D_GNU_SOURCE`
     and reproduces the verified run-3 failures):
     `-D_LARGEFILE64_SOURCE` (musl exposes `struct rlimit64`/`statfs64`
     + `prlimit64`/`statfs64` aliases only under it; the fork's own
     CPPFLAGS only sets `_GNU_SOURCE` — this was the real incomplete-type
     error), `-DHAVE_SECCOMP_FILTER -DHAVE_PROCESS_VM` (explicit cross
     feature capabilities), `-include <work>/musl-compat.h`,
     `-I<talloc-prefix>/include` (talloc.h + the staged pure-BSD
     `sys/queue.h`), `-ffile-prefix-map` for determinism.
   - env `LDFLAGS += -L<talloc-prefix>/lib` (the fork links plain
     `-ltalloc`).
   - `ARG_MAX` needs no define: 131072 resolves from the pinned
     `linux/limits.h`.
3. talloc 2.4.2 hand-built static: two TUs (`talloc.c`,
   `lib/replace/replace.c`) with the reviewed cross `config.h`
   (`config/talloc-config.h`; `cross-answers.txt` retained as the
   waf-probe answer record), archived `llvm-ar rcSD`, headers staged under
   the prefix (incl. `sys/queue.h`). The TU command also needs
   `-D__STDC_WANT_LIB_EXT1__=1` (hard `#error` in `lib/replace/replace.h`)
   and `-DTALLOC_BUILD_VERSION_MAJOR=2 -DTALLOC_BUILD_VERSION_MINOR=4
   -DTALLOC_BUILD_VERSION_RELEASE=2`; the version defines were
   binary-recovered from the verified archive (`talloc_magic =
   0xea18ee70` ⇒ 2.4.2) because the parent transcript only preserved the
   failing pre-define attempts.
4. Output verification instead of exit-code trust: the fork GNUmakefile
   scopes `.IGNORE`/`.INTERMEDIATE` around its probes and the verified
   space-path run proved make can exit 0 while recipes failed. The
   producer therefore scans the make log for failure signatures, requires
   the exact 70-object set (m32 objects must be absent), verifies
   `build.h`/`loader-info.c` hashes, then runs `llvm-readelf -lW` gates
   (wide format; **assert a nonzero parsed LOAD count** before the
   ≥16KiB alignment check — wrapped `-l` can fold a row and leave
   `p_paddr` at the line end) plus AArch64/EXEC/static and the
   embedded-vs-weak loader symbol shape.
5. `loader.elf`/`loader.exe` are deleted GNU-make `.INTERMEDIATE`s; the
   relink/lineage evidence exported under `$OUT/build/` is instead the
   full object set (including `loader/loader-wrapped.o`, which carries the
   embedded stripped loader bytes), the generated files, the patched
   source and the make log.

## Loader packaging (upstream-provided channel)

The fork embeds its loader (`loader/loader-wrapped.o`) inside
`libproot.so`; the same build produces the standalone freestanding loader
ELF (`src/loader/loader`). The verified pre-patch payload hash family is
`libproot.so` `db8968b988c5a6f129c88f0d516e4ec1bcec12da522800460d6c77534c831bc2`
and `libproot_loader.so` `3ef215b13e37bfd9454a5dfa8125a912177fbd693025753a4e8c1eb1e58ed735`
(both AArch64, static, all LOAD segments 64KiB-aligned ⇒ 16KiB-compatible;
re-verified against `llvm-readelf -lW` on 2026-10-22). Byte-equality with
the *pre-patch* payload hashes is NOT promised and was measured on the
canonical rebuild: `libproot.so` intentionally differs (the pinned EXITKILL
patch changes `tracee/event.o`; the disassembly now builds the options
mask with the `PTRACE_O_EXITKILL` bit at both SETOPTIONS sites, plus
`-ffile-prefix-map` path normalization). For the standalone loader, the
`.text`/`.rodata`/`.data`/symbol-table contents are **byte-identical** to
`3ef215b1…` (executable equivalence, compared 2026-10-22); only `.debug_*`
metadata differs (prefix-map, the compat header being `-include`d into
`loader.c` on a clean rebuild, and build-path provenance).
`PROOT_LOADER="$NATIVE_LIBRARY_DIR/libproot_loader.so"` remains the
supported override when the embedded copy must be bypassed.

## Lineage — generic v5.5.0 baseline (historical, superseded)

The earlier producer pinned proot-me v5.5.0 (commit `25dc6a31…`, tarball
sha256 `287cfb27f58e100b0153006cb352268225bb9ad9d41d9b52ed56d01a22c13e6f`;
its loader payload `9cf8e3cf89d2168ee76ee34c12146c1ef752d5ce1adad7b90e2330258f793925`).
That binary remains *reproducibility baseline* only. Main's device chain:
A10 — the generic cross build's disabled feature probes and tracing path
were mismatched, leaving the loader `open` untranslated and giving
ENOENT for `/usr/bin/sh` (not an mmap denial); A12 — `PROOT_NO_SECCOMP=1`
restores translation and glibc file-backed `PROT_EXEC` mmap **succeeds**;
A13 — glibc then encounters inherited Android SIGSYS behavior; the exact
trapped syscall was not independently recorded. Rseq tunables alone change nothing. The maintained
Termux fork handles the Android outer-seccomp SIGSYS lineage correctly
(its `src_tracee_event.c` handling is the actual fetched primary source),
and A14 with this fork binary achieved real Linux guest success
(`id`/`uname`/`os-release`/stdout/stderr/exit-23, owned group-SIGKILL +
reap, `realLinuxSleepChildGone`). Diagnostics like `PROOT_NO_SECCOMP`
were investigative only — the final run uses neither it nor
`GLIBC_TUNABLES`, and nothing here weakens the OS seccomp policy.

## License obligations — truthful per-component (no filename-based guarantees)

- **Combined terms of `libproot.so`**: PRoot (fork; per-file
  GPL-**2.0-or-later**) is statically linked with talloc + lib/replace
  (LGPL-**3.0-or-later**). LGPL-3.0 section 4 does not permit distributing
  the combined work under GPL-2.0-only terms, so the earlier “GPL-2.0 safe
  floor” choice is corrected: the producer **exercises PRoot's per-file
  “or later” option and the combined binary is offered under
  GPL-3.0-or-later**. Requirements when shipping: (a) original notices
  preserved — per-file GPL headers, the upstream `COPYING` (GPL-2.0 text)
  and the talloc/lib/replace LGPL notices travel unchanged inside the
  pinned archive/CCS (the EXITKILL patch does not remove any notice);
  (b) **complete corresponding source** for the combined program under
  GPL-3.0-or-later = the pinned archives + the one patch + *this exact
  recipe* (flags, shims, vendored headers, hashes), offered alongside the
  binary; (c) LGPL-3.0 static-link relink obligations — satisfied by the
  CCS plus the exported `talloc.o`/`replace.o`/`libtalloc.a`/staged prefix
  under `$OUT/build/`, letting recipients modify and relink; (d) BSD-3
  notice obligations for `sys/queue.h` — retained verbatim in
  `compat/queue.h` (+ `.patch` record); it is build-time-only (the ELFs
  carry no copyrightable BSD bytes, only macro-expanded plumbing) and the
  notice is passed through regardless.
- **`libproot_loader.so`** comes from the same pinned fork source and
  carries the same obligations as `libproot.so`.
- **QRoot launcher / JNI boundary**: the Floe-owned Java/Kotlin (MPL-2.0)
  and `libfloepty.so` JNI code **never link, embed or derive from GPL
  PRoot internals**; the transport execs the binary as a separate child
  process. GPL internals must not be grafted into the JNI library. This
  is a process-boundary statement, not a security-sandbox claim.
- **zig**: MIT, host tool only, not shipped.
- **NDK**: toolchain under its own terms; only the independently
  BSD-licensed `sys/queue.h` file is retained in-repo (with notice).


## Incorporated C runtime notices (Main review)

The Zig executable is a build tool, but the static helper incorporates
musl and compiler builtins from that pinned distribution. Keep the complete
`../licenses/musl-COPYRIGHT` and `../licenses/Zig-LICENSE` with binary
materials, along with the retained BSD queue-header notice. The pinned Zig
archive contains those runtime sources; these inputs are not replaced by
a claim that a static binary contains no shipped C runtime.
