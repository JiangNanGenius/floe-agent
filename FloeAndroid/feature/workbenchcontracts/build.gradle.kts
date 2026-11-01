plugins { alias(libs.plugins.android.library) }

// G09-R1 media workbench consumer contract (source-only module).
//
// Typed media project/edit-command contracts and WorkbenchHostApi. It reuses
// the shared creative ownership/binding types from :feature:canvascontracts;
// editor state, Compose UI and storage stay outside this module.
android {
    namespace = "com.floe.android.feature.workbench"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    api(project(":feature:canvascontracts"))
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation(libs.junit)
}
