plugins { alias(libs.plugins.android.library) }

android {
    namespace = "com.floe.android.linuxruntime"
    compileSdk = 37
    ndkVersion = "30.0.16248370"
    defaultConfig {
        minSdk = 28
        ndk { abiFilters += "arm64-v8a" }
    }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
