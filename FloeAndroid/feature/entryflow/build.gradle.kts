// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C07 App-entry presentation. Presentation only: the App-owned
// `app/host/entryflow` controller owns platform Intent admission, the real
// SharedUriGrantAuthority lease, Notes/attachment handoff, diagnostics
// redaction and export. No store, network, credential or process code lives
// here.
android {
    namespace = "com.floe.android.feature.entryflow"
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
