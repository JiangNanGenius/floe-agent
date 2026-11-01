plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// G09-R1 Canvas library + editor presentation (source-only stage).
//
// Authority split:
// * `:feature:canvascontracts` is the ONLY Canvas project/asset API. This
//   module never opens a file, never defines a second CanvasProject model and
//   never keeps a project library in memory as durable state.
// * The retained `CanvasWorkspaceSession`/`CanvasEditorController` own only
//   the editor session token, the loaded projector envelope, local selection
//   and the UI undo stack. Every mutation is a `CanvasHostApi` patch with the
//   exact expected revision and a durable operation id.
// * SAF picking and atomic new-project creation arrive through the explicit
//   `CanvasEditorPorts` interfaces in `ui/api/CanvasEditorPorts.kt`. There is
//   no default implementation and no fake success.
// * Preview bytes are read only from `CanvasProjectEnvelope.assetsBasePath`
//   (the trusted Materials directory) with a bounded sampled bitmap decoder.
//
// Central settings.gradle.kts registration and the App dependency are owned by
// the integration stage, which applies them together with the module lockfile.
android {
    namespace = "com.floe.android.feature.canvas.ui"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    implementation(project(":feature:canvascontracts"))
    // Existing Floe iOS-style substrate (FloeColors/FloeType/FloeIcons, form
    // controls, sheets). Never a second design system or Material icon set.
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.activity.compose)
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
}
