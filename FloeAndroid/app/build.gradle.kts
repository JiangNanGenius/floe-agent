import java.util.Properties
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.X509Certificate
import com.android.apksig.ApkVerifier

plugins { alias(libs.plugins.android.application); alias(libs.plugins.kotlin.compose) }

// --- Full-channel component embedding ----------------------------------------
// The child APK is embedded ONLY after :runtimeapp's export task has selected
// the exact single assembled artifact via the AGP variant artifact provider
// and BuiltArtifacts metadata and CRYPTOGRAPHICALLY verified a real APK
// Signature Scheme v2/v3 signature bound to the expected signing identity
// (never a directory scan, never a stale or unsigned file, never a structure-
// only "signing block" claim). This task consumes that staged, signature-
// verified export: BEFORE writing the asset pair it independently re-verifies
// the exact staged bytes' v2/v3 signature against this build's expected
// signing identity (the same derivation as :runtimeapp), cross-checks the
// export's verified-signer sidecar, then re-hashes those bytes and
// cross-checks the export's digest sidecar. Only public certificate digests
// are ever reported — never key material or passwords. The asset layout
// (linux-runtime/runtime.apk + runtime.apk.sha256) is unchanged; the runtime
// package/channel/version/signer-equality checks remain the on-device
// authority and Main's offline apksigner equality checks remain required.
abstract class BundleLinuxRuntimeComponent : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val stagedApk: RegularFileProperty
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val stagedApkDigest: RegularFileProperty
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val stagedApkSigner: RegularFileProperty
    @get:Input
    abstract val buildType: Property<String>
    @get:Input
    abstract val trustedReleaseIdentityConfigured: Property<Boolean>
    @get:Input
    @get:Optional
    abstract val expectedReleaseCertificateSha256: Property<String>
    @get:Input
    @get:Optional
    abstract val pinnedDebugKeystorePath: Property<String>
    @get:OutputDirectory
    abstract val assetDirectory: DirectoryProperty

    @TaskAction fun bundle() {
        val apk = stagedApk.get().asFile
        require(apk.isFile) {
            "Staged runtime component APK is missing at ${apk}; :runtimeapp:export must produce " +
                "exactly one cryptographically signature-verified artifact per full variant " +
                "(no unsigned fallback)"
        }
        val expected = stagedApkDigest.get().asFile.readText().trim()
        require(expected.matches(Regex("[0-9a-f]{64}"))) { "Staged runtime digest sidecar is malformed: $expected" }
        val certifiedSigner = stagedApkSigner.get().asFile.readText().trim().lowercase()
        require(certifiedSigner.matches(Regex("[0-9a-f]{64}"))) {
            "Staged runtime signer sidecar is malformed: $certifiedSigner"
        }
        val type = buildType.get()
        if (type == "release" && !trustedReleaseIdentityConfigured.get()) {
            error(
                "Refusing to embed a release runtime component without the approved signing " +
                    "identity: configure floe.release.keystore, floe.release.keyAlias, " +
                    "floe.release.storePasswordEnv, floe.release.keyPasswordEnv and " +
                    "floe.release.expectedCertSha256. Debug keys are not a fallback."
            )
        }
        // Expected signing identity for this build type — the same one
        // consistent interface as :runtimeapp's export gate.
        val expectedCert = if (type == "release") {
            requireNotNull(expectedReleaseCertificateSha256.orNull) {
                "floe.release.expectedCertSha256 (approved release certificate SHA-256) is " +
                    "required to verify the release runtime component signature"
            }
        } else {
            floeExpectedDebugCertificateSha256(pinnedDebugKeystorePath.orNull)
        }
        require(certifiedSigner == expectedCert) {
            "The export's verified signer $certifiedSigner is not this build's expected signing " +
                "identity $expectedCert; refusing to embed a component verified against a " +
                "different identity"
        }
        // Second real cryptographic gate: verify these exact staged bytes with
        // the pinned apksig verifier immediately BEFORE hashing/embedding.
        floeRequireVerifiedApkSignature(
            apk, "Staged runtime component ${apk.name} ($type)", expectedCert
        ) { logger.lifecycle(it) }
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
        val computed = digest.digest().joinToString("") { "%02x".format(it) }
        require(computed == expected) {
            "Staged runtime APK bytes changed after :runtimeapp signature verification " +
                "($computed != $expected); refusing to hash/embed a mismatched component"
        }
        output.resolve("runtime.apk.sha256").writeText(computed + "\n")
    }

    // These verification helpers live INSIDE this task class (a static
    // companion object), not as script-level functions: any reference from a
    // class declared in the script to a Build_gradle member would compile
    // BundleLinuxRuntimeComponent as a non-static inner class and Gradle would
    // then refuse to instantiate the task ("Class
    // Build_gradle.BundleLinuxRuntimeComponent is a non-static inner class").
    // The companion is fully self-contained (JDK/Kotlin/apksig imports only)
    // and every task input arrives through the annotated properties above, so
    // the task captures no script state.
    companion object {
        // --- Cryptographic APK signature verification (mirrored in :runtimeapp) ------
        // Structural "APK Sig Block 42" presence proves only a container shape: a
        // forged or tampered block could pass it. The real gate uses the pinned
        // com.android.apksig 9.4.0 verifier already on the AGP 9.4.0 buildscript
        // classpath (gradle/verification-metadata.xml pins apksig-9.4.0.jar; it is the
        // same library the SDK build-tools apksigner verify command runs — digests
        // were byte-identical to apksigner 37.0.0 on the existing alpha7 and
        // qualification APKs). A v2/v3/v31 signature must VERIFY and its signer
        // certificate's public SHA-256 digest must equal the expected signing identity
        // BEFORE anything is hashed or embedded. Only public certificate digests are
        // ever reported or compared — no key material, no passwords. These helpers are
        // byte-consistent with :runtimeapp's export gate (one signing interface, one
        // verification semantics for both modules).
        fun floeSha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }

        // Reads ONLY the public certificate for AGP's documented default debug alias
        // from the configured debug keystore (alias/passwords are AGP's public default
        // debug constants, the same values the debug signingConfigs use).
        fun floeKeystoreCertificateSha256(keystore: File, alias: String, storePassword: String): String {
            var cert: X509Certificate? = null
            var lastError: Exception? = null
            for (storeType in listOf("JKS", "PKCS12")) {
                try {
                    val ks = KeyStore.getInstance(storeType)
                    keystore.inputStream().use { ks.load(it, storePassword.toCharArray()) }
                    cert = ks.getCertificate(alias) as? X509Certificate
                    if (cert != null) break
                } catch (e: Exception) { lastError = e }
            }
            val found = requireNotNull(cert) {
                "Cannot derive the expected debug certificate from ${keystore.name} (alias $alias with " +
                    "AGP's public default debug credentials): " + (lastError?.message ?: "no such certificate")
            }
            return floeSha256Hex(found.encoded)
        }

        // The expected debug signer derives from the debug identity actually
        // configured: the pinned floe.debug.keystore if set, else AGP's documented
        // default debug keystore location ($ANDROID_USER_HOME/debug.keystore when the
        // variable is set, else $HOME/.android/debug.keystore). The alias is tried as
        // androiddebugkey first (the DSL alias both modules configure, and the alias
        // of Android-Studio-generated debug stores) then AndroidDebugKey (the alias of
        // a store AGP itself generated via createDefaultDebugStore on a fresh
        // checkout). At task execution time the debug APK has already been signed with
        // exactly that store, so an unresolvable identity means an unknown signer and
        // is refused fail-closed.
        fun floeExpectedDebugCertificateSha256(pinnedKeystorePath: String?): String {
            val candidates = if (!pinnedKeystorePath.isNullOrBlank()) {
                listOf(File(pinnedKeystorePath))
            } else {
                buildList {
                    System.getenv("ANDROID_USER_HOME")?.takeIf { it.isNotBlank() }
                        ?.let { add(File(it, "debug.keystore")) }
                    add(File(File(System.getProperty("user.home"), ".android"), "debug.keystore"))
                }
            }
            val keystore = candidates.firstOrNull { it.isFile } ?: error(
                "The debug signing identity cannot be derived: no debug keystore among " +
                    candidates.joinToString { it.path } + ". Embed refuses to trust an unknown signer — " +
                    "set floe.debug.keystore (absolute path) so both modules share one explicit debug identity."
            )
            var lastError: IllegalArgumentException? = null
            for (alias in listOf("androiddebugkey", "AndroidDebugKey")) {
                try {
                    return floeKeystoreCertificateSha256(keystore, alias, "android")
                } catch (e: IllegalArgumentException) { lastError = e }
            }
            throw requireNotNull(lastError) {
                "Debug identity unreadable from ${keystore.path}"
            }
        }

        fun floeRequireVerifiedApkSignature(
            apk: File,
            context: String,
            expectedCertificateSha256: String,
            report: (String) -> Unit,
        ) {
            val result = try {
                ApkVerifier.Builder(apk).build().verify()
            } catch (e: Exception) {
                error("$context: cryptographic APK signature verification could not be performed: ${e.message}")
            }
            require(result.isVerified) {
                "$context: cryptographic signature verification FAILED; refusing to hash or embed. " +
                    "Verifier issues: ${result.errors.joinToString { it.toString() }}"
            }
            require(result.isVerifiedUsingV2Scheme || result.isVerifiedUsingV3Scheme || result.isVerifiedUsingV31Scheme) {
                "$context: no cryptographically verified APK Signature Scheme v2/v3 signature (v1/JAR-only or " +
                    "unsigned) — a signing-block structure alone proves nothing and must never be trusted here"
            }
            val digests = result.signerCertificates.map { floeSha256Hex(it.encoded) }.distinct()
            require(digests.size == 1) {
                "$context: expected exactly one signer certificate, verified ${digests.size}"
            }
            require(digests.single() == expectedCertificateSha256) {
                "$context: verified signer certificate SHA-256 ${digests.single()} does not match the expected " +
                    "signing identity $expectedCertificateSha256 — wrong key; embed refused"
            }
            report("$context: real v2/v3 signature verified (pinned apksig 9.4.0); " +
                "signer certificate SHA-256 ${digests.single()}")
        }
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
// behaviour is preserved unchanged.
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

