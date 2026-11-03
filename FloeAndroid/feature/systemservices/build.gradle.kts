// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// C06 system-services presentation. Presentation only: the App-owned
// `app/host/systemservices` controller owns Android permissions, the platform
// lane, foreground/NFC lifecycle and the Swift bridge.
android {
    namespace = "com.floe.android.feature.systemservices"
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
    testImplementation(libs.junit)
}
