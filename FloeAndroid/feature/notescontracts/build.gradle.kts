plugins { alias(libs.plugins.android.library) }

// G06 Notes C0/C1 consumer contract (source-only module).
//
// This module is deliberately dependency-free product code: typed models, the
// NotesService interface, edit vocabulary, protocol bounds and cancellation
// semantics. The App host adapter (com.floe.android.host.notes) owns the JSON
// wire and calls the existing SwiftCore/JNI exchange. Central settings.gradle
// registration, app dependency and the lockfile are Main's integration step.
android {
    namespace = "com.floe.android.feature.notes"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    testImplementation(libs.junit)
}
