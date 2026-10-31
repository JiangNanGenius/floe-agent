// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library) }

// G07.3B offline capture analysis. Deliberately Android-library shaped like
// core/networkmonitor, but the parser/aggregation/reporting code uses only
// java.io/java.security/org.json and no Android API. The App supplies the
// actual SAF stream and owns the temporary raw copy.
android {
    namespace = "com.floe.android.core.pcap"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    testImplementation(libs.junit)
    // Android supplies org.json in product; local JVM tests need its real implementation.
    testImplementation("org.json:json:20240303")
}
