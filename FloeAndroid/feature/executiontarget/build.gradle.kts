// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C02 execution-target presentation. Presentation only: the App-owned
// `app/host/executiontarget` controller owns the trusted-host calls; the
// Swift domain/store owns pinning, validation, explicit migration, CAS and
// the drain gate. No transport, credential or process code lives here.
android {
    namespace = "com.floe.android.feature.executiontarget"
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
