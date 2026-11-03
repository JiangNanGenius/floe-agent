// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C05 SFTP remote-file presentation. Presentation only: the App-owned
// controller owns the trusted `floe.sftp/18` bridge lane and the native
// workspace commit; this module renders state and collects explicit user
// actions. No transport, credential or file authority lives here.
android {
    namespace = "com.floe.android.feature.sftp"
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
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.junit)
}
