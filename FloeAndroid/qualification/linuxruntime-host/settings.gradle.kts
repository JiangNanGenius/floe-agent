pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "floe-linuxruntime-qualification"
include(":app", ":linuxruntime")
project(":linuxruntime").projectDir = file("../../core/linuxruntime")
