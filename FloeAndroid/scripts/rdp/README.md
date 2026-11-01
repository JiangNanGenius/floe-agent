# C05 RDP Android native dependency build

Status: **source recipe only**. No native dependency build was run in the C05
source lane; the Android ARM64 archives still require a serialized build and
App/device qualification.

The Android RDP backend is the real upstream FreeRDP core plus the small Floe
bridge in `shared/Sources/FloeRDPNative`. No Apple binary, Apple framework or
Kotlin frame/RDP protocol substitute is used.

## Pins

`runtime.lock.json` is the authority:

| Dependency | Release | SHA-256 |
| --- | --- | --- |
| FreeRDP | 3.31.1 | `4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991` |
| OpenSSL | 4.0.1 | `2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09` |

Licences: `licenses/rdp/FreeRDP-LICENSE` (Apache-2.0, includes WinPR) and
`licenses/rdp/OpenSSL-LICENSE` (Apache-2.0).

The FreeRDP source pin and OpenSSL pin are the same releases recorded by the
fixed iOS donor (`FloeAgent/ThirdParty/FreeRDP/runtime.lock.json` at
`a59b4d4005f616c611df67fab7620e9853c525b9`). The Android build recipe is
separate and static.

## Build

Prerequisites: NDK `30.0.16248370`, CMake, Ninja, a C toolchain, and enough
free disk for one serialized native build. Set `ANDROID_NDK_HOME` (or
`ANDROID_NDK_ROOT`). Do not run this concurrently with an App build.

```bash
scratch=/absolute/scratch/freerdp-android
prefix=/absolute/prefix/freerdp-android-arm64
scripts/rdp/fetch_and_verify.py --scratch "$scratch"
scripts/rdp/build_openssl_android.sh "$scratch/openssl-4.0.1" "$prefix/openssl"
scripts/rdp/build_freerdp_android.sh \
  "$scratch/freerdp-3.31.1" "$prefix" "$prefix/openssl"
scripts/rdp/verify_prefix.py --prefix "$prefix"
```

The FreeRDP build enables the RDP core and WinPR only: clients, servers,
channels, X11/Wayland, SDL, FFmpeg/SWScale, cups, pulse/ALSA, PCSC, fuse,
uriparser, cJSON, opus, PNG/JPEG/WebP, Kerberos and all redirectors are off.
Static libraries are position-independent so they can link into the SwiftPM
`libFloeAndroidCore.so`.

## SwiftPM link

Main applies the `Package.swift` patch that adds:

* `FloeRDPNative` (C bridge, `FloeRDP.h`/`FloeRDP.c`);
* `FloeRDP` (Swift session/trust/frame module);
* header search and static link flags under
  `FLOE_FREERDP_PREFIX` (default `shared/Vendor/Remote/FreeRDP/android-arm64`).

The prefix is **not** committed. A build without the materialized prefix
fails truthfully at compile/link time; it does not fall back to an Apple
binary or a placeholder implementation.

## Bridge contract

`shared/Sources/FloeRDPNative/include/FloeRDP.h` is the fixed C contract
(copied byte-for-byte from the donor). `FloeRDP.c` is the donor bridge with a
single `#if defined(__ANDROID__)` compile guard so host builds compile an empty
translation unit instead of pretending to speak RDP.

* `floe_rdp_create/start/stop/destroy` own a worker and join it before
  releasing the callback context.
* `floe_rdp_input` admits whole batches atomically from a bounded queue.
* Frame and certificate callbacks run on the worker and copy/parse bounded
  bytes before returning.
* `VerifyX509Certificate` is routed to `RDPFloeCertificateTrust`, which only
  accepts an exact user-approved leaf SHA-256; every other result is an
  explicit challenge.

## Verification

`verify_prefix.py` checks the required headers, the two core archives, the two
OpenSSL archives, ARM64 static archives, required FreeRDP symbols, absence of
Apple binaries/client libraries, and writes a SHA-256 manifest. A successful
prefix verification is dependency evidence, not an RDP connection or App
acceptance.
