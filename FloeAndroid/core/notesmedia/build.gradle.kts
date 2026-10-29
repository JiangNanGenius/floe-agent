// G06 Notes media module (PDF adapter + Android Ink + annotation/PDF/image export).
//
// This module is deliberately a plain `com.android.library`: the reusable
// media layer must be hostable from the existing App UI, the benchmark harness
// and the (upcoming) Notes feature without forcing a Compose runtime into the
// consumer. The AndroidX Ink authoring surface used here is the STABLE
// View-based `androidx.ink.authoring.InProgressStrokesView` (Ink 1.0.0), not
// the Compose authoring preview.
//
// Pinned upstream artifacts (verified against the official Google Maven
// metadata at dl.google.com/dl/android/maven2/androidx/ink/<artifact>/1.0.0/
// on 2026-10-29; every requested version exists and 1.0.0 is the newest
// NON-alpha release of the `androidx.ink` group):
//   ink-authoring, ink-brush, ink-geometry, ink-nativeloader,
//   ink-rendering, ink-storage, ink-strokes — all 1.0.0.
// Licenses are Apache-2.0 and retained verbatim under `licenses/ink/`
// (PROVENANCE.json records the metadata digests and resolved artifact list).
// Versions are spelled out here rather than added to the central version
// catalog because this module's registration is Main's integration step; a
// later catalog consolidation may replace these literals without changing
// the module API.
plugins { alias(libs.plugins.android.library) }

android {
    namespace = "com.floe.android.core.notesmedia"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // The module ships Kotlin source only; no resources, no BuildConfig.
    buildFeatures { buildConfig = false }
}

dependencies {
    // The PDF reader/print adapter REUSES the existing Office PDF authority
    // (OfficePdfVerifiedSource / OfficePdfSourceAccess / OfficePdfRenderHost /
    // OfficePdfPrintFlow) instead of opening a second renderer. `api` keeps
    // the shared verified-source contract visible to consumers that already
    // own an Office receipt-proved snapshot.
    api(project(":core:officeengine"))

    implementation(libs.androidx.core)
    implementation(libs.kotlinx.coroutines.core)

    // androidx.ink 1.0.0 (stable) — explicit pins, see header.
    implementation("androidx.ink:ink-authoring:1.0.0")
    implementation("androidx.ink:ink-brush:1.0.0")
    implementation("androidx.ink:ink-geometry:1.0.0")
    implementation("androidx.ink:ink-nativeloader:1.0.0")
    implementation("androidx.ink:ink-rendering:1.0.0")
    implementation("androidx.ink:ink-storage:1.0.0")
    implementation("androidx.ink:ink-strokes:1.0.0")

    testImplementation(libs.junit)
}

// Fixture files for the JVM tests are task-owned regenerable build output
// under the module build directory (safgateway/workspacebridge convention).
tasks.withType<Test>().configureEach {
    val fixtureRoot = layout.buildDirectory.dir("tmp/notesmedia-tests")
    doFirst { fixtureRoot.get().asFile.mkdirs() }
    systemProperty("java.io.tmpdir", fixtureRoot.get().asFile.absolutePath)
    // Opt-in real-world PDF smoke check (Main/combined stage):
    //   ./gradlew :core:notesmedia:testDebugUnitTest -Pnotesmedia.realPdfFile=/abs/path.pdf
    // The test is SKIPPED (JUnit assumption) when no path is supplied, so the
    // default suite stays hermetic.
    systemProperty(
        "notesmedia.realPdfFile",
        providers.gradleProperty("notesmedia.realPdfFile").getOrElse(""),
    )
}
