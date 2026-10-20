import java.util.Properties

plugins { alias(libs.plugins.android.library) }

// --- Pinned development debug signing identity -------------------------------
// Same pin as :app and :core:swiftbridge. A library's androidTest APK is a
// separately installed package; keeping it on the checkout's one development
// identity avoids a key drift that would force uninstall/reinstall between
// batches. When the property is absent (fresh public checkout) AGP's default
// debug behaviour is preserved unchanged.
fun floePinnedDebugKeystore(): File? {
    val raw = listOf(
        providers.gradleProperty("floe.debug.keystore").orNull,
        Properties().apply {
            val local = rootProject.file("local.properties")
            if (local.isFile) local.inputStream().use { load(it) }
        }.getProperty("floe.debug.keystore"),
    ).firstOrNull { !it.isNullOrBlank() } ?: return null
    // Validate the raw configured value before Gradle resolves relative files.
    require(File(raw).isAbsolute) {
        "floe.debug.keystore must be an absolute path (relative values are rejected " +
            "instead of silently resolved against the project directory): $raw"
    }
    val keystore = file(raw)
    require(keystore.isAbsolute && keystore.isFile) {
        "floe.debug.keystore is configured but not usable (an existing absolute file " +
            "is required, refusing to fall back to a silently regenerated key): $raw"
    }
    return keystore
}
val floeDevKeystore = floePinnedDebugKeystore()

android {
    namespace = "com.floe.android.credentials"
    if (floeDevKeystore != null) {
        signingConfigs.getByName("debug").apply {
            storeFile = floeDevKeystore
            storePassword = "android" // AGP default debug keystore constant
            keyAlias = "androiddebugkey"
            keyPassword = "android" // AGP default debug keystore constant
        }
    }
    compileSdk = 37
    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    // The adapter's public surface implements CredentialStore, so contracts is
    // an API dependency rather than an implementation detail.
    api(project(":core:contracts"))
    // Debug-only sealed QA enrollment uses the coroutines Mutex so a
    // continuation that resumes on the store's I/O thread cannot break
    // per-session serialization. This is the already-resolved repository
    // version (Compose/app lockfiles resolve 1.9.0), not an upgrade.
    debugImplementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
