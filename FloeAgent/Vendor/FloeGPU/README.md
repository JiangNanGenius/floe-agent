# FloeGPU static dependencies

`FloeGPUBinary` contains the Venus renderer and MoltenVK for arm64 iOS,
iOS Simulator and macOS. The App uses public Metal APIs. The package does
not contain a host CPU JIT or an OpenGL/video acceleration backend.

`PROVENANCE.json` records the exact renderer commit, local patch, official
MoltenVK archive and every shipped library/header digest. Run `python3 verify.py`
for read-only verification. License texts are retained in `LICENSES/`.

The renderer is built from `utmapp/virglrenderer` at the recorded commit,
with `ThirdParty/FloeVirtualGPU/patches/0001-floe-vkr-accounting.patch` applied.
Meson options are `--buildtype=release --default-library=static -Dvenus=true
-Drender-server-mode=thread -Drender-server-worker=thread -Dunstable-apis=true
-Dvulkan-dload=false -Dtests=false -Dvtest=false -Dcheck-gl-errors=false`.
Build with Python 3 including PyYAML, Meson, Ninja and pkg-config.
Build each platform with its matching Apple SDK and arm64 target; use six
Ninja jobs initially. The iOS builds use Meson Darwin cross files with
`subsystem='ios'` and `needs_exe_wrapper=true`.
Set both C and link arguments to `-mmacosx-version-min=15.0` for macOS;
the device and Simulator cross targets use iOS 16.0 explicitly.

The pinned libepoxy 1.5.10 headers/build dependency is needed by the upstream
renderer configuration. It is not linked into the final Venus-only consumer.
Supply a matching per-platform pkg-config prefix; do not link a Homebrew
dynamic library into an iOS binary. Vulkan C headers come from the recorded
official MoltenVK distribution.

For each platform, extract the arm64 slice of the official MoltenVK static
archive with `lipo -thin arm64` when necessary. Merge it with that platform's
`libvirglrenderer.a` using `xcrun libtool -static`, then assemble the three
archives and C headers with `xcodebuild -create-xcframework`. This binary is
consumed only by the `FloeVirtualGPU` C target, which exposes the public module.
Do not place a `module.modulemap` at the binary's header root: Xcode copies
static-library headers into a shared `include` directory. C sources include
Vulkan and virgl headers explicitly. Preserve the current artifact while rebuilding to
a fresh output directory. A local rebuild has its own hashes and requires
consumer linking/runtime qualification before replacing these bytes.
