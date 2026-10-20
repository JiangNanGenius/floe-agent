import java.util.Properties

plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// --- Pinned development debug signing identity -------------------------------
// Same pin as :app, :core:swiftbridge, :core:credentials and :feature:providers
// (SHA-256 44c68bee…a3789 certificate). The self-hosted synthetic androidTest
// APK is a separately installed package and must carry the checkout's ONE
// established development identity; no credential values live in this file.
// When the property is absent (fresh public checkout) AGP's default debug
// behaviour is preserved unchanged.
fun floePinnedDebugKeystore(): File? {
    val raw = listOf(
        providers.gradleProperty("floe.debug.keystore").orNull,
        Properties().apply {
            val local = rootProject.file("local.properties")
            if (local.isFile) local.inputStream().use { load(it) }
        }.getProperty("floe.debug.keystore"),
    ).firstOrNull { !it.isNullOrBlank() } ?: return null
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
    namespace = "com.floe.android.feature.conversation"
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
        // Self-hosted synthetic component fixture (androidTest only; no
        // production App, no backend, no network, no credential host).
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    // The conversation presentation flow consumes ONLY the Floe design-system
    // wrappers (which expose the frozen compose-cupertino substrate as api),
    // plus the frozen immutable bridge envelope types from core:contracts for
    // host identity vocabulary. No provider-feature dependency: conversation
    // flows must not depend on the provider feature (lane rule); model/provider
    // facts arrive as host projections only.
    implementation(project(":core:designsystem"))
    implementation(project(":core:contracts"))
    implementation(libs.androidx.activity.compose)
    // REAL Markdown parse adapter (Main-accepted Option A): pure-JVM
    // commonmark-java 0.30.1 behind the typed requestMarkdownParse /
    // applyMarkdownParseResult contract. BSD-2-Clause license retained under
    // FloeAndroid/licenses/commonmark/ and NOTICE.md; runs off the UI thread
    // on bounded dedicated workers; no HTML/JS execution, no network, no
    // Android runtime dependency in these artifacts.
    implementation(libs.commonmark)
    implementation(libs.commonmark.ext.gfm.tables)
    implementation(libs.commonmark.ext.gfm.strikethrough)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
    // Isolated synthetic render fixture (androidTest only; never release).
    // Espresso is the corrected 3.7.0 pin (shared catalog): 3.5.0's reflective
    // InputManager.getInstance() fails on API 37 before any assertion.
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
