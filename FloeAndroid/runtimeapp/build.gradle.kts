import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.Properties
import java.util.ServiceLoader
import com.android.apksig.ApkVerifier
import com.android.build.api.artifact.SingleArtifact
import com.android.build.api.variant.BuiltArtifactsLoader
import com.android.build.api.variant.VariantOutputConfiguration.OutputType

plugins { alias(libs.plugins.android.application) }

// --- Pinned development debug signing identity -------------------------------
// Same floe.debug.keystore contract as :app; the runtime component MUST share
// the core app's signing identity (the installer refuses "Runtime signing
// identity differs"), so both modules read one property, never divergent ones.
val configuredKey = providers.gradleProperty("floe.debug.keystore").orNull
    ?: Properties().apply {
        rootProject.file("local.properties").takeIf { it.isFile }?.inputStream()?.use { load(it) }
    }.getProperty("floe.debug.keystore")

// --- Single release-version input ---------------------------------------------
// Read from gradle.properties (:app reads the identical values; the runtime
// identity check compares core/component longVersionCode on device). Defaults
// preserve the published 0.1.0-alpha.7 / versionCode 7; Main bumps exactly once
// per frozen candidate. No per-module constant may drift again.
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
// Identical contract in :app and :runtimeapp: the SAME floe.release.* values
// configure BOTH buildTypes.release, which is what makes the on-device
// "signing identity differs" equality check satisfiable for ordinary
// non-debuggable candidates. Passwords are only ever taken from the named
// environment variables of the build process (Main's keychain-backed helper
// exports them); the RELEASE keystore's contents are never read and no value
// is ever logged here. For debug variants the expected signer is derived by
// reading only the PUBLIC certificate of the debug identity actually
// configured (AGP's documented default alias/password constants).
// floe.release.expectedCertSha256 is PUBLIC metadata — the approved release
// certificate's SHA-256 digest (see apksigner verify --print-certs on any
// delivered approved candidate) — never a password or key material. It is what
// binds the cryptographic verification below to THIS project's expected
// identity instead of merely "some valid signature".
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

// --- Cryptographic APK signature verification (mirrored in :app) -------------
// Structural "APK Sig Block 42" presence proves only a container shape: a
// forged or tampered block could pass it. The real gate uses the pinned
// com.android.apksig 9.4.0 verifier already on the AGP 9.4.0 buildscript
// classpath (gradle/verification-metadata.xml pins apksig-9.4.0.jar; it is the
// same library the SDK build-tools apksigner verify command runs — digests
// were byte-identical to apksigner 37.0.0 on the existing alpha7 and
// qualification APKs, probe logged in Local/Private/android-g03-20261022/r3/
// packaging-review-repair). A v2/v3/v31 signature must VERIFY, and its signer
// certificate's public SHA-256 digest must equal the expected signing identity
// BEFORE anything is hashed, copied or embedded. Only public certificate
// digests are ever reported or compared — no key material, no passwords.
fun floeSha256Hex(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }

// Reads ONLY the public certificate for AGP's documented default debug alias
// from the configured debug keystore (alias/passwords are AGP's public default
// debug constants, the same values the debug signingConfigs above use).
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
// checkout). By export execution time the debug APK has already been signed
// with exactly that store, so an unresolvable identity means an unknown signer
// and is refused fail-closed.
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
            candidates.joinToString { it.path } + ". Export refuses to trust an unknown signer — " +
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
        "$context: cryptographic signature verification FAILED; refusing to hash, copy or embed. " +
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
            "signing identity $expectedCertificateSha256 — wrong key; export refused"
    }
    report("$context: real v2/v3 signature verified (pinned apksig 9.4.0); " +
        "signer certificate SHA-256 ${digests.single()}")
}

abstract class ExportSignedRuntimeApk : DefaultTask() {
    // The exact AGP SingleArtifact.APK output directory for THIS variant,
    // wired through the variant artifact provider (carries the producer task
    // dependency). It is never scanned for candidates: the AGP BuiltArtifacts
    // metadata (output-metadata.json, METADATA_FILE_VERSION 3) selects the
    // exact single output file.
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val apkDirectory: DirectoryProperty
    @get:Input
    abstract val variantName: Property<String>
    @get:Input
    abstract val buildType: Property<String>
    @get:Input
    abstract val trustedReleaseIdentityConfigured: Property<Boolean>
    @get:Input
    abstract val expectedApplicationId: Property<String>
    @get:Input
    abstract val expectedVersionCode: Property<Int>
    @get:Input
    @get:Optional
    abstract val expectedReleaseCertificateSha256: Property<String>
    @get:Input
    @get:Optional
    abstract val pinnedDebugKeystorePath: Property<String>
    @get:OutputDirectory
    abstract val exportDirectory: DirectoryProperty

