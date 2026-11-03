// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C05 SSH remote-host screens. Presentation only: the App-owned controller
// (`app/host/remote`) owns the bridge, credentials, profile persistence and
// live session lifecycle. The terminal surface is the EXISTING
// `:feature:terminal` Termux-emulator renderer; this module adds no parser,
// process, transport or credential code.
android {
    namespace = "com.floe.android.feature.remote"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}
dependencies {
    implementation(project(":core:designsystem"))
    api(project(":feature:terminal"))
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.junit)
}
