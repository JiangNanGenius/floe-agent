// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C02 tool-result paging presentation. Presentation only: the App-owned
// `app/host/toolresults` controller owns the trusted-host `floe.results/20`
// call; the Swift domain/store owns retention, ownership and byte windows.
// No transport, credential or file code lives here.
android {
    namespace = "com.floe.android.feature.toolresults"
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
