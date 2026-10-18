#!/usr/bin/env python3
"""Configure the pinned local SDK without unquoted paths or global toolchain changes.

Equivalent to upstream setup-android-sdk.sh symlinks, but supports spaces in this repo.
Only task-owned SDK links are created; existing non-link files are never removed.
"""
import os
from pathlib import Path

tools = Path(os.environ["FLOE_ANDROID_TOOLCHAINS"])
bundle = tools / "swift-6.4.1-RELEASE_android.artifactbundle"
sdk = bundle / "swift-android"
ndk = Path(os.environ["ANDROID_NDK_HOME"]) / "toolchains/llvm/prebuilt/darwin-x86_64"
sysroot = sdk / "ndk-sysroot"


def link(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        if destination.resolve() == source.resolve():
            return
        destination.unlink()
    elif destination.exists():
        raise RuntimeError(f"Refusing to replace non-link: {destination}")
    destination.symlink_to(source.resolve())


link(ndk / "sysroot/usr/include", sysroot / "usr/include")
for library in (ndk / "sysroot/usr/lib").iterdir():
    link(library, sysroot / "usr/lib" / library.name)
clang = sorted((ndk / "lib/clang").iterdir())[-1]
link(clang, sdk / "swift-resources/usr/lib/swift/clang")
for folder in ("swift", "swift_static"):
    for obj in (sdk / "swift-resources/usr/lib").glob(f"{folder}-*/android/*/swiftrt.o"):
        link(obj, sysroot / f"usr/lib/{folder}/android" / obj.parent.name / "swiftrt.o")
link(bundle, Path(os.environ["FLOE_SWIFT_SDKS"]) / bundle.name)
print("Pinned Swift Android SDK linked to pinned NDK; no global SDK registration changed")
