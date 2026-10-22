import java.util.Properties
import java.security.MessageDigest

plugins { alias(libs.plugins.android.application); alias(libs.plugins.kotlin.compose) }

abstract class BundleLinuxRuntimeComponent : DefaultTask() {
    @get:InputDirectory
    abstract val apkDirectory: DirectoryProperty
    @get:OutputDirectory
    abstract val assetDirectory: DirectoryProperty

    @TaskAction fun bundle() {
        val apk = apkDirectory.get().asFile.listFiles { file -> file.extension == "apk" }
            ?.singleOrNull() ?: error("Expected one matching runtime APK")
        val output = assetDirectory.get().asFile.resolve("linux-runtime")
        output.mkdirs()
        val digest = MessageDigest.getInstance("SHA-256")
        apk.inputStream().use { input ->
            output.resolve("runtime.apk").outputStream().use { stream ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count); stream.write(buffer, 0, count)
                }
            }
        }
        output.resolve("runtime.apk.sha256").writeText(digest.digest().joinToString("") { "%02x".format(it) } + "\n")
    }
}

// --- Pinned development debug signing identity -------------------------------
// AGP's implicit debug keystore resolves from $ANDROID_USER_HOME, else
// ~/.android, and silently generates a brand-new keypair wherever it first
// finds none. That key-drifted the G01 build batches (44c68bee… -> bf9ab29f…)
// and broke `adb install -r` upgrade continuity on installed packages.
// Pin one checkout-local development keystore so the app's debug variants and
// every androidTest APK keep a single stable identity regardless of environment
// flips. The path comes from the git-ignored local.properties or an explicit
// -Pfloe.debug.keystore build argument; the key file itself lives outside the
// public scope under Local/Private. The alias/password constants below are
// AGP's documented public default-debug values, not production credentials.
// When the property is absent (fresh public checkout) AGP's default debug
// behaviour is preserved unchanged. Release signing is a separate decision.
fun floePinnedDebugKeystore(): File? {
    val raw = listOf(
        providers.gradleProperty("floe.debug.keystore").orNull,
        Properties().apply {
            val local = rootProject.file("local.properties")
            if (local.isFile) local.inputStream().use { load(it) }
        }.getProperty("floe.debug.keystore"),
    ).firstOrNull { !it.isNullOrBlank() } ?: return null
    // Validate the RAW configured path before resolution: File(file(raw)) would
    // already be absolutized against the project directory and could never
    // reject a relative configuration, contradicting the documented contract.
    require(File(raw).isAbsolute) {
        "floe.debug.keystore must be an absolute path (relative values are rejected " +
            "instead of silently resolved against the project directory): $raw"
    }
    val keystore = file(raw)
    require(keystore.isAbsolute && keystore.isFile) {
        "floe.debug.keystore is configured but not usable (an existing absolute file " +
            "is required, refusing to fall back to a silently regenerated key): $raw"
    }
    return keystore
}
val floeDevKeystore = floePinnedDebugKeystore()

android {
    namespace = "com.floe.android"
    if (floeDevKeystore != null) {
        signingConfigs.getByName("debug").apply {
            storeFile = floeDevKeystore
            storePassword = "android" // AGP default debug keystore constant
            keyAlias = "androiddebugkey"
            keyPassword = "android" // AGP default debug keystore constant
        }
    }
    compileSdk = 37
    ndkVersion = "30.0.16248370"
    defaultConfig {
        applicationId = "com.floe.agent"
        minSdk = 28
        targetSdk = 37
        versionCode = 7
        versionName = "0.1.0-alpha.7"
        ndk { abiFilters += "arm64-v8a" }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    flavorDimensions += "distribution"
    productFlavors {
        create("full") { dimension = "distribution"; applicationIdSuffix = ".full" }
        create("play") { dimension = "distribution" }
    }
    buildTypes {
        debug { applicationIdSuffix = ".dev" }
        release { isMinifyEnabled = false }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    packaging { jniLibs { useLegacyPackaging = false } }
}

// GitHub has one public APK asset. The separate-UID execution component is
// inside that APK and installed only after the user's explicit OS consent.
// Play consumes its component through the Store and never embeds an installer.
androidComponents.onVariants { variant ->
    if (variant.productFlavors.any { it.second == "full" }) {
        val type = requireNotNull(variant.buildType)
        val capitalType = type.replaceFirstChar { it.uppercase() }
        val name = variant.name.replaceFirstChar { it.uppercase() }
        val bundle = tasks.register<BundleLinuxRuntimeComponent>("bundle${name}LinuxRuntime") {
            dependsOn(":runtimeapp:assembleFull$capitalType")
            apkDirectory.set(project(":runtimeapp").layout.buildDirectory.dir("outputs/apk/full/$type"))
            assetDirectory.set(layout.buildDirectory.dir("generated/runtimeComponent/${variant.name}"))
        }
        variant.sources.assets?.addGeneratedSourceDirectory(bundle, BundleLinuxRuntimeComponent::assetDirectory)
    }
}

dependencies {
    implementation(project(":core:contracts"))
    implementation(project(":core:credentials"))
    implementation(project(":core:designsystem"))
    implementation(project(":core:swiftbridge"))
    implementation(project(":core:runtimeipc"))
    implementation(project(":core:workspacebridge"))
    implementation(project(":core:runlifecycle"))
    // G02 App host binding: the real provider/conversation/integrations
    // components the Application-owned host binds to the shared runtime.
    implementation(project(":feature:conversation"))
    implementation(project(":feature:integrations"))
    implementation(project(":feature:providers"))
    implementation(project(":feature:settings"))
    implementation(libs.androidx.core)
    implementation(libs.androidx.activity.compose)
    // Explicit pin: the dispatcher relies on CoroutineStart.UNDISPATCHED
    // semantics from the repository-resolved 1.9.0 line.
    implementation(libs.kotlinx.coroutines.core)
    // RB1-R6: structured JSON tree parsing for the bootstrap readback/
    // status/effect channels (no Regex, no handwritten parser). 1.9.0 is
    // already present in gradle/verification-metadata.xml with jar/module
    // checksums; the compiler serialization plugin is NOT required for
    // JsonElement tree parsing. The Gradle qualification stage must
    // regenerate app/gradle.lockfile with --write-locks for the compile
    // classpaths (source-only lane cannot run Gradle).
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    "fullImplementation"(project(":feature:phonecontrol"))
    "fullImplementation"(project(":feature:rootsystem"))
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
