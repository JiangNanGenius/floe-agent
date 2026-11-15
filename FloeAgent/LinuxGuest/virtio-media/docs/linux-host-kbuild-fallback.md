# Mature Linux-host kbuild fallback (recipe only — NOT executed)

Prepared 2026-11-11 after repeated Darwin host-tool friction. This is the
bounded alternative if the Darwin `modpost` path fails once more. It uses the
exact pinned Debian 6.12.107-1 arm64 header/kbuild packages and the immutable
package inputs; **no VM/container has been started** (default Colima is
stopped; starting anything needs primary + Root resource coordination).

## Inputs (immutable, hash-pinned in config/build-inputs.json)

- `guest/downloads/linux-source-6.12_6.12.107-1_all.deb` (sha256 775b9ef8…)
- `guest/downloads/linux-headers-6.12.107+deb13-arm64_6.12.107-1_arm64.deb` (sha256 20cc55bd…)
- `guest/downloads/config-6.12.107+deb13-arm64` (sha256 44342a19…)
- `guest/downloads/Module.symvers-6.12.107+deb13-arm64` (sha256 4e1420af…, 26760 symbols)
- Extra debs needed from the same Debian pool (NOT yet downloaded; fetch only when this route is authorized):
  - `linux-headers-6.12.107+deb13-common_6.12.107-1_all.deb` (arch-independent UAPI headers)
  - `linux-kbuild-6.12.107+deb13_6.12.107-1_arm64.deb` (prebuilt kbuild host tools + scripts)
- Driver: `driver/` from this package (byte-identical to the ChromeOS pin, sha256 in HANDOFF.json)

## Host

Any mature Debian/Ubuntu Linux with stock `aarch64-linux-gnu-gcc` (Debian
package `gcc-aarch64-linux-gnu`, bookworm/trixie) OR a native arm64 Debian
host. No macOS SDK involved; glibc never forces uuid_t through <sys/types.h>,
so the file2alias.c host tooling builds unmodified.

## Steps (exact)

```sh
work=/build/fvm-module          # isolated task dir; NO home/credentials mounts
mkdir -p "$work" && cd "$work"
# dpkg -x the three/five pinned debs here; then:
tar -xJf usr/src/linux-source-6.12.tar.xz     # only if full-source route
KSRC=$work/linux-source-6.12                  # or the Debian headers dir:
# KSRC=$work/usr/src/linux-headers-6.12.107+deb13-arm64  (with
#   usr/lib/linux-kbuild-6.12.107+deb13/scripts reachable via the headers'
#   relative symlinks — that is the standard Debian out-of-tree layout)
cp /pins/config-6.12.107+deb13-arm64        "$KSRC/.config"   # when full-source
cp /pins/Module.symvers-6.12.107+deb13-arm64 "$KSRC/Module.symvers"
make -C "$KSRC" O="$work/out" ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=+deb13-arm64 modules_prepare
make -C "$KSRC" O="$work/out" ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=+deb13-arm64 \
     M="$work/modsrc/virtio-media" modules
```

`modsrc/virtio-media` is the same sha256-manifested copy the Darwin path uses
(produced by scripts/build_module.py step 5). With the Debian headers route
(KSRC = linux-headers-…-arm64), `modules_prepare` is mostly a no-op because
Debian ships prebuilt scripts/ + generated includes; LOCALVERSION is carried
by the headers themselves (release = 6.12.107+deb13-arm64).

## Post-checks (identical to the Darwin path)

- vermagic == `6.12.107+deb13-arm64 SMP mod_unload modversions aarch64`
- `nm -u` imports all resolve in Module.symvers; receipt records real CRCs,
  provider modules and the .modinfo `depends` string.
- module alias `virtio:d00000030v*` present in .modinfo.

## Why this is trustworthy

Same pinned config/symvers/vermagic inputs; modpost is Debian's own build of
the same source. Divergence risk vs the Darwin-built module is limited to
compiler flags (both gcc, freestanding) and is bounded by comparing sha256,
vermagic, __crc_ tables and modpost warnings between the two builds.
