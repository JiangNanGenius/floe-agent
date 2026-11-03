# C05 device communication — third-party pins and licences

This directory records the exact Android USB serial dependency used by
`:core:devicecommunication`. The Android BLE GATT path uses only the platform
`android.bluetooth` APIs and adds no third-party library. TCP/Telnet uses only
the JDK `java.net` surface. The model tool bridge uses no third-party runtime.

## usb-serial-for-android 3.11.0

* Upstream: <https://github.com/mik3y/usb-serial-for-android>
* Exact tag: `3.11.0`
* Exact tag commit: `8e694372dee4531d140766df7af3189d3d9531c5`
* Distribution (JitPack, the upstream-documented repository):
  * AAR `com.github.mik3y:usb-serial-for-android:3.11.0`
  * URL <https://jitpack.io/com/github/mik3y/usb-serial-for-android/3.11.0/usb-serial-for-android-3.11.0.aar>
  * size 68,000 bytes
  * SHA-256 `f74032134a4ded3276ccc02bec0d278015bc3c93ef04473b98fbda2771d7e439`
  * POM size 1,733 bytes
  * POM SHA-256 `57a557bf88541b00c34878c58a4e39aa9de6e4fe0b01693d7d8e7f5704e2390c`
  * transitive runtime dependency: `androidx.annotation:annotation:1.10.0`
  * compile dependency: `org.jetbrains.kotlin:kotlin-stdlib:2.2.10` (already
    supplied by the project's Kotlin plugin)
* Licence: MIT
  * exact upstream `LICENSE.txt` SHA-256
    `6f467d3d79c5d31734881fb83e082e84512bde05d3f7893e0e8373fd0d2b5d2c`
  * retained verbatim in `usb-serial-for-android-LICENSE.txt`

No version is floating and no other JitPack group is enabled. The pin is
declared in `gradle/libs.versions.toml` (`usb-serial = "3.11.0"`) and the
JitPack repository is content-filtered to `com.github.mik3y`. Main owns the
Gradle lockfile regeneration; the exact artifact hash above is the verification
value for that first resolution.

The Android USB host path uses the user's per-device `UsbManager` grant and
never asks for storage/all-files access. USB storage remains SAF.
