# Acceleration image build and install steps

These steps extend the existing clean base-image recipe. They are source and
build inputs only; the shipped `v8` image and its manifest are not modified.

## 1. Guest video

1. Build `FloeAgent/LinuxGuest/virtio-media` with
   `python3 scripts/build_module.py` against the exact pinned image kernel.
   Record the kernel release, compiler, `vermagic`, module SHA-256 and the
   source tree digest.
2. Use `boot_overlay/image_gate.py` in read-only mode to verify the module,
   initrd inputs and overlay layout. Then install through
   `boot_overlay/install_recipe.py` into a fresh base/initrd; never edit a used
   project disk or a frozen image.
3. Build the client:
   `cd FloeAgent/LinuxGuest/acceleration/video && make CC=aarch64-linux-musl-gcc`.
   Install `floe-codec` as `/usr/local/bin/floe-codec` (0755).
4. The engine must be compiled with the ABI4 source patch and the image
   manifest must declare `deviceCapabilities.videoAcceleration = true` only
   after both the module and client are present and verified.

## 2. Standard BLAS

1. Generate SPIR-V with `python3 build/build_spirv.py` using a trusted
   `glslangValidator`/`glslc`; the Makefile fails closed without the generated
   headers. Do not commit generated headers or binaries.
2. Cross-compile with the image's AArch64 Linux toolchain:
   `make CC=<cross-cc> TARGET_FLAGS="<target/sysroot>" -j2 all`.
3. Install with `scripts/install-floe-blas.sh --root <prepared-base> --build build`.
   The install contract is `/usr/local/lib/floe-acceleration/libfloe_blas.so`,
   `/usr/local/bin/floe-blas-run`, `/usr/local/bin/floe-blas-probe` and the
   mode/config assets.
4. A new task child may be wrapped by `floe-blas-run`; do not preload the
   shared runner or supervisor. The policy is `off|auto|on`; unsupported
   shapes/types retain the original CPU BLAS. `floe-accel compute status`
   reports the actual mode and provider presence.

## 3. Blender

1. Stage/install the standard ARM64 Linux Blender 4.3+ package (or a prepared
   guest runtime). The base image need not bundle Blender.
2. `cd FloeAgent/LinuxGuest/acceleration/blender && ./install.sh --prefix /usr/local`
   (or `--stage <owned-image-root>` for offline staging). `python3` is
   required; `vulkaninfo`/`glxinfo` are recommended for raw status facts.
3. `floe-blender status --json` must report the actual backend. GPU admission
   failure is explicit and never silently falls back to software; software is
   a separate user choice. `open` inherits the project `DISPLAY` and never
   starts X/VNC/desktop.

## 4. OpenCL

1. Supply clean upstream checkouts at the exact pins in
   `FloeAgent/LinuxGuest/acceleration/opencl/PINS.json`.
2. Run the producer's `--plan-only`/`--check-only` first, then `--execute` with
   an admitted external ARM64 Linux `clspv` and its manifest. Without the
   compiler the producer fails closed and packaging is refused.
3. Install the ICD, JSON, environment script and verified `clspv` under
   `/usr/lib/floe-opencl` and `/usr/share/floe-opencl`. Do not advertise
   OpenCL until a real ICD load and kernel run pass.

## 5. Dispatcher and capability declaration

1. Install `FloeAgent/LinuxGuest/acceleration/floe-accel` as
   `/usr/local/bin/floe-accel` (0755). It reports missing components and never
   substitutes a native-host process.
2. Only after the installed-image qualification, generate the optional
   manifest `graphics` block with
   `python3 FloeAgent/scripts/graphics/emit_capabilities.py` and a qualification
   identifier. `shaderCache` also requires a build receipt recording the
   actual Meson options. Missing artifacts or gates make the declaration fail.
3. A new image needs a new id, manifest, disk and real qualification; do not
   flip `qualified`/`distributionAllowed` on `v8` or reuse its id.

## 6. Not proven here

No module load, codec session, hardware-vs-software counter, BLAS kernel,
Blender render, OpenCL ICD load, image boot or App acceptance is included.
Source presence and a successful compile are not capability proof.
