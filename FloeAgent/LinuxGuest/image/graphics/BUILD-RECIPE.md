# Linux graphics build recipe

This recipe is source/build input, not build evidence. Run it only in a
separate, explicitly scheduled native window. Every command below is
reproducible from public archives plus this repository's patches.

## 0. Inputs and identity

| Input | Identity |
| --- | --- |
| Guest Mesa archive | `mesa_25.0.7.orig.tar.xz`, sha256 `592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6` |
| Guest WSI patch | `patches/guest-mesa-25.0.7/0001-floe-x11-cpu-present-complete.patch`, sha256 `0877816a0aa5291a38ffb830a36abee5673bea34babb24d8a1ad050332fb0704` |
| Host Mesa archive | `mesa-30da39187d8d3cf03c58ecd2bebb497b84501f51.tar.gz`, sha256 `74c234fda0351d71a104f6bd99984d1a3b085386a85df06c300778e4970fc465` |
| Host Hadron archive (provenance) | `hadron-f2f162e2b3af1f914040113c44eef2cceb30865a.tar.gz`, sha256 `8ea1cdedc7c69e76ffbff76b30f397e27ecbea1096fc829832fb83882c1d708a` |
| Host patch series | `patches/host-mesa-30da3918/SERIES.json`, 96 ordered patches |

`python3 FloeAgent/scripts/graphics/verify_graphics_sources.py` must pass before
using any input.

## 1. Prepare a tree

```sh
OUT="$HOME/Library/Caches/CodexBuild/FloeAgent/graphics/guest-wsi-$(date +%Y%m%d%H%M%S)"
python3 FloeAgent/scripts/graphics/prepare_mesa_sources.py \
  --series guest --archive /path/to/mesa_25.0.7.orig.tar.xz \
  --work-dir "$OUT" --apply
```

The script refuses an existing work directory, verifies the archive digest,
rejects archive members that escape the destination, verifies every patch
digest and applies with `patch -p1 -F0`. It prints the patched `tree` and a
`PREPARE_RECEIPT.json`. The host series uses `--series host` with the Mesa
30da3918 archive. Patch `0093` is applied from `src/kosmickrisp/vulkan`; the
series records that working directory.

## 2. Toolchain

- Apple Silicon macOS host, Xcode 27.2 (`27B52`) selected explicitly through
  `DEVELOPER_DIR`.
- For guest Linux artifacts: a pinned Debian trixie arm64 sysroot and a
  matching clang/lld cross wrapper. Do not substitute the macOS SDK or a
  Homebrew dynamic library.
- Meson + Ninja + Python 3 with PyYAML and pkg-config. The accepted private
  build used a dedicated virtual environment; no global package change.
- Six Ninja jobs initially. Stop if the internal volume falls below 30 GiB or
  measured memory pressure requires fewer jobs.

## 3. Guest Venus ICD

Configuration (from the accepted WSI V2 build):

```
meson setup BUILD TREE \
  --cross-file <arm64-linux-cross.ini> --native-file <native.ini> \
  --wrap-mode=nodownload --prefix=/opt/floe-gpu/wsi-v2 --libdir=lib \
  --buildtype=release \
  -Dplatforms=x11 -Dvulkan-drivers=virtio -Dgallium-drivers=[] \
  -Dopengl=false -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dglvnd=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled -Ddraw-use-llvm=false \
  -Dexpat=disabled -Dzlib=disabled -Dzstd=disabled -Dlibunwind=disabled \
  -Dlmsensors=disabled -Dvalgrind=disabled -Dbuild-tests=false -Dtools=[] \
  -Dshader-cache=disabled
ninja -C BUILD -j6 src/virtio/vulkan/libvulkan_virtio.so
```

Link `libvulkan_virtio.so` with `-Wl,-z,nodelete`. Generate the ICD JSON with
the pinned Mesa `src/vulkan/util/vk_icd_gen.py` against the same tree; never
invent a library path. Record all three artifact digests and the generated
JSON bytes before packaging.

