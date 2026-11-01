// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C05 desktop-assist presentation. The App-owned controller
// (`app/host/desktopassist`) owns the trusted `floe.desktopassist/22` channel,
// the original credential vault metadata and the RAM-only secret editor. This
// module adds no transport, credential store or persistence code.

android {
    namespace = "com.floe.android.feature.desktopassist"
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
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.junit)
}
