// Optional signed split. The base APK keeps the small Office UI/ownership API;
// this module alone carries the existing verified native engine and assets.
plugins { alias(libs.plugins.android.dynamic.feature) }

android {
    namespace = "com.floe.android.officepreview"
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
    val producer = project(":core:officeengine")
    sourceSets.getByName("main") {
        assets.srcDir(producer.layout.buildDirectory.dir("office-engine/assets"))
        jniLibs.srcDir(producer.layout.buildDirectory.dir("office-engine/jniLibs"))
    }
    packaging {
        jniLibs.keepDebugSymbols += "**/*.so"
    }
}

dependencies { implementation(project(":app")) }

tasks.configureEach {
    if ((name.startsWith("merge") && name.contains("Assets")) || name.contains("lint", true)) {
        dependsOn(":core:officeengine:prepareOfficeEngineAssets")
    }
    if ((name.startsWith("merge") && name.contains("JniLib")) ||
        (name.startsWith("copy") && name.contains("JniLib")) || name.contains("lint", true)) {
        dependsOn(":core:officeengine:stageOfficeEngineJniLibs")
    }
}

// Match the base channel's actual extraction/mapping contract.
androidComponents.onVariants { variant ->
    variant.packaging.jniLibs.useLegacyPackaging.set(
        variant.productFlavors.any { it.first == "distribution" && it.second == "full" })
}