    @TaskAction
    fun export() {
        val type = buildType.get()
        if (type == "release" && !trustedReleaseIdentityConfigured.get()) {
            error(
                "Refusing to export the release runtime component without the approved " +
                    "signing identity: configure floe.release.keystore, floe.release.keyAlias, " +
                    "floe.release.storePasswordEnv, floe.release.keyPasswordEnv and " +
                    "floe.release.expectedCertSha256 (identical values to :app so both share " +
                    "one signer). Debug keys are not a fallback."
            )
        }

        // 1. Exact single assembled output from the AGP artifact provider +
        //    BuiltArtifacts metadata — no directory scan, no stale pick, no
        //    filename heuristic; missing/ambiguous/split outputs are refused.
        val dir = apkDirectory.get().asFile
        val loader = ServiceLoader.load(
            BuiltArtifactsLoader::class.java, BuiltArtifactsLoader::class.java.classLoader
        ).firstOrNull() ?: error(
            "AGP's public BuiltArtifactsLoader service is unavailable on the buildscript " +
                "classpath; refusing to locate the runtime APK by scanning output directories"
        )
        val built = loader.load(apkDirectory.get()) ?: error(
            "No AGP BuiltArtifacts metadata (output-metadata.json) in the ${variantName.get()} " +
                "artifact directory ${dir} — the variant APK was not assembled through the " +
                "artifact pipeline; refusing to export from a directory scan"
        )
        require(built.variantName == variantName.get()) {
            "BuiltArtifacts metadata names variant ${built.variantName}, expected ${variantName.get()}"
        }
        require(built.applicationId == expectedApplicationId.get()) {
            "BuiltArtifacts metadata applicationId ${built.applicationId} != expected " +
                "${expectedApplicationId.get()}"
        }
        val element = built.elements.singleOrNull() ?: error(
            "BuiltArtifacts metadata lists ${built.elements.size} outputs " +
                "(${built.elements.joinToString { it.outputFile }}) for ${variantName.get()}; " +
                "exactly one is required — split or ambiguous outputs are refused"
        )
        require(element.outputType == OutputType.SINGLE && element.filters.isEmpty()) {
            "The single ${variantName.get()} output is a split/qualified element " +
                "(type ${element.outputType}, filters ${element.filters}); only the unsplit " +
                "APK may be embedded"
        }
        require(element.versionCode == expectedVersionCode.get()) {
            "BuiltArtifacts metadata versionCode ${element.versionCode} != expected " +
                "${expectedVersionCode.get()}"
        }
        val outputName = element.outputFile
        val apk = if (outputName.startsWith("/")) File(outputName) else File(dir, outputName)
        require(apk.isFile && apk.extension == "apk") {
            "BuiltArtifacts outputFile ${apk.path} is not an existing .apk file"
        }
        require(apk.canonicalFile.parentFile == dir.canonicalFile) {
            "BuiltArtifacts outputFile ${apk.path} escapes the artifact directory ${dir}"
        }

        // 2. Expected signing identity for this build type, then REAL
        //    cryptographic verification BEFORE any hashing/copying.
        val expectedCert = if (type == "release") {
            requireNotNull(expectedReleaseCertificateSha256.orNull) {
                "floe.release.expectedCertSha256 (approved release certificate SHA-256) is " +
                    "required to verify the release runtime component signature"
            }
        } else {
            floeExpectedDebugCertificateSha256(pinnedDebugKeystorePath.orNull)
        }
        floeRequireVerifiedApkSignature(
            apk, "Runtime component ${apk.name} (${variantName.get()})", expectedCert
        ) { logger.lifecycle(it) }

        // 3. Copy the verified bytes + write the digest and verified-signer sidecars.
        val output = exportDirectory.get().asFile
        output.mkdirs()
        val staging = File(output, "runtime.apk.part")
        val digest = MessageDigest.getInstance("SHA-256")
        apk.inputStream().use { input ->
            staging.outputStream().use { stream ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count); stream.write(buffer, 0, count)
                }
            }
        }
        require(staging.renameTo(File(output, "runtime.apk"))) {
            "Failed to publish the verified runtime component into ${output}"
        }
        File(output, "runtime.apk.sha256").writeText(
            digest.digest().joinToString("") { "%02x".format(it) } + "\n"
        )
        File(output, "runtime.apk.cert-sha256").writeText(expectedCert + "\n")
    }
}

