import java.util.Properties

plugins { alias(libs.plugins.android.application); alias(libs.plugins.kotlin.compose) }

// --- Pinned development debug signing identity -------------------------------
// AGP's implicit debug keystore resolves from $ANDROID_USER_HOME, else
// ~/.android, and silently generates a brand-new keypair wherever it first
// finds none. That key-drifted the G01 build batches (44c68bee… -> bf9ab29f…)
// and broke `adb install -r` upgrade continuity on installed packages.
// Pin one checkout-local development keystore so the app's debug variants and
// every androidTest APK keep a single stable identity regardless of environment
// flips. The path comes from the git-ignored local.properties or an explicit
// -Pfloe.debug.keystore build argument; the key file itself lives outside the
// public scope under Local/Private. The alias/password constants below are
// AGP's documented public default-debug values, not production credentials.
// When the property is absent (fresh public checkout) AGP's default debug
// behaviour is preserved unchanged. Release signing is a separate decision.
fun floePinnedDebugKeystore(): File? {
    val raw = listOf(
        providers.gradleProperty("floe.debug.keystore").orNull,
        Properties().apply {
            val local = rootProject.file("local.properties")
            if (local.isFile) local.inputStream().use { load(it) }
        }.getProperty("floe.debug.keystore"),
    ).firstOrNull { !it.isNullOrBlank() } ?: return null
    // Validate the RAW configured path before resolution: File(file(raw)) would
    // already be absolutized against the project directory and could never
    // reject a relative configuration, contradicting the documented contract.
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
    namespace = "com.floe.android"
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
        applicationId = "com.floe.agent"
        minSdk = 28
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0-g01"
        ndk { abiFilters += "arm64-v8a" }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    flavorDimensions += "distribution"
    productFlavors {
        create("full") { dimension = "distribution"; applicationIdSuffix = ".full" }
        create("play") { dimension = "distribution" }
    }
    buildTypes {
        debug { applicationIdSuffix = ".dev" }
        release { isMinifyEnabled = false }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    packaging { jniLibs { useLegacyPackaging = false } }
}
dependencies {
    implementation(project(":core:contracts"))
    implementation(project(":core:designsystem"))
    implementation(project(":core:swiftbridge"))
    implementation(libs.androidx.core)
    implementation(libs.androidx.activity.compose)
    "fullImplementation"(project(":feature:phonecontrol"))
    "fullImplementation"(project(":feature:rootsystem"))
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