// --- Single release-version input ---------------------------------------------
// Identical read in :runtimeapp (gradle.properties holds the one pair; the
// runtime identity check compares core/component longVersionCode on device, so
// divergent constants are a correctness defect, not a style choice). Defaults
// preserve the published 0.1.0-alpha.7 / versionCode 7 bytes-for-bytes; this
// round deliberately does NOT bump — Main verifies an unused version/tag and
// overrides both values exactly once per frozen candidate via -P or an edited
// gradle.properties line.
val floeVersionName = providers.gradleProperty("floe.version.name").orNull
    ?: error("gradle.properties must define floe.version.name (single release-version input)")
require(floeVersionName.matches(Regex("^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$"))) {
    "floe.version.name must match the stage-release grammar [A-Za-z0-9._+-] (1-64 chars)"
}
val floeVersionCode = (providers.gradleProperty("floe.version.code").orNull
    ?: error("gradle.properties must define floe.version.code (single release-version input)"))
    .trim().toIntOrNull()?.takeIf { it >= 1 && it <= 2100000000 }
    ?: error("floe.version.code must be a positive versionCode within the platform range")

// --- Approved release signing identity (interface names only, never values) --
// The SAME floe.release.* interface configures :app and :runtimeapp release
// signing from one invocation's environment, which is what lets an ordinary
// non-debuggable candidate satisfy BundledRuntimeInstaller's signer-equality
// check. Values of floe.release.* properties are identity references (path /
// alias / environment-variable NAME / PUBLIC certificate digest); the two
// environment variables carry the keychain-retrieved passwords into the Gradle
// process only (Main's helper exports them; nothing here persists, prints or
// copies a value). floe.release.expectedCertSha256 is the approved release
// certificate's public SHA-256 digest (obtainable via apksigner verify
// --print-certs on any approved candidate or keytool on the certificate) — it
// is public metadata, never a secret, and it is what binds cryptographic
// verification to THIS project's expected identity rather than "any valid
// signature". Partial configuration fails at configuration time; a fully
// absent interface keeps debug behaviour but refuses release assembly through
// the guard task below — there is no unsigned, debug-signed or empty-cert
// release path.
val floeSigningLocal = Properties().apply {
    rootProject.file("local.properties").takeIf { it.isFile }?.inputStream()?.use { load(it) }
}
fun floeReleaseProperty(name: String): String? =
    (providers.gradleProperty(name).orNull ?: floeSigningLocal.getProperty(name))?.takeIf { it.isNotBlank() }
