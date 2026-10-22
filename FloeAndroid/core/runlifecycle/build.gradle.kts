plugins { alias(libs.plugins.android.library) }

// Core-side Agent foreground lifecycle (G03). TRANSIENT service ownership
// only: this module registers REAL in-flight work in memory, promotes it
// through ONE specialUse foreground service, and answers opaque per-operation
// Binder permits for the distinct-UID runtime component. It is NOT a second
// run/job/environment database and never admits work from Intent extras,
// model JSON or IPC payloads. Registration is module wiring owned by Main:
// the settings include and lock regeneration happen in the serialized
// Gradle cohort; this package does not compile the moving shared tree.
android {
    namespace = "com.floe.android.runlifecycle"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    // Reuses the Main-authored permit protocol, package channels and the
    // exact UID/signature peer verifier. No runtimeapp dependency is added
    // in either direction.
    implementation(project(":core:runtimeipc"))
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
}
