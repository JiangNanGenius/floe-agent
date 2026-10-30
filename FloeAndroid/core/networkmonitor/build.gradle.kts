plugins { alias(libs.plugins.android.library) }

// G07.2 bounded monitoring models/engine/reporting. Android Service, notification and
// application wiring live only in the App host package; this module retains no
// arbitrary JSONObject and has no transport beyond the injected frozen-service port.
android {
    namespace = "com.floe.android.core.networkmonitor"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    // Android supplies org.json in product; local JVM tests need its real implementation.
    testImplementation("org.json:json:20240303")
}