val floeReleaseKeystorePath = floeReleaseProperty("floe.release.keystore")
val floeReleaseKeyAlias = floeReleaseProperty("floe.release.keyAlias")
val floeReleaseStoreEnvName = floeReleaseProperty("floe.release.storePasswordEnv")
val floeReleaseKeyEnvName = floeReleaseProperty("floe.release.keyPasswordEnv")
val floeReleaseExpectedCert = floeReleaseProperty("floe.release.expectedCertSha256")
val floeReleaseInterface = listOf(
    "floe.release.keystore" to floeReleaseKeystorePath,
    "floe.release.keyAlias" to floeReleaseKeyAlias,
    "floe.release.storePasswordEnv" to floeReleaseStoreEnvName,
    "floe.release.keyPasswordEnv" to floeReleaseKeyEnvName,
    "floe.release.expectedCertSha256" to floeReleaseExpectedCert,
)
val floeReleaseSupplied = floeReleaseInterface.count { it.second != null }
require(floeReleaseSupplied == 0 || floeReleaseSupplied == floeReleaseInterface.size) {
    "Partial approved release signing configuration; missing: " +
        floeReleaseInterface.filter { it.second == null }.joinToString { it.first } +
        " (all five interface entries are required together, or none for debug-only work)"
}
val floeReleaseIdentityConfigured = floeReleaseSupplied == floeReleaseInterface.size
val floeReleaseExpectedCertSha256 = floeReleaseExpectedCert?.lowercase()?.also {
    require(it.matches(Regex("^[0-9a-f]{64}$"))) {
        "floe.release.expectedCertSha256 must be the approved release certificate's public " +
            "SHA-256 digest as 64 hex characters (public metadata — never a password or key)"
    }
}

