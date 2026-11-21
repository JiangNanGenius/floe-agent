# Linux guest graphics build inputs

This directory holds the reviewed, public build inputs for the Linux guest
graphics stack. It is not a runtime image and contains no compiled binary.
Nothing here changes the installed v8 image or proves an iOS/App result.

`SOURCE-SELECTION.json` records two distinct streams:

| Stream | Role | Status |
| --- | --- | --- |
| Debian Mesa 25.0.7 (guest) | Frontend (`libgallium` + `libGLX_floe`) and the Venus Vulkan ICD used by a Linux guest image | Source verified; patch applies cleanly; native image build not run by this intake |
| Mesa 30da3918 + Hadron (host) | Next macOS KosmicKrisp backend for private Linux acceleration | Source/apply chain verified; macOS component and Linux runtime qualified privately; iOS port UNBUILT and upstream-unsupported |

The App's shipped ``FloeGPU`` binary remains the pinned virglrenderer + MoltenVK
1.4.2 stack. The newer host Mesa/Kosmickrisp selection must not be linked into
iOS, and its macOS archives must not replace an Apple-platform binary.

## Guest stream

Public inputs are the Debian `mesa_25.0.7.orig.tar.xz` archive and
`patches/guest-mesa-25.0.7/0001-floe-x11-cpu-present-complete.patch`. The patch
adds the generic X11 CPU-present path for present-aware Vulkan WSI: queued
`PresentPixmap`, FIFO pacing through XCB present completion, resize handling,
error rollback and init/destroy cleanup. It supersedes every intermediate WSI
patch that preceded it.

Apply `0002-floe-apple-hardware-identity.patch` from the same guest series.
Vulkan's device name and integrated or discrete device type come from the
Apple renderer. The guest driver identifies itself with `VK_DRIVER_ID_MESA_VENUS`.
Floe BLAS uses the driver ID and reported device type to select its backend.

The frontend build uses `-Dglx=dri -Dglvnd-vendor-name=floe
-Dgallium-drivers=softpipe,zink -Dshader-cache=enabled
-Dshader-cache-max-size=64M` and installs under a private prefix
(`/usr/lib/floe-gpu`). The shader cache is a bounded 64 MiB persistent cache;
it is not enabled until an image actually contains this frontend and the
capability declaration records it.

The Venus ICD build uses `-Dvulkan-drivers=virtio -Dgallium-drivers=[]` and
links with `-Wl,-z,nodelete`. Do not mix objects or shared libraries from a
previous frontend/Venus configuration: the WSI structures must be rebuilt
together.

## Host stream

The host series contains 86 reviewed Mesa/Hadron patches, 5 Floe patches
(static headless component, embedded resolver, iOS link check, geometry
bounds, allocation-size checks), one portable 64-bit literal fix, one memory
types fix and three driver-hardening patches: 96 entries in total.
`SERIES.json` binds the exact order and digests. Use `prepare_mesa_sources.py` to verify and apply the series; never
apply a prefix of the series or a stale intermediate patch.

The accepted host configuration is static KosmicKrisp only:
`-Dfloe-kk-embedded=true -Ddefault_library=static -Dplatforms=macos
-Dvulkan-drivers=kosmickrisp -Dgallium-drivers=[] -Dopengl=false`.
The target is the static component link check. The iOS static port and its
generated compiler tools are explicitly UNRUN.

## Verification

```sh
python3 FloeAgent/scripts/graphics/verify_graphics_sources.py
python3 FloeAgent/scripts/graphics/prepare_mesa_sources.py \
    --series guest --archive /path/to/mesa_25.0.7.orig.tar.xz
python3 FloeAgent/scripts/graphics/prepare_mesa_sources.py \
    --series host --archive /path/to/mesa-30da3918....tar.gz
```

`--apply` requires a fresh `--work-dir` and writes a receipt. It never
downloads and never invokes a compiler. Use the printed `tree` path for Meson.

`CAPABILITY-POLICY.json` maps each capability to the installed artifacts that
must exist before a manifest may declare it. `emit_capabilities.py` writes the
optional `graphics` block for an image manifest and refuses a declaration that
lacks artifacts or a required gate. `shaderCache` additionally requires a build
receipt recording the actual Meson cache options; library presence alone does
not prove the cache was enabled. Video `nativeSoftware` is explicitly not
hardware. Blender is not a capability.

## Qualifications and limits

- The guest WSI V2 patch passed a read-only apply check against the pinned
  pristine Mesa 25.0.7 tree on 2026-11-15.
- Private macOS-hosted interpreted Linux evidence (preserved at its original
  artifact) covers six WSI frames/resize/pixels, 17 geometry runs, 21 logic
  cases, OpenGL transform feedback, Blender GUI Workbench and background CLI.
  That evidence is not iOS, physical-iPad or App acceptance.
- The fixed 128 MiB indirect geometry-shader heap remains; oversized indirect
  draws fail explicitly instead of wrapping.
- The repository includes the OpenCL build inputs, the native ABI4 video
  backend and the virtio-media kernel module source. A compatible installed
  guest needs the matching binaries and a verified image manifest before
  those devices appear. See [acceleration image assembly](ACCELERATION-IMAGE.md).
- The installed v8 image remains the current baseline. A new image requires a
  real build and a new installed-image qualification.

License texts are retained under `LICENSES/`. The patches are Mesa/Hadron
derived under their upstream notices; the Floe patch text is MPL-2.0.

## 简体中文

本目录只保存可公开复核的 Linux 图形源码与构建输入，不包含已编译镜像或二进制。
`SOURCE-SELECTION.json` 区分两条来源：客户机 Debian Mesa 25.0.7（现有 v8 镜像
路径）与宿主机 Mesa 30da3918/Hadron（下一代 macOS KosmicKrisp，iOS 尚未构建，
上游亦不支持 iOS）。App 当前仍使用 `Vendor/FloeGPU` 的 virglrenderer+MoltenVK
1.4.2，不得混用宿主机或 Linux 产物。

`prepare_mesa_sources.py` 默认只校验哈希，`--apply` 才在新建目录解压并应用补丁；
不会下载、编译或启动虚拟机。`emit_capabilities.py` 只有在所需产物真实安装且
有资格标识时才生成能力声明；没有证据的能力一律不可用。Blender 不是能力项，
视频“原生软件”单独计数。OpenCL 构建输入、ABI4 原生视频后端、virtio-media
内核模块源码已经接入，配套镜像的构建和能力核验见[镜像组装说明](ACCELERATION-IMAGE.md)。
