plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// G04 Sora native IDE renderer + Floe workspace presentation (source-only
// stage). The module owns renderer/tab/tree chrome and transaction GATING
// only: document/file/revision/undo/draft truth stays in the Swift
// FloeWorkspace service reached through the host IdeHost adapter (Main/B3).
// No durable Kotlin document state, no executor, no route authority, no App
// dependency. Dependencies use only pinned version-catalog artifacts plus the
// pinned official Sora editor coordinate io.github.rosemoe:editor:0.24.4
// (LGPL-2.1; POM closure: androidx.annotation 1.9.1 / androidx.collection
// 1.5.0 / kotlin-stdlib 2.2.21). settings.gradle.kts registration, the catalog
// entries and the license/NOTICE inventory are applied by Main from the
// snippets in Local/Private/android-g04-20261024/r1/ide-renderer/SOURCE_READY.json.
android {
    namespace = "com.floe.android.feature.ide"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    // Floe design-system wrappers (Cupertino substrate arrives as api) and the
    // frozen bridge vocabulary from core:contracts. No provider/conversation
    // feature dependency: IDE flows must stay task-agnostic.
    implementation(project(":core:designsystem"))
    implementation(project(":core:contracts"))
    implementation(libs.androidx.activity.compose)
    // Pure JVM state types used by the presenter/tests (no Android runtime
    // dispatch requirements — the presenter is scheduler-free).
    implementation(libs.kotlinx.coroutines.core)
    // Pinned official Sora native editor (new group). Transitive closure and
    // exact artifact hashes verified 2026-10-24; see SOURCE_READY.json.
    implementation(libs.sora.editor)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
}
