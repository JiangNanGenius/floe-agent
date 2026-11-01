plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// G09-R1 media project library + image/video workbench presentation
// (source-only stage).
//
// Authority split:
// * `:feature:workbenchcontracts` is the ONLY media project/edit-command API
//   and `:feature:canvascontracts` supplies the shared creative identity
//   (storage layer, origin, session tokens). This module never opens a file
//   directly as project authority and never defines a second media store.
// * The retained `MediaWorkspaceSession`/`MediaEditorController` own the exact
//   editor token, the loaded envelope, selection and preview bitmaps only.
//   Every mutation is a native `media.project.apply` (or undo/redo) with the
//   exact expected revision and a durable op id, followed by a native reload.
// * SAF picking and atomic source creation arrive through the explicit
//   `MediaEditorPorts` interfaces in `ui/api/MediaEditorPorts.kt`.
// * Asset previews are read only from the trusted `mediaRootPath` carried by
//   `MediaProjectEnvelope`, with a bounded sampled bitmap decoder. A recorded
//   `taskWorkspacePath` is never used as a root.
android {
    namespace = "com.floe.android.feature.workbench.ui"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    implementation(project(":feature:workbenchcontracts"))
    // Shared creative identity vocabulary (CreativeStorageLayer, origin,
    // session tokens, path guard). No Canvas UI dependency.
    implementation(project(":feature:canvascontracts"))
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.activity.compose)
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
}
