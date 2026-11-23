// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library) }

android {
    namespace = "com.floe.android.core.devicelink"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("computer.iroh:iroh-android:1.2.0") {
        exclude(group = "net.java.dev.jna", module = "jna")
    }
    // The upstream AAR uses JNA 5.15.0. Use the Android AAR with the 16 KiB fixes.
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    implementation(libs.kotlinx.coroutines.core)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
