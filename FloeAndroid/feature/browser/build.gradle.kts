plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// G04 controlled browser + token-bound local preview (source-only stage).
// The module owns the dumb android.webkit.WebView renderer/executor, the pure
// loopback ServerSocket transport and the Compose task panel projection ONLY.
// Session/tab/document/handoff/preview/download AUTHORITY is the Swift
// FloeBrowser service reached through these interfaces (Main JNI composition;
// pattern precedent: feature/ide IdeHost + core/swiftbridge floe_*_jni).
// No durable Kotlin browser state, no network business logic, no path
// authority, no route authority, no App dependency. Dependencies are pinned
// version-catalog artifacts only (no androidx.webkit: document-start script
// injection degrades to on-commit re-injection, which the probe protocol
// already tolerates honestly). settings.gradle.kts registration and the
// app binding are applied by Main from the snippets in
// Local/Private/android-g04-20261024/r1/browser-preview/SOURCE_READY.json.
android {
    namespace = "com.floe.android.feature.browser"
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
    implementation(project(":core:designsystem"))
    implementation(project(":core:contracts"))
    implementation(libs.androidx.activity.compose)
    // Pure JVM logic (transport loop, presenter fencing, download pump) runs
    // against these interfaces; the scheduler stays injectable for tests.
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
}