// A release variant may only be assembled through the approved identity (the
// export task above guards the embedded product path; this guards direct
// :runtimeapp:assemble*Release use for every channel, play included).
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
                        "floe.release.expectedCertSha256 (Gradle properties or local.properties), " +
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
    namespace = "com.floe.android.runtime"
    if (!configuredKey.isNullOrBlank()) {
        val key = File(configuredKey)
        require(key.isAbsolute && key.isFile) { "Configured debug signing key is unavailable" }
        signingConfigs.getByName("debug") {
            storeFile = key
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
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
        applicationId = "com.floe.agent.runtime"
        minSdk = 28
        targetSdk = 37
        versionCode = floeVersionCode
        versionName = floeVersionName
        ndk { abiFilters += "arm64-v8a" }
        manifestPlaceholders["floeCorePackage"] = "com.floe.agent"
    }
    flavorDimensions += "distribution"
    productFlavors {
        create("full") {
            dimension = "distribution"
            applicationIdSuffix = ".full"
            manifestPlaceholders["floeCorePackage"] = "com.floe.agent.full"
        }
        create("play") {
            dimension = "distribution"
            manifestPlaceholders["floeCorePackage"] = "com.floe.agent"
        }
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            // Match the ordinary non-debuggable process boundary qualified in
            // R1 even when the component uses the pinned development identity.
            isDebuggable = false
            // The service permission is declared by the exact core build.
            // Values below are set per variant because flavor+build suffixes compose.
        }
        release {
            isMinifyEnabled = false
            if (floeReleaseIdentityConfigured) signingConfig = signingConfigs.getByName("floeRelease")
        }
    }
    buildFeatures { buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Executable payloads are package-manager extracted into nativeLibraryDir.
    packaging {
        jniLibs.useLegacyPackaging = true
        // Preserve the exact qualified executable payloads and CCS digest binding.
        jniLibs.keepDebugSymbols += setOf("**/libproot.so", "**/libproot_loader.so")
        jniLibs.excludes += "**/libfloeprobe.so" // R1 qualification executable is test-only.
        jniLibs.excludes += "**/libfloe_qualification_jni.so"
    }
}

androidComponents.onVariants { variant ->
    val full = variant.productFlavors.any { it.second == "full" }
    variant.manifestPlaceholders.put("floeCorePackage",
        "com.floe.agent" + (if (full) ".full" else "") + (if (variant.buildType == "debug") ".dev" else ""))
    // Only the full channel ever hands a signed component artifact to :app;
    // Play keeps no staged APK and cannot gain the installer path (its core
    // manifest has no REQUEST_INSTALL_PACKAGES and no embedded runtime.apk).
    if (full) {
        val type = requireNotNull(variant.buildType)
        val name = variant.name.replaceFirstChar { it.uppercase() }
        tasks.register<ExportSignedRuntimeApk>("export${name}RuntimeApk") {
            dependsOn("assemble$name")
            variantName.set(variant.name)
            buildType.set(type)
            trustedReleaseIdentityConfigured.set(floeReleaseIdentityConfigured)
            // applicationId composition mirrors the DSL above exactly:
            // base + flavor suffix (.full) + debug suffix (.dev).
            expectedApplicationId.set(
                "com.floe.agent.runtime.full" + (if (type == "debug") ".dev" else "")
            )
            expectedVersionCode.set(floeVersionCode)
            floeReleaseExpectedCertSha256?.let { expectedReleaseCertificateSha256.set(it) }
            if (!configuredKey.isNullOrBlank()) pinnedDebugKeystorePath.set(configuredKey)
            // Exact AGP variant artifact directory (provider-wired), NOT a
            // guessed outputs/apk/full/<type> path scan.
            apkDirectory.set(variant.artifacts.get(SingleArtifact.APK))
            exportDirectory.set(layout.buildDirectory.dir("exported-runtime-apk/${variant.name}"))
        }
    }
}

dependencies {
    implementation(project(":core:runtimeipc"))
    implementation(project(":core:workspacebridge"))
    implementation(project(":core:linuxruntime"))
    // Only the original environment authority and its dependencies. Main App
    // provider/security/history modules and files do not enter this component.
    implementation(project(":core:linuxauthoritybridge"))
    testImplementation(libs.junit)
}
