plugins { alias(libs.plugins.android.library) }

android {
    namespace = "com.floe.android.workspacebridge"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    implementation(project(":core:runtimeipc"))
    testImplementation(libs.junit)
    // Host JVM tests need an executable JSON reference; Android's local
    // test jar intentionally replaces framework methods with throwing stubs.
    // This does not enter the product, which uses framework org.json.
    testImplementation("org.json:json:20240303")
}

// Fixture files are regenerable, task-owned build output rather than a
// shared system-temp namespace. No change to product storage paths.
tasks.withType<Test>().configureEach {
    val fixtureRoot = layout.buildDirectory.dir("tmp/workspace-tests")
    doFirst { fixtureRoot.get().asFile.mkdirs() }
    systemProperty("java.io.tmpdir", fixtureRoot.get().asFile.absolutePath)
}
