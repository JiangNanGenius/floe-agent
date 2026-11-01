// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C05 device communication presentation: TCP/Telnet, BLE GATT and USB serial
// screens. Presentation only: sockets/GATT/USB live in
// :core:devicecommunication and the App-owned controller; the terminal pane is
// the EXISTING :feature:terminal renderer. No permission request, transport,
// credential or model authority lives in this module.
android {
    namespace = "com.floe.android.feature.devicecommunication"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation(project(":core:designsystem"))
    implementation(project(":core:devicecommunication"))
    api(project(":feature:terminal"))
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.junit)
}
