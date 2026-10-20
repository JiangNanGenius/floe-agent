import java.util.Properties

plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// --- Pinned development debug signing identity -------------------------------
// Same pin as :app, :core:swiftbridge, :core:credentials and
// :feature:providers. The self-hosted androidTest fixture APK is a
// separately installed package; it must carry the checkout's one established
// development identity (SHA-256 44c68bee…a3789) so Main can install/read it
// without key drift. No credential values live in this file; when the
// property is absent (fresh public checkout) AGP's default debug behaviour is
// preserved unchanged.
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

// Skills/MCP administration presentation module (G02 work package P2.6).
// Registered by the qualification stage (include(":feature:integrations"));
// no App target depends on it yet. Only pinned version-catalog artifacts are
// used; the module lock is regenerated with --write-locks, never by hand.
android {
    namespace = "com.floe.android.feature.integrations"
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
        // Self-hosted synthetic fixture; no production App or backend entry.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    // The presentation flow consumes ONLY the Floe design-system wrappers
    // (which expose the frozen compose-cupertino substrate as api). No
    // network client, database, package executor or permission authority
    // lives in this module: every effect crosses IntegrationUiCallbacks.
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.junit)
    // Isolated synthetic render fixture (androidTest only; never release).
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
    // Pin Espresso 3.7.0 explicitly: Compose ui-test-junit4's transitive
    // 3.5.0 reflects InputManager.getInstance(), which does not exist on API 37
    // and fails every Compose test at Espresso.onIdle before any assertion.
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
