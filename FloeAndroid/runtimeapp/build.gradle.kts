import java.util.Properties

plugins { alias(libs.plugins.android.application) }

val configuredKey = providers.gradleProperty("floe.debug.keystore").orNull
    ?: Properties().apply {
        rootProject.file("local.properties").takeIf { it.isFile }?.inputStream()?.use { load(it) }
    }.getProperty("floe.debug.keystore")

android {
    namespace = "com.floe.android.runtime"
    compileSdk = 37
    ndkVersion = "30.0.16248370"
    defaultConfig {
        applicationId = "com.floe.agent.runtime"
        minSdk = 28
        targetSdk = 37
        versionCode = 7
        versionName = "0.1.0-alpha.7"
        ndk { abiFilters += "arm64-v8a" }
        manifestPlaceholders["floeCorePackage"] = "com.floe.agent"
    }
    flavorDimensions += "distribution"
    productFlavors {
        create("full") {
            dimension = "distribution"
            applicationIdSuffix = ".full"
            manifestPlaceholders["floeCorePackage"] = "com.floe.agent.full"
        }
        create("play") {
            dimension = "distribution"
            manifestPlaceholders["floeCorePackage"] = "com.floe.agent"
        }
    }
    if (!configuredKey.isNullOrBlank()) {
        val key = File(configuredKey)
        require(key.isAbsolute && key.isFile) { "Configured debug signing key is unavailable" }
        signingConfigs.getByName("debug") {
            storeFile = key
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            // Match the ordinary non-debuggable process boundary qualified in
            // R1 even when the component uses the pinned development identity.
            isDebuggable = false
            // The service permission is declared by the exact core build.
            // Values below are set per variant because flavor+build suffixes compose.
        }
        release { isMinifyEnabled = false }
    }
    buildFeatures { buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Executable payloads are package-manager extracted into nativeLibraryDir.
    packaging {
        jniLibs.useLegacyPackaging = true
        jniLibs.excludes += "**/libfloeprobe.so" // R1 qualification executable is test-only.
        jniLibs.excludes += "**/libfloe_qualification_jni.so"
    }
}

androidComponents.onVariants { variant ->
    val full = variant.productFlavors.any { it.second == "full" }
    variant.manifestPlaceholders.put("floeCorePackage",
        "com.floe.agent" + (if (full) ".full" else "") + (if (variant.buildType == "debug") ".dev" else ""))
}

dependencies {
    implementation(project(":core:runtimeipc"))
    implementation(project(":core:workspacebridge"))
    implementation(project(":core:linuxruntime"))
    // Only the original environment authority and its dependencies. Main App
    // provider/security/history modules and files do not enter this component.
    implementation(project(":core:linuxauthoritybridge"))
}