// A release variant may only be assembled through the approved identity, for
// both channels. The child's embedded product path is additionally guarded by
// :runtimeapp's export task before anything is hashed or embedded.
val verifyFloeReleaseSigningIdentity =
    tasks.register("verifyFloeReleaseSigningIdentity") {
        description = "Fails release assembly unless the approved floe.release.* signing identity is fully configured"
        group = "verification"
        val configured = floeReleaseIdentityConfigured
        doLast {
            if (!configured) {
                error(
                    "Refusing to assemble a release candidate without the approved signing " +
                        "identity: configure floe.release.keystore, floe.release.keyAlias, " +
                        "floe.release.storePasswordEnv, floe.release.keyPasswordEnv and " +
                        "floe.release.expectedCertSha256 (Gradle properties or local.properties) " +
                        "and export the referenced password environment variables. Unsigned release " +
                        "output must never be hashed, embedded, staged or published; debug/pinned " +
                        "development keys are not a release fallback."
                )
            }
        }
    }
tasks.configureEach {
    if (name == "assembleFullRelease" || name == "assemblePlayRelease") {
        dependsOn(verifyFloeReleaseSigningIdentity)
    }
}

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
    if (floeReleaseIdentityConfigured) {
        val keystore = File(requireNotNull(floeReleaseKeystorePath))
        require(keystore.isAbsolute && keystore.isFile) {
            "floe.release.keystore must be an existing absolute path (never printed or copied here)"
        }
        signingConfigs.create("floeRelease") {
            storeFile = keystore
            storePassword = providers.environmentVariable(requireNotNull(floeReleaseStoreEnvName)).orNull
                ?: error("Release keystore password environment variable ${floeReleaseStoreEnvName} is not set")
            keyAlias = requireNotNull(floeReleaseKeyAlias)
            keyPassword = providers.environmentVariable(requireNotNull(floeReleaseKeyEnvName)).orNull
                ?: error("Release key password environment variable ${floeReleaseKeyEnvName} is not set")
        }
    }
    compileSdk = 37
    ndkVersion = "30.0.16248370"
    defaultConfig {
        applicationId = "com.floe.agent"
        minSdk = 28
        targetSdk = 37
        versionCode = floeVersionCode
        versionName = floeVersionName
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
        release {
            isMinifyEnabled = false
            if (floeReleaseIdentityConfigured) signingConfig = signingConfigs.getByName("floeRelease")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    packaging {
        jniLibs.useLegacyPackaging = false
        // Preserve the verified upstream Office bytes. Their own immutable
        // payload pins are checked independently from Floe's Swift core;
        // a packaging strip must not silently replace that native identity.
        val officePins = groovy.json.JsonSlurper().parse(
            rootProject.file("core/officeengine/payload-pins.json")) as Map<*, *>
        val officeLibraries = officePins["libraries"] as Map<*, *>
        jniLibs.keepDebugSymbols += officeLibraries.keys.map { "**/$it" }
        // Product-packaging boundary for the Swift SDK runtime staging: the
        // four test-only Swift runtime libraries are staged inside
        // core/swiftbridge jniLibs for host qualification and are byte-pinned
        // by the accepted Core12 native manifest, but no product library's
        // DT_NEEDED closure references them (verified against the actual
        // candidate ELF data) and the stage-release packager refuses any
        // formal APK that ships them. Exclude them from the product APK only;
        // the native producer, its staging script and its manifest binding
        // stay byte-identical.
        jniLibs.excludes += setOf(
            "**/libTesting.so",
            "**/libXCTest.so",
            "**/lib_TestingInterop.so",
            "**/lib_Testing_Foundation.so",
        )
    }
}

// GitHub has one public APK asset. The separate-UID execution component is
// inside that APK and installed only after the user's explicit OS consent.
// Play consumes its component through the Store and never embeds an installer:
// the wiring below stays full-flavor-only, so no Play variant ever gains a
// staged child APK, runtime.apk assets or the request-install path.
androidComponents.onVariants { variant ->
    if (variant.productFlavors.any { it.second == "full" }) {
        val type = requireNotNull(variant.buildType)
        val name = variant.name.replaceFirstChar { it.uppercase() }
        val exportedDir = project(":runtimeapp").layout.buildDirectory.dir("exported-runtime-apk/${variant.name}")
        val bundle = tasks.register<BundleLinuxRuntimeComponent>("bundle${name}LinuxRuntime") {
            // Deterministic order: assemble -> export (BuiltArtifacts-exact
            // selection + cryptographic v2/v3 verify + digest/signer sidecars)
            // -> embed (signer cross-check + re-verify + digest re-hash)
            // -> mergeAssets -> package.
            dependsOn(":runtimeapp:export${name}RuntimeApk")
            stagedApk.set(exportedDir.map { it.file("runtime.apk") })
            stagedApkDigest.set(exportedDir.map { it.file("runtime.apk.sha256") })
            stagedApkSigner.set(exportedDir.map { it.file("runtime.apk.cert-sha256") })
            buildType.set(type)
            trustedReleaseIdentityConfigured.set(floeReleaseIdentityConfigured)
            floeReleaseExpectedCertSha256?.let { expectedReleaseCertificateSha256.set(it) }
            floeDevKeystore?.let { pinnedDebugKeystorePath.set(it.absolutePath) }
            assetDirectory.set(layout.buildDirectory.dir("generated/runtimeComponent/${variant.name}"))
        }
        variant.sources.assets?.addGeneratedSourceDirectory(bundle, BundleLinuxRuntimeComponent::assetDirectory)
    }
}

dependencies {
    implementation(project(":core:contracts"))
    implementation(project(":core:network"))
    implementation(project(":core:networkmonitor"))
    implementation(project(":core:pcap"))
    implementation(libs.androidx.work.runtime)
    // Preserve the already-locked concurrent-futures KTX 1.2.0 line:
    // androidx.test:core 1.7.0 (androidTest) references SuspendToFutureAdapter,
    // which is absent from WorkManager 2.12.0's minimum 1.1.0, and AGP
    // consistent resolution otherwise downgrades the androidTest runtime to 1.1.0.
    implementation("androidx.concurrent:concurrent-futures-ktx:1.2.0")
    implementation(project(":feature:network"))
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
    implementation(project(":feature:notescontracts"))
    implementation(project(":core:notesmedia"))
    implementation(project(":feature:notes"))
    // G04 service/presentation modules; owner-bound host adapters gate use.
    implementation(project(":core:safgateway"))
    implementation(project(":core:officeengine"))
    implementation(project(":feature:ide"))
    implementation(project(":feature:terminal"))
    implementation(project(":feature:browser"))
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
    testImplementation("org.json:json:20240303")
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
