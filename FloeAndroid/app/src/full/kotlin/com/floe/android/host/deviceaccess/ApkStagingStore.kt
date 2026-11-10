// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.content.Context
import android.net.Uri
import com.floe.android.rootsystem.StagedApk
import java.io.File
import java.security.MessageDigest

/**
 * App-side staging for user-picked APKs. The user grants a document via SAF;
 * this store copies the bytes into Floe's app-specific external staging dir
 * (a tree the shell/root service can actually read), records a bounded
 * manifest and hands out opaque staged ids. Install tool calls name those ids
 * and the privileged service re-validates the resolved path against the
 * shared-storage ceiling before touching anything.
 *
 * Staging never installs anything by itself and never follows model-supplied
 * paths: only SAF content the user explicitly picked enters this store.
 */
internal class ApkStagingStore(private val context: Context) {

    sealed interface StageResult {
        data class Ok(val staged: List<StagedApk>, val skipped: List<String>) : StageResult
        data class Failed(val code: String) : StageResult
    }

    private val baseDir: File?
        get() = context.getExternalFilesDir("apk-staging")

    @Synchronized
    fun list(): List<StagedApk> = readManifest().map { it.toStagedApk() }

    @Synchronized
    fun stage(uris: List<Uri>): StageResult {
        val dir = baseDir ?: return StageResult.Failed("staging_unavailable")
        if (!dir.exists() && !dir.mkdirs()) return StageResult.Failed("staging_unavailable")
        val entries = readManifest().toMutableList()
        // Every picked uri is accounted for: capacity overflow and copy
        // failures land in `skipped` so no selection is silently dropped.
        val skipped = ArrayList<String>()
        val added = ArrayList<StagedApk>()
        for (uri in uris) {
            if (entries.size >= ApkStagingManifest.MAX_ENTRIES) {
                skipped += "capacity:" + uri.toString().take(72)
                continue
            }
            val staged = copyOne(dir, uri) ?: run {
                skipped += uri.toString().take(80)
                continue
            }
            entries.removeAll { it.stagedId == staged.stagedId }
            entries += ApkStagingManifest.Entry(
                stagedId = staged.stagedId,
                fileName = staged.fileName,
                sizeBytes = staged.sizeBytes,
                sha256 = staged.sha256,
                packageName = staged.packageName,
                addedAtMillis = System.currentTimeMillis(),
            )
            added += staged
        }
        if (added.isEmpty() && skipped.isNotEmpty()) return StageResult.Failed("staging_failed")
        writeManifest(entries)
        return StageResult.Ok(added, skipped)
    }

    /**
     * Remove one manifest entry. App-local bytes (SAF/workspace) are deleted
     * with the row; service-owned rows are removed from the manifest only
     * and the caller releases the physical bytes through the service's typed
     * maintenance path (see DeviceAccessHost.removeStagedApk), restoring the
     * row when the release refuses. Returns the removed entry.
     */
    @Synchronized
    fun remove(stagedId: String): ApkStagingManifest.Entry? {
        if (!ApkStagingManifest.stagedIdValid(stagedId)) return null
        val entries = readManifest()
        val target = entries.firstOrNull { it.stagedId == stagedId } ?: return null
        if (target.origin != ApkStagingManifest.Origin.FILE_ROOT) {
            File(baseDir, fileNameFor(target.stagedId)).delete()
        }
        writeManifest(entries.filterNot { it.stagedId == stagedId })
        return target
    }

    /** Restore a row whose physical release failed or was refused. */
    @Synchronized
    fun restore(entry: ApkStagingManifest.Entry) {
        val entries = readManifest().filterNot { it.stagedId == entry.stagedId }
        if (entries.size >= ApkStagingManifest.MAX_ENTRIES) return
        writeManifest(entries + entry)
    }

    /** Absolute service-readable staged path for an existing entry. */
    @Synchronized
    fun stagedPath(stagedId: String): String? = stagedEntry(stagedId)?.first

    /**
     * Resolve a staged id to its absolute path AND its digest binding. The
     * file must exist and still match the manifest byte size; the content
     * digest itself is re-verified by the privileged service over the very
     * bytes it streams to the package manager, so a modified file fails
     * closed at the point of effect.
     */
    @Synchronized
    fun stagedEntry(stagedId: String): Pair<String, ApkStagingManifest.Entry>? {
        if (!ApkStagingManifest.stagedIdValid(stagedId)) return null
        val entry = readManifest().firstOrNull { it.stagedId == stagedId } ?: return null
        if (entry.origin == ApkStagingManifest.Origin.FILE_ROOT) {
            // The service-issued path recorded at adoption time is the
            // identity; the App must not stat another UID's private stage.
            val path = entry.fileName
            if (!com.floe.android.rootsystem.policy.StagedApkPolicy.isServiceStagedPath(path)) {
                return null
            }
            return path to entry
        }
        val file = File(baseDir, fileNameFor(stagedId))
        if (!file.isFile) return null
        if (file.length() != entry.sizeBytes) return null
        return file.absolutePath.takeIf { it.startsWith("/") }?.let { it to entry }
    }

