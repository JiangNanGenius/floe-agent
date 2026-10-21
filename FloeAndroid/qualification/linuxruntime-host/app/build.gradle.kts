plugins { alias(libs.plugins.android.application) }

android {
    namespace = "com.floe.linuxruntime.qualhost"
    compileSdk = 37
    ndkVersion = "30.0.16248370"
    defaultConfig {
        applicationId = "com.floe.linuxruntime.qualhost"
        minSdk = 28
        targetSdk = 37
        versionCode = 1
        versionName = "0.1-r1"
        ndk { abiFilters += "arm64-v8a" }
    }
    buildTypes {
        // Non-debuggable (android:debuggable=false) but installable with the
        // development debug identity, so Main can `adb install` it and
        // still prove behavior in a normal App UID rather than under
        // run-as/adb shell. The process domain is untrusted_app regardless of
        // the signing key; release vs debug changes no SELinux facts here.
        release { signingConfig = signingConfigs.getByName("debug") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // useLegacyPackaging=true => platform extracts the shipped executable
    // payloads (libfloeprobe.so, libproot.so) to real files under the app
    // native library directory, the packaged location used by this targetSdk>=29 app to
    // execve() from besides the runtime itself (AGP 9 maps this to
    // android:extractNativeLibs="true" at manifest merge).
    packaging { jniLibs { useLegacyPackaging = true } }
}

dependencies {
    implementation(project(":linuxruntime"))
}
