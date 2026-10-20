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
    // The qualification JNI wrapper (floe_qualification_jni) is debug-variant
    // ONLY: this flag gates the CMake add_library, so release AAR native
    // entries never build or package it. Production floe_jni and every frozen
    // boundary (hashes, 16 KiB, 64 KiB, v1 shape) are unchanged for all
    // variants. Evidence: native-jni-qualification release-boundary report.
    buildTypes {
        getByName("debug") {
            externalNativeBuild { cmake { arguments += "-DFLOE_BUILD_QUALIFICATION_JNI=ON" } }
        }
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    implementation(project(":core:contracts"))
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
    // Self-target RB1 lifecycle test decodes the v3 wire with the SAME
    // pinned structured JSON library as the product coordinator (1.9.0);
    // test-only, never part of the library's release AAR.
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
}
