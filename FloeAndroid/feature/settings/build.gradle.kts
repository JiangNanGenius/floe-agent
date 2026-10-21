plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// G02 Settings model-role policy is shared with the App host. Effects,
// persistence, credentials and routing remain owned by existing services.
// Dependencies use only pinned version-catalog artifacts.
android {
    namespace = "com.floe.android.feature.settings"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    // Pure policy/presentation layer: no App dependency, no network client,
    // no database — every effect crosses the host callbacks.
    implementation(project(":core:designsystem"))
    testImplementation(libs.junit)
}