## 4. Guest frontend (OpenGL/GLX + bounded shader cache)

```
-Dglx=dri -Dglx-direct=true -Dglvnd=enabled -Dglvnd-vendor-name=floe \
-Degl=disabled -Dgbm=disabled -Dplatforms=x11 \
-Dgallium-drivers=softpipe,zink -Dvulkan-drivers= -Dllvm=disabled \
-Dexpat=disabled -Dzlib=disabled -Dzstd=enabled -Dlibunwind=disabled \
-Dlmsensors=disabled -Dvalgrind=disabled -Dbuild-tests=false -Dtools= \
-Dshared-glapi=enabled -Dshader-cache=enabled -Dshader-cache-max-size=64M
```

Targets: `src/gallium/targets/dri/libgallium-25.0.7.so` and
`src/glx/libGLX_floe.so.0.0.0`. The 64 MiB cache is persistent but bounded; it
must live under the project's writable overlay, never a workspace 9P mount or
a RAM tmpfs. Enabling the cache changes only configuration; performance and
correctness require a fresh real run.

## 5. Host KosmicKrisp component

```
-Dfloe-kk-embedded=true -Ddefault_library=static -Dplatforms=macos \
-Dvulkan-drivers=kosmickrisp -Dgallium-drivers=[] -Dtools=[] -Dopengl=false \
-Degl=disabled -Dglx=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=disabled \
-Dllvm=disabled -Ddraw-use-llvm=false -Dmesa-clc=system -Dprecomp-compiler=system \
-Dshader-cache=disabled -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled \
-Dbuild-tests=false -Db_lto=false -Db_ndebug=false
```

Build target `src/kosmickrisp/vulkan/floe-kk-link-check` first. This is a
macOS static link check; it is not an iOS build. The iOS static headless /
resolver / link-check patches are included in the series, but the iOS compile,
generated Metal compiler tools and App link remain unrun.

## 6. Artifact checks

- `file`/`lipo`/`otool -l` prove the slice architecture and minimum OS.
- `readelf -h` (aarch64, ELF64 LSB), `readelf -d` (SONAME, no private
  `RUNPATH`/`RPATH`), and `nm -D --defined-only` must match the expected
  SONAME/exports.
- No absolute private build path may remain in a shipped library or JSON.
- The ICD JSON must refer to the exact installed library path, and the loader
  must resolve that path in a real guest.
- `emit_capabilities.py` is the only supported way to turn these artifacts into
  a manifest `graphics` block; it requires a qualification identifier and
  records the exact artifact digests.

## 7. What is not proven

- No compiler, linker, GPU, VM or App command was run while preparing this
  intake. The recipe's success is unverified until the coordinator schedules
  the native window.
- The private macOS-hosted Linux results do not prove iOS or physical-iPad
  capability.
- OpenCL, video nodes and Blender availability are not implied by these build
  inputs. See `SOURCE-SELECTION.json` `deferredComponents`.

## 8. Build receipt for capability emission

`emit_capabilities.py` refuses to declare `shaderCache` from library presence
alone: a configuration-only library can be built with the cache disabled. The
native build owner writes one small receipt beside the artifacts:

```json
{
  "schema": "floe.graphics.build-receipt.v1",
  "series": "guest-mesa-25.0.7",
  "mesonOptions": [
    "-Dshader-cache=enabled",
    "-Dshader-cache-max-size=64M",
    "-Dgallium-drivers=softpipe,zink"
  ],
  "artifacts": {
    "libgallium-25.0.7.so": "<sha256>",
    "libGLX_floe.so.0.0.0": "<sha256>"
  },
  "qualification": "<fresh installed-image qualification id>"
}
```

Pass it with `--build-receipt`. The producer records its SHA-256 in the
declaration evidence. A receipt is a build record, not runtime proof; the
installed-image qualification must still exercise the cache cases.
