plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// G06 Notes library/editor/mind-map presentation (source-only stage).
//
// Authority split:
// * `:feature:notescontracts` is the ONLY document/authority API. This module
//   never opens a database, never defines a second NoteDocument model and
//   never persists a fake in-memory library.
// * Media (PDF/Ink/export/print), Office, assistant, OCR/indexing and system
//   share/SAF effects arrive through the explicit required interfaces in
//   `api/NotesHostPorts.kt`. `core:notesmedia` is deliberately NOT a compile
//   dependency of this module: the App host adapter is the single consumer of
//   that module (its stable `NotesMedia` factory), so integration can land
//   without forcing the office-engine payload into this module's classpath.
//   The concrete consumer contract lives in this module's public API files
//   (`api/NotesHostPorts.kt`) and its module documentation.
//
// No central settings.gradle.kts/app dependency, manifest or host edit belongs
// to this file; Main applies the integration patch from HANDOFF.json.
android {
    namespace = "com.floe.android.feature.notes.ui"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    // Contract models, NotesService, NotesEdit/request values and protocol
    // bounds. Read-only: this module must not redeclare them.
    implementation(project(":feature:notescontracts"))
    // Existing Floe iOS-style substrate (FloeColors/FloeType/FloeIcons, form
    // controls, sheets, Cupertino). Never a second design system.
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.activity.compose)
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
}
