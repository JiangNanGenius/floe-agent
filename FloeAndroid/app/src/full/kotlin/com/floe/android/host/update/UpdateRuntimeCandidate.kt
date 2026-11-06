// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.zip.ZipFile

/** A companion is admitted by the downloaded signed parent, never by the
 * currently running App's older bundled assets or a release-note URL. */
internal data class RuntimeInstallProof(
    val packageName: String,
    val versionCode: Long,
    val signerSha256: Set<String>,
    val sha256: String,
)

internal object RuntimeUpdatePolicy {
    fun accepts(main: ApkIdentity, runtime: ApkIdentity, installed: ApkIdentity,
        expectedPackage: String, sdkInt: Int): Boolean =
        runtime.packageName == expectedPackage && installed.packageName == expectedPackage &&
            runtime.longVersionCode == main.longVersionCode && runtime.longVersionCode >= installed.longVersionCode &&
            main.signerSha256.isNotEmpty() && runtime.signerSha256 == main.signerSha256 &&
            runtime.signerSha256 == installed.signerSha256 && runtime.minSdk <= sdkInt &&
            runtime.hasArm64Libraries && !runtime.hasForeignAbiLibraries

    fun installedMatches(installed: ApkIdentity?, proof: RuntimeInstallProof): Boolean =
        installed != null && installed.packageName == proof.packageName &&
            installed.longVersionCode == proof.versionCode && installed.signerSha256 == proof.signerSha256 &&
            proof.signerSha256.isNotEmpty()
}

internal class UpdateRuntimeCandidate(private val context: Context, private val reader: ApkIdentityReader) {
    private val runtimePackage = RuntimePackages.forCore(context.packageName).runtime

    fun isInstalled(): Boolean = try {
        context.packageManager.getPackageUid(runtimePackage, 0)
        RuntimePeerVerifier(context).verifyPeer(runtimePackage)
        true
    } catch (_: PackageManager.NameNotFoundException) { false }

    /** Off-main, same authenticated idle check as the existing setup path.
     * A failed query is unknown, never permission to replace a live worker. */
    fun isIdle(): Boolean {
        if (!isInstalled()) return true
        val client = RuntimeConnection(context)
        try {
            client.connect().get(15, TimeUnit.SECONDS)
            val response = client.exchange("status")
            check(response.getBoolean("ok"))
            return !response.getJSONObject("result").getBoolean("active")
        } finally { client.close() }
    }

    data class Prepared(val file: File, val proof: RuntimeInstallProof) : java.io.Closeable {
        override fun close() { file.delete() }
    }

    /** Extract a bounded, uniquely named private copy; no ZIP paths are used
     * as file paths. The parent stream is independently verified at commit. */
    fun prepare(parent: File, main: ApkIdentity): Prepared? {
        if (!isInstalled() || Build.VERSION.SDK_INT < 29) return null
        val installed = checkNotNull(reader.installed(runtimePackage))
        val directory = File(context.cacheDir, "app-runtime-update").apply { mkdirs() }
        check(directory.isDirectory && directory.canonicalFile.parentFile == context.cacheDir.canonicalFile)
        // One installer admission owns this directory; process-loss remnants
        // are disposable copies, not runtime workspaces or user files.
        directory.listFiles()?.filter { it.name.startsWith("runtime-update-") && it.extension == "apk" }
            ?.forEach { it.delete() }
        val file = File.createTempFile("runtime-update-", ".apk", directory)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            val expected = ZipFile(parent).use { zip ->
                val entries = zip.entries().asSequence().filter { it.name in setOf(APK, HASH) }.toList()
                check(entries.count { it.name == APK } == 1 && entries.count { it.name == HASH } == 1)
                val checksum = zip.getInputStream(entries.single { it.name == HASH }).use {
                    UpdateTextReader.read(it, 128) { error("Runtime checksum exceeds its budget") }.trim()
                }
                check(checksum.matches(Regex("[0-9a-f]{64}")))
                zip.getInputStream(entries.single { it.name == APK }).use { input ->
                    FileOutputStream(file).use { output ->
                        var total = 0L
                        val bytes = ByteArray(64 * 1024)
                        while (true) {
                            val count = input.read(bytes)
                            if (count < 0) break
                            total += count
                            check(total <= MAX_BYTES)
                            digest.update(bytes, 0, count); output.write(bytes, 0, count)
                        }
                        check(total > 0); output.fd.sync()
                    }
                }
                checksum
            }
            check(digest.digest().joinToString("") { "%02x".format(it) } == expected)
            val runtime = checkNotNull(reader.read(file))
            check(RuntimeUpdatePolicy.accepts(main, runtime, installed, runtimePackage, Build.VERSION.SDK_INT))
            return Prepared(file, RuntimeInstallProof(runtime.packageName, runtime.longVersionCode,
                runtime.signerSha256, expected))
        } catch (failure: Exception) { file.delete(); throw failure }
    }

    private companion object {
        const val APK = "assets/linux-runtime/runtime.apk"
        const val HASH = "assets/linux-runtime/runtime.apk.sha256"
        const val MAX_BYTES = 512L * 1024 * 1024
    }
}
