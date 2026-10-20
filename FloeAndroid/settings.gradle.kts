pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "FloeAndroid"
include(":app", ":core:contracts", ":core:credentials", ":core:designsystem", ":core:swiftbridge")
include(":feature:phonecontrol", ":feature:rootsystem")
// G02 provider/model presentation flow (source-only stage; no App dependency
// yet). Registered last, after its build file exists; the next Gradle stage
// regenerates this module's lockfile with --write-locks.
include(":feature:providers")
// G02 conversation/history/task/approval/attachment/temporary presentation
// flow (source-only stage; no App route wired yet). Registered last in the
// same convention; the next Gradle stage regenerates this module's lock.
include(":feature:conversation")
// G02 Skills/MCP administration presentation flow (source delivered; the
// qualification stage registers it, generates its lock and runs its tests.
// No App dependency or route added).
include(":feature:integrations")

