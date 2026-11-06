# Manifold native core

Floe uses [Manifold 3.5.4](https://github.com/elalish/manifold/tree/ce50d78021d64507f89e8c9fc2c2e51018117857), commit `ce50d78021d64507f89e8c9fc2c2e51018117857`, under Apache-2.0. `Manifold-SOURCE.json` records the source archive digest and every packaged file digest. `Manifold-LICENSE.txt` and the App's `Manifold-NOTICES.txt` retain the notices. The upstream algorithm is unchanged.

The static archives target arm64 iOS 26, arm64 iOS Simulator 26, and arm64 macOS. They were built with Xcode 27.1 (27A9275). The adapter is the separate `Sources/ManifoldShim` target. C++ headers stay private to that adapter; adding a root `module.modulemap` would collide with the existing XAtlas binary header output in Xcode.

To reproduce, download the pinned GitHub source archive and verify its SHA-256 against the manifest. Configure each slice with these common options:

```sh
cmake -S SOURCE -B BUILD -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DMANIFOLD_TEST=OFF \
  -DMANIFOLD_CBIND=OFF -DMANIFOLD_PYBIND=OFF -DMANIFOLD_PAR=OFF \
  -DMANIFOLD_CROSS_SECTION=OFF -DMANIFOLD_DOWNLOADS=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build BUILD --target manifold --parallel 6
```

For iOS, add `-DCMAKE_SYSTEM_NAME=iOS`, `-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0`, and the selected SDK's full path as `CMAKE_OSX_SYSROOT` (`iphoneos` or `iphonesimulator`). Select Xcode per command with `DEVELOPER_DIR`; do not change global `xcode-select`.

Copy upstream `include/manifold` and the generated `include/manifold/version.h` into one headers directory. Package the three `src/libmanifold.a` archives with `xcodebuild -create-xcframework -library … -headers …`. Check the packaged library and header digests before adopting a rebuild. Run `python3 ../scripts/verify_manifold_vendor.py` from this directory, or invoke it by its repository path.

Manifold produces closed triangle meshes. Mixed modeling keeps the original precise body and mesh source, while the authored result explicitly retains mesh precision. Exact faceted conversion uses the existing OCCT kernel separately.
