// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library) }

// C06 Android system services: real one-shot location (LocationManager),
// read-only ContactsContract, foreground NDEF reader mode and read-only
// Health Connect. This module owns the platform clients, pure validation and
// the bounded contact snapshot store. It never owns UI, permission dialogs,
// the Swift bridge, model tools or a database schema.
//
// androidx.health.connect:connect-client is pinned to the exact stable 1.1.0
// release (Apache-2.0). Its AAR needs compileSdk 36+, which this project
// already uses (37). License/provenance: FloeAndroid/licenses/systemservices.
android {
    namespace = "com.floe.android.core.systemservices"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)
    // Exact stable Health Connect client; no preview or dynamic version.
    implementation("androidx.health.connect:connect-client:1.1.0")
    testImplementation(libs.junit)
    // Android's local-test android.jar stubs org.json; use a real JVM copy for
    // deterministic policy/serialization tests. No product code depends on it.
    testImplementation("org.json:json:20240303")
}
