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

dependencies {
    // Pinned decompression for the transactional rootfs installer (install/):
    // XZ for Java 1.12, org.tukaani:xz, license 0BSD (SPDX header + license
    // element in the upstream POM; text retained at licenses/xz-0BSD-LICENSE).
    // Verified from the primary source on 2026-10-22 against
    // https://repo1.maven.org/maven2/org/tukaani/xz/1.12/ published .sha256:
    //   jar 3e158a87bd73d8afb4b6e8239c013b7d049c48563f45860ce99cd2e448cf4a6b
    //   pom 937b44d869c059c39f07ae194d8cd6219f5aebf2200ef9707f0b50b7837da281
    // Project maintained by Lasse Collin / tukaani-project (latest release
    // 1.12, maven-metadata lastUpdated 2026-03-01). Pure JVM, zero transitive
    // dependencies; Gradle checksums are pinned in
    // FloeAndroid/gradle/verification-metadata.xml (additive org.tukaani
    // component). NOTE for App wiring (Main): the jar is multi-release
    // (META-INF/versions/9); verify D8 handling once during integration.
    implementation("org.tukaani:xz:1.12")
    testImplementation(libs.junit)
}
