// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library) }
android {
    namespace = "com.floe.android.core.fonts"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies { testImplementation(libs.junit) }
