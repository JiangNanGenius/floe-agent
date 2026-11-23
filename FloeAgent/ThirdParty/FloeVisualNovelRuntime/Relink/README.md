# Rebuild and relink ShioriKrkr for iOS

The archives here are the source for KiriKit 0.1.3 at `c1393f79f669cbe801c71af08ff6e8ed8ab5e72d` and FFmpeg n8.0.3 at `8ae0b34901ba60a802f183ee75a250a9fc3e09a5`. `SHA256SUMS` identifies both archives. The KiriKit archive contains the engine, C interface, CMake inputs, triplets, source pins and patches. Its `Scripts/krkr2/fetch.sh` fetches the pinned KiriKiri core, plug-ins and vcpkg releases, applies those patches and prepares both iOS dependency sets.

Use Xcode 27.2 (27B52), CMake, Ninja, Git, and Bison 3.8 in a fresh working directory with no spaces in its resolved path. Run these commands from the matching Floe App source tag. Set `relink_work` to a new directory whose parent already exists.

```sh
relink_inputs="$PWD/FloeAgent/ThirdParty/FloeVisualNovelRuntime/Relink"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CMAKE_BUILD_PARALLEL_LEVEL=6
(cd "$relink_inputs" && shasum -a 256 -c SHA256SUMS)
mkdir "$relink_work"
tar -xzf "$relink_inputs/KiriKit-0.1.3.tar.gz" -C "$relink_work"
tar -xzf "$relink_inputs/ffmpeg-n8.0.3.tar.gz" -C "$relink_work"
```

Apply your FFmpeg changes to `ffmpeg/`, then build it and link it into both ShioriKrkr slices. The build uses the original static FFmpeg configuration and the iOS 17 minimum for both slices. The engine fetch script applies its patches before you make any manual changes to the engine or plug-in sources.

```sh
bash "$relink_work/KiriKit/Scripts/krkr2/fetch.sh" arm64-ios-simulator arm64-ios
bash "$relink_inputs/build-ffmpeg-ios.sh" "$relink_work/ffmpeg" "$relink_work/ffmpeg-build"
export SHIORI_FFMPEG="$relink_work/shiori"
mkdir -p "$SHIORI_FFMPEG/Vendor"
mv "$relink_work/ffmpeg-build/ShioriFFmpeg.xcframework" "$SHIORI_FFMPEG/Vendor/"
bash "$relink_work/KiriKit/Scripts/krkr2/build-framework.sh" simulator device
```

In a separate copy of the matching Floe App source, replace the existing `FloeAgent/ThirdParty/FloeVisualNovelRuntime/ShioriKrkr.xcframework` with `KiriKit/Vendor/ShioriKrkr.xcframework` from this build. Regenerate the Xcode project with `bash FloeAgent/scripts/gen_project.sh`, build the App, and use your own signing identity for installation. The bundled license terms allow modifying the library and reverse engineering for debugging those modifications. See the corresponding source notice in the App's third-party licenses.
