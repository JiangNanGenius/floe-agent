import java.util.Properties

plugins { alias(libs.plugins.android.library) }

// --- Pinned development debug signing identity -------------------------------
// Same pin as :app (see app/build.gradle.kts for the rationale): the library's
// androidTest APK must share the app's debug identity, otherwise instrumentation
// installation against the app fails or drifts. When the property is absent
// (fresh public checkout) AGP's default debug behaviour is preserved unchanged.
fun floePinnedDebugKeystore(): File? {
    val raw = listOf(
        providers.gradleProperty("floe.debug.keystore").orNull,
        Properties().apply {
            val local = rootProject.file("local.properties")
            if (local.isFile) local.inputStream().use { load(it) }
        }.getProperty("floe.debug.keystore"),
    ).firstOrNull { !it.isNullOrBlank() } ?: return null
    // Validate the caller's path before Gradle resolves relative files.
    val keystore = File(raw)
    require(keystore.isAbsolute && keystore.isFile) {
        "floe.debug.keystore is configured but not usable (an existing absolute file " +
            "is required, refusing to fall back to a silently regenerated key): $raw"
    }
    return keystore
}
val floeDevKeystore = floePinnedDebugKeystore()

android {
    namespace = "com.floe.android.bridge"
    if (floeDevKeystore != null) {
        signingConfigs.getByName("debug").apply {
            storeFile = floeDevKeystore
            storePassword = "android" // AGP default debug keystore constant
            keyAlias = "androiddebugkey"
            keyPassword = "android" // AGP default debug keystore constant
        }
    }
    compileSdk = 37
    ndkVersion = "30.0.16248370"
    defaultConfig {
        minSdk = 28
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild { cmake { cppFlags += "-std=c++17" } }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    implementation(project(":core:contracts"))
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
