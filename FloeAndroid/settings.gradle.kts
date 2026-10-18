pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "FloeAndroid"
include(":app", ":core:contracts", ":core:designsystem", ":core:swiftbridge")
include(":feature:phonecontrol", ":feature:rootsystem")
