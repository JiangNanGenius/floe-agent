// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }

// G04-R1 embedded terminal feature module (job-dda32d23d55e4460).
//
// Contents:
//  * `com.termux.terminal` — the SELECTED, byte-identical subset of the
//    pinned Termux terminal-emulator parser/buffer (upstream
//    termux/termux-app v0.118.3, commit
//    5b657c6adf4304e5198951ce815fe0205dcac29c; Apache License 2.0 per the
//    repository LICENSE.md exception for terminal-emulator, derived from
//    jackpal/Android-Terminal-Emulator Apache 2.0). Exact per-file SHA-256
//    values, the vendoring manifest and the single documented
//    TerminalSessionClient patch live in `src/main/java/com/termux/terminal/`
//    + `licenses/` + PROVENANCE-TERMUX.md below and are mirrored to
//    Local/Private/android-g04-20261024/r1/terminal-lsp/.
//  * `com.floe.android.feature.terminal` — a narrow Compose renderer +
//    input/selection layer that drives the reused emulator over an
//    EXTERNAL byte pipe supplied by the App host controller. NO process,
//    session, service or runtime ownership lives here: TerminalSession,
//    JNI.java and termux.c are deliberately NOT vendored (they are the
//    competing Termux process lifecycle that D3 forbids). The ORIGINAL
//    Linux engine + ShellSessionCenter + native session authority stay in
//    Swift Core (G04TerminalDomain) behind the trusted JNI host API.
//
// settings.gradle.kts registration and the license/NOTICE inventory are
// applied by Main (see the mounting delta in the private r1/terminal-lsp
// folder). No App, provider or bridge-module dependency: the pane receives
// its transport as plain Kotlin callbacks.
android {
    namespace = "com.floe.android.feature.terminal"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions {
        // The vendored terminal-emulator references a handful of android
        // statics (Log/Base64/Color helpers) that never run on the tested
        // paths; JVM unit tests must not crash on class defaults.
        unitTests.isReturnDefaultValues = true
    }
}
dependencies {
    // Floe design-system wrappers (compose substrate arrives as api).
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.activity.compose)
    // Pure-JVM test support for the input/selection/parse unit tests.
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
}
