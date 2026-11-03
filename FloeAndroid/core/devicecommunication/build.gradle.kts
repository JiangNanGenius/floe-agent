// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library) }

// C05 device communications: real bounded TCP/Telnet sessions, Android BLE
// GATT sessions and USB serial sessions.
//
// The module owns the platform transports and their bounded, generation-fenced
// state only. It requests no permission and opens no system dialog: the App
// host calls an explicit user action first and supplies the resulting grants.
// The trusted UI bridge (`floe.device/14`) and ordinary model tools are
// App/Swift-owned; no model path, V3 command or Linux/guest execution route
// exists here.
android {
    namespace = "com.floe.android.core.devicecommunication"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation(libs.kotlinx.coroutines.core)
    // Exact user-approved C05 pin: usb-serial-for-android 3.11.0. The exact
    // tag commit, AAR/POM SHA-256 and MIT licence text are recorded under
    // FloeAndroid/licenses/devicecommunication/. Never update implicitly.
    implementation(libs.usb.serial)
    testImplementation(libs.junit)
}
