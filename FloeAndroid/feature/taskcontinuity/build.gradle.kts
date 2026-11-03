// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C02 durable task continuity presentation. Presentation only: the App-owned
// `app/host/taskcontinuity` controller owns the trusted-host calls; the Swift
// coordinator owns the pause marker, storage probe, resume validation and the
// canonical question/approval wait identity. No store, transport, credential
// or process code lives here.
android {
    namespace = "com.floe.android.feature.taskcontinuity"
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
