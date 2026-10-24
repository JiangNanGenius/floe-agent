# Android Git component build

This source overlay pins libgit2 1.9.2, SwiftGitX 0.4.0 and Mbed TLS 3.6.7. See `PINS.json`, upstream license files and `README.md` for the exact revisions and local overlay. Upstream source bytes remain unchanged; the local `floe_common_crypto.c` translation unit includes the original CommonCrypto source only when its backend is selected.

The current 951-file `VENDOR_FILE_HASHES.sha256` digest is:

```text
4725b4b2b1a494942a11f011c71fc06cf4b7c9869f8bf17f48ae95adc3a71a39
```

From the FloeAndroid directory, verify the source overlay without changing it:

```sh
(cd shared/Vendor/Git && shasum -a 256 -c VENDOR_FILE_HASHES.sha256)
```

Use the existing `scripts/env.sh` toolchain configuration. Set `DEVELOPER_DIR` to the actual installed Xcode developer directory on the build host; qualification used Xcode 27.1 with Swift 6.4.1, Android SDK 37 and NDK 30. For a nested source checkout, explicitly set `FLOE_ANDROID_TOOLCHAINS` and `FLOE_ANDROID_CACHE_ROOT` to the existing toolchains and warm cache before sourcing the script. Do not change global xcode-select or create another checkout to build these components.

Run in Bash, sequentially on the same scratch directory:

```sh
source scripts/env.sh
for floe_git_component in MbedTLS FloeGit; do
  "$FLOE_SWIFT_BIN/swift" build --build-system native \
    --package-path "$FLOE_ANDROID_ROOT/shared" \
    --target "$floe_git_component" \
    --scratch-path "$FLOE_ANDROID_CACHE_ROOT/swift-native" \
    --swift-sdks-path "$FLOE_SWIFT_SDKS" \
    --swift-sdk swift-6.4.1-RELEASE_android \
    --triple aarch64-unknown-linux-android28 --jobs 6 -c release
done
```

MbedTLS must be present for the final Git HTTPS link. Building a Swift target alone is insufficient evidence of its complete C link closure. Retain these warm objects for the subsequent full `FloeAndroidCore` product link. Do not rebuild an unchanged Linux authority merely to check Git.

The Git and browser targets were compiled to actual AArch64 ELF objects on 2026-10-24. This component result does not establish a full Core link, behavioral tests, Android UI/device acceptance, real account authentication or remote Git/Actions behavior. Private build paths, logs, object manifests and original failure records stay in the local qualification evidence, outside public releases.
