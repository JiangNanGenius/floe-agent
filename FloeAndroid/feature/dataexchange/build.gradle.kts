// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C07 backup/restore and document-package presentation. Presentation only:
// the App-owned `app/host/dataexchange` controller owns SAF, bridge jobs,
// hashing read-back and staged restore; Swift owns archive validation,
// journals and the project/note/settings sinks.
android {
    namespace = "com.floe.android.feature.dataexchange"
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