    /**
     * Adopt a Swift-staged workspace transfer: the returned binding is
     * re-verified against the actual bytes (size + SHA-256) BEFORE the file
     * enters the manifest, so a corrupted or swapped inbox file can never
     * become an install target. Returns null on any mismatch.
     */
    @Synchronized
    fun adoptWorkspaceFile(
        inboxFile: File,
        expectedSha256: String,
        expectedSizeBytes: Long,
    ): StagedApk? {
        if (!inboxFile.isFile) return null
        if (inboxFile.length() != expectedSizeBytes) {
            inboxFile.delete()
            return null
        }
        val sha = sha256Of(inboxFile)
        if (sha == null || !sha.equals(expectedSha256, ignoreCase = true)) {
            inboxFile.delete()
            return null
        }
        val stagedId = ApkStagingManifest.stagedIdFor(sha)
        val dir = baseDir ?: return null
        if (!dir.exists() && !dir.mkdirs()) return null
        val finalFile = File(dir, fileNameFor(stagedId))
        val moved = if (inboxFile.renameTo(finalFile)) {
            true
        } else {
            runCatching {
                inboxFile.inputStream().use { input ->
                    finalFile.outputStream().use { output -> input.copyTo(output) }
                }
                inboxFile.delete()
            }.isSuccess && finalFile.isFile
        }
        if (!moved) return null
        if (finalFile.length() != expectedSizeBytes) {
            finalFile.delete()
            return null
        }
        val packageName = context.packageManager.getPackageArchiveInfo(finalFile.absolutePath, 0)
            ?.packageName
        val entries = readManifest().filterNot { it.stagedId == stagedId }
        if (entries.size >= ApkStagingManifest.MAX_ENTRIES) return null
        val entry = ApkStagingManifest.Entry(
            stagedId = stagedId,
            fileName = finalFile.name,
            sizeBytes = expectedSizeBytes,
            sha256 = sha,
            packageName = packageName,
            addedAtMillis = System.currentTimeMillis(),
            origin = ApkStagingManifest.Origin.WORKSPACE,
        )
        writeManifest(entries + entry)
        return entry.toStagedApk()
    }

    /**
     * Adopt a service-side copy of a user-granted file-root APK. The service
     * issues the digest-named path inside its own uid/package namespaced
     * leaf; the entry records that exact path as the file identity so the
     * App never stats or deletes another UID's private storage.
     */
    @Synchronized
    fun adoptServiceCopy(
        stagedPath: String,
        receipt: com.floe.android.rootsystem.StagedCopyReceipt,
    ): StagedApk? {
        if (stagedPath != receipt.stagedPath) return null
        if (!com.floe.android.rootsystem.policy.StagedApkPolicy.isServiceStagedPath(stagedPath)) {
            return null
        }
        val pathDigest = stagedPath.substringAfterLast('/').removeSuffix(".apk")
        if (!pathDigest.equals(receipt.sha256, ignoreCase = true)) return null
        if (receipt.sizeBytes !in 1..com.floe.android.rootsystem.policy.StagedApkPolicy.MAX_APK_BYTES) {
            return null
        }
        val stagedId = ApkStagingManifest.stagedIdFor(receipt.sha256)
        val entries = readManifest().filterNot { it.stagedId == stagedId }
        if (entries.size >= ApkStagingManifest.MAX_ENTRIES) return null
        val entry = ApkStagingManifest.Entry(
            stagedId = stagedId,
            fileName = stagedPath,
            sizeBytes = receipt.sizeBytes,
            sha256 = receipt.sha256,
            packageName = receipt.packageName,
            addedAtMillis = System.currentTimeMillis(),
            origin = ApkStagingManifest.Origin.FILE_ROOT,
        )
        writeManifest(entries + entry)
        return entry.toStagedApk()
    }

    private fun copyOne(dir: File, uri: Uri): StagedApk? {
        val temp = File(dir, ".incoming-${System.nanoTime()}")
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                temp.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                        size += read
                        if (size > com.floe.android.rootsystem.policy.StagedApkPolicy.MAX_APK_BYTES) {
                            throw java.io.IOException("apk too large")
                        }
                    }
                    output.fd.sync()
                }
            } ?: return null
            val sha = digest.digest().joinToString("") { "%02x".format(it) }
            val stagedId = ApkStagingManifest.stagedIdFor(sha)
            val packageName = context.packageManager.getPackageArchiveInfo(temp.absolutePath, 0)
                ?.packageName
            val finalFile = File(dir, fileNameFor(stagedId))
            if (!temp.renameTo(finalFile)) return null
            StagedApk(
                stagedId = stagedId,
                fileName = displayName(uri).take(ApkStagingManifest.MAX_FILE_NAME),
                sizeBytes = size,
                sha256 = sha,
                packageName = packageName,
            )
        } catch (_: Throwable) {
            null
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    private fun displayName(uri: Uri): String {
        val last = uri.lastPathSegment
        if (!last.isNullOrBlank()) return last.substringAfterLast('/')
        return "staged.apk"
    }

    private fun sha256Of(file: File): String? = try {
        file.inputStream().use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        }
    } catch (_: Throwable) {
        null
    }

    private fun fileNameFor(stagedId: String): String =
        stagedId.replace(':', '_') + ".apk"

    private fun manifestFile(): File? = baseDir?.let { File(it, "manifest.json") }

    private fun readManifest(): List<ApkStagingManifest.Entry> {
        val file = manifestFile() ?: return emptyList()
        if (!file.isFile) return emptyList()
        return ApkStagingManifest.fromJson(file.readText())
    }

    private fun writeManifest(entries: List<ApkStagingManifest.Entry>) {
        val file = manifestFile() ?: return
        val text = ApkStagingManifest.toJson(entries)
        val temp = File(file.parentFile, ".manifest-${System.nanoTime()}.tmp")
        try {
            temp.outputStream().use { stream ->
                stream.write(text.toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
            if (!temp.renameTo(file)) {
                file.writeText(text)
                temp.delete()
            }
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    private fun ApkStagingManifest.Entry.toStagedApk() = StagedApk(
        stagedId = stagedId,
        fileName = fileName,
        sizeBytes = sizeBytes,
        sha256 = sha256,
        packageName = packageName,
    )
}
