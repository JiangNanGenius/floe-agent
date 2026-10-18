plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

val outputRoot = providers.environmentVariable("FLOE_ANDROID_BUILD_ROOT")
subprojects {
    outputRoot.orNull?.let { root ->
        layout.buildDirectory.set(file(root).resolve(project.path.removePrefix(":").replace(':', '/')))
    }
    dependencyLocking { lockAllConfigurations() }
}
