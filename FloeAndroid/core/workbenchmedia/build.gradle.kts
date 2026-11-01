plugins { alias(libs.plugins.android.library) }

// G09-R2 Android media platform (Media3 playback/composition/export + image
// renderer + bounded render-ticket service).
//
// Authority split:
//  * :feature:workbenchcontracts (frozen G09-R2) owns every public port and
//    DTO used here; this module implements them and adds no parallel media
//    project/file/job store of its own.
//  * NativeFoundation (shared Core/C ABI/JNI/App facade) owns the accepted
//    epoch/root, the immutable render snapshot lease, large imports and the
//    real bounded MediaRenderTicketTransport. This module only consumes those
//    injected ports; it never invents a root, lease, ticket or transport.
//
// Dependency pins are exact (no dynamic versions): androidx.media3 1.11.1 is
// the release verified by discovery07/LIMITS.md (Google Maven metadata
// lastUpdated 2026-10-26; GitHub tag 1.11.1). Aliases are proposed in the
// private integration patch and must exist before Main's integrated compile.
// No Compose, no Flow in the public contract surface, no FFmpeg/local model.
android {
    namespace = "com.floe.android.core.workbenchmedia"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { buildConfig = false }
}

dependencies {
    api(project(":feature:workbenchcontracts"))
    implementation(libs.kotlinx.coroutines.core)

    // Exact Media3 1.11.1 platform engine. Transformer pulls the pinned
    // muxer/datasource/container artifacts transitively; exoplayer plays the
    // very same Composition through CompositionPlayer.
    implementation(libs.media3.common)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.transformer)
    implementation(libs.media3.effect)
    // C03 real HEIC still-image encoder (AndroidX HeifWriter 1.1.0). This is a
    // codec-backed HEIF writer, never Bitmap.compress with a .heic extension.
    implementation(libs.androidx.heifwriter)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
}

// Pure-JVM test fixtures are task-owned regenerable build output under the
// module build directory (safgateway/notesmedia convention).
tasks.withType<Test>().configureEach {
    val fixtureRoot = layout.buildDirectory.dir("tmp/workbenchmedia-tests")
    doFirst { fixtureRoot.get().asFile.mkdirs() }
    systemProperty("java.io.tmpdir", fixtureRoot.get().asFile.absolutePath)
}
