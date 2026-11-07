// Optional signed split. The base APK keeps the small CAD host/renderer API
// and the hash-pinned manifest; this module alone carries the immutable
// hash-pinned CAD viewer payload that used to sit (unpacked) in the base
// source tree. Mirrors :officepreview: one identity for both channels.
plugins { alias(libs.plugins.android.dynamic.feature) }

android {
    namespace = "com.floe.android.cadpreview"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
        ndk { abiFilters += "arm64-v8a" }
    }
    flavorDimensions += "distribution"
    productFlavors {
        create("full") { dimension = "distribution" }
        create("play") { dimension = "distribution" }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets.getByName("main") {
        assets.srcDir("src/main/assets")
    }
}

dependencies { implementation(project(":app")) }
