// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officereview

import com.floe.android.core.officeengine.OfficeRequestPolicy
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewNaming
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID

/**
 * Bounded immutable-copy helpers for conflict review. These functions only
 * ever write inside the caller-created review directory; they never open the
 * mutable working copy for writing and never touch the original.
 */
internal object OfficeConflictArtifacts {
    const val MAX_BYTES = 256L * 1024 * 1024
    private const val CHUNK = 64 * 1024

    /** Verify the source is a regular bounded file and hash it. */
    fun digest(file: File): Pair<String, Long>? {
        if (!file.isFile || file.length() !in 1..MAX_BYTES) return null
        if (Files.isSymbolicLink(file.toPath())) return null
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            file.inputStream().buffered(CHUNK).use { input ->
                val buffer = ByteArray(CHUNK)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    total += read
                    if (total > MAX_BYTES) return null
                    digest.update(buffer, 0, read)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) } to total
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Copy one source into an immutable file in [directory]. The copy is
     * re-read and verified against its streamed digest, is made read-only,
     * and — when [format] is known — must pass the SAME output verifier the
     * engine uses for a saved package. A torn/invalid working copy therefore
     * becomes an honest review failure, never a "version" shown to the user.
     */
    fun copyVerified(
        source: File,
        directory: File,
        name: String,
        format: String?,
        expectedSha256: String? = null,
        expectedBytes: Long? = null,
    ): OfficeConflictVersion? {
        if (!source.isFile || Files.isSymbolicLink(source.toPath())) return null
        val length = source.length()
        if (length !in 1..MAX_BYTES) return null
        if (expectedBytes != null && expectedBytes != length) return null
        val root = runCatching { directory.canonicalFile }.getOrNull() ?: return null
        if (!root.isDirectory) return null
        val safeName = name.substringAfterLast('/').substringAfterLast('\\')
            .takeIf { it.isNotBlank() && it.length <= 96 && it.none { c -> c == '/' || c == '\\' || c.code < 0x20 } }
            ?: return null
        val target = File(root, safeName)
        if (target.canonicalFile.parentFile?.canonicalFile != root) return null
        if (target.exists()) return null
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            FileInputStream(source).use { input ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(CHUNK)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        total += read
                        if (total > MAX_BYTES) throw IllegalStateException("sourceTooLarge")
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                    runCatching { output.fd.sync() }
                }
            }
            val sha = digest.digest().joinToString("") { "%02x".format(it) }
            if (target.length() != total) throw IllegalStateException("copyLengthMismatch")
            if (expectedSha256 != null && !sha.equals(expectedSha256, ignoreCase = true)) {
                throw IllegalStateException("copyDigestMismatch")
            }
            if (format != null) {
                val verified = OfficeRequestPolicy.verifyStagedOutput(target, format)
                if (!verified.verified || verified.sha256?.equals(sha, ignoreCase = true) != true) {
                    throw IllegalStateException("copyNotAValidPackage")
                }
            }
            if (!target.setReadOnly()) throw IllegalStateException("copyProtectionFailed")
            return OfficeConflictVersion(sha256 = sha, bytes = total, revision = null, file = target)
        } catch (_: Throwable) {
            runCatching { target.delete() }
            return null
        }
    }

    /**
     * Re-proves that [version] is exactly one regular, non-symlink file
     * directly inside a review directory under [root]. Any swapped, escaped
     * or re-linked file is refused before a reader opens it.
     */
    fun ownedVersionFile(root: File, directory: File, version: OfficeConflictVersion): File? {
        val canonicalRoot = runCatching { root.canonicalFile }.getOrNull() ?: return null
        val canonicalDirectory = runCatching { directory.canonicalFile }.getOrNull() ?: return null
        if (canonicalDirectory.parentFile?.canonicalFile != canonicalRoot) return null
        val file = runCatching { version.file.canonicalFile }.getOrNull() ?: return null
        if (file.parentFile?.canonicalFile != canonicalDirectory) return null
        if (Files.isSymbolicLink(file.toPath())) return null
        if (!file.isFile || file.length() != version.bytes) return null
        val digest = digest(file) ?: return null
        if (digest.second != version.bytes || !digest.first.equals(version.sha256, ignoreCase = true)) {
            return null
        }
        return file
    }

    /**
     * Writes ONE bounded UTF-8 text projection into an App-owned review
     * directory. The file is derived state beside the immutable snapshot; the
     * snapshot is never modified. The write is atomic (temp + fsync + rename)
     * and the final file is read-only. Returns its digest/length or null on
     * any refusal (oversize, wrong name, escape, IO failure).
     */
    fun writePreviewText(
        root: File,
        directory: File,
        name: String,
        text: String,
    ): Pair<String, Long>? {
        val canonicalRoot = runCatching { root.canonicalFile }.getOrNull() ?: return null
        val canonicalDirectory = runCatching { directory.canonicalFile }.getOrNull() ?: return null
        if (canonicalDirectory.parentFile?.canonicalFile != canonicalRoot) return null
        if (name != OfficeConflictPreviewNaming.MINE_FILE &&
            name != OfficeConflictPreviewNaming.CURRENT_FILE
        ) return null
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() ||
            bytes.size.toLong() > OfficeConflictPreviewAnswer.MAX_PREVIEW_FILE_BYTES
        ) return null
        val target = File(canonicalDirectory, name)
        if (target.canonicalFile.parentFile?.canonicalFile != canonicalDirectory) return null
        if (Files.isSymbolicLink(target.toPath())) return null
        val temporary = File(canonicalDirectory, ".$name.${UUID.randomUUID()}.tmp")
        if (temporary.canonicalFile.parentFile?.canonicalFile != canonicalDirectory) return null
        return try {
            FileOutputStream(temporary).use { output ->
                output.write(bytes)
                output.flush()
                runCatching { output.fd.sync() }
            }
            if (temporary.length() != bytes.size.toLong()) {
                throw IllegalStateException("previewLengthMismatch")
            }
            if (!temporary.setReadOnly()) throw IllegalStateException("previewProtectionFailed")
            // A previous admission for the SAME immutable snapshot may have
            // produced the same projection. Reuse it only when byte-identical;
            // otherwise remove the stale derived file and publish the new one.
            if (target.exists()) {
                val existing = digest(target)
                if (existing != null &&
                    existing.second == bytes.size.toLong() &&
                    existing.first == sha256(bytes)
                ) {
                    temporary.delete()
                    return existing
                }
                if (!target.delete()) throw IllegalStateException("previewReplaceFailed")
            }
            if (!temporary.renameTo(target)) throw IllegalStateException("previewRenameFailed")
            val verified = digest(target) ?: throw IllegalStateException("previewVerifyFailed")
            if (verified.second != bytes.size.toLong() || verified.first != sha256(bytes)) {
                throw IllegalStateException("previewDigestMismatch")
            }
            verified
        } catch (_: Throwable) {
            runCatching { temporary.delete() }
            null
        }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** Deletes only regular, non-symlink files directly inside [directory]. */
    fun deleteReviewDirectory(root: File, directory: File) {
        runCatching {
            val canonicalRoot = root.canonicalFile
            val canonical = directory.canonicalFile
            if (canonical.parentFile?.canonicalFile != canonicalRoot) return
            canonical.listFiles()?.forEach { child ->
                if (child.isFile && !Files.isSymbolicLink(child.toPath())) child.delete()
            }
            canonical.delete()
        }
    }
}
