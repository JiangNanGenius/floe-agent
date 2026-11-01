plugins { alias(libs.plugins.android.library) }

// G09-R1 Canvas consumer contract (source-only module).
//
// Typed Canvas project/patch/revision/asset contracts and the CanvasHostApi
// consumed by the later Compose feature. No Compose, no storage and no JSON
// wire implementation live here; the App host owns the exact wire codec.
android {
    namespace = "com.floe.android.feature.canvas"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    // Opaque preserved subtrees (scene3D/design authority) only; the typed
    // DTOs themselves are plain Kotlin data classes.
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation(libs.junit)
}
