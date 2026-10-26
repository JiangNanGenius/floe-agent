// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/**
 * Application-owned MUTABLE WORKING COPY stage for the R2 edit routes.
 *
 * The existing snapshot stagers (provider + workspace) stay exactly as they
 * are: they publish IMMUTABLE, read-protected verified snapshots and remain
 * safe for public default READ_ONLY callers. The Office EDIT admission
 * requires a separately owned WRITABLE working copy (the module fail-closes
 * on any non-writable staged file), so this stager copies a snapshot forward
 * — never the other way around:
 *  - the source snapshot is opened read-only and is NEVER chmod'd, truncated,
 *    renamed or overwritten here (nor is any provider/workspace original:
 *    callers pass only their own staged snapshot);
 *  - the copy is byte-verified: length + SHA-256 of the streamed bytes must
 *    equal the snapshot's already-verified facts, so the working copy starts
 *    from exactly the proven content and becomes the receipt's
 *    expectedBaseSha256 for any later App-side compare;
 *  - ownership is canonical and bounded: a fresh randomly named directory
 *    under [root], a no-symlink regular file, inside [MAX_BYTES] (256 MiB,
 *    same Office cap as every other stage), copied in 64 KiB chunks;
 *  - cancellation ([isCurrent]) is honored between every chunk; the caller
 *    drains the actual IO before releasing references (same NonCancellable
 *    await discipline as the provider route);
 *  - retention is honest: a completed working copy is NEVER deleted by this
 *    class on success, failure, cancel or close — it is the recoverable base
 *    the App keeps (a user-visible recovery flow is separate pending work).
 *    Only THIS attempt's own never-exposed partial directory is cleaned.
 */
internal class OfficeEditableCopyStager(private val root: File) {

    /** The verified mutable working copy, owned by the App stage from here on. */
    data class EditableCopy(
        val sessionID: String,
        val file: File,
        val bytes: Long,
        val sha256: String,
        val extension: String,
    )

    class Failure(val code: String) : Exception(code)

    companion object {
        /** Same Office input/output byte cap as the snapshot stagers and the module. */
        const val MAX_BYTES = 256L * 1024 * 1024
        private const val CHUNK_BYTES = 64 * 1024
        private val SHA256_HEX = Regex("^[0-9a-f]{64}$")
        private val EDIT_EXTENSIONS = setOf("docx", "xlsx", "pptx")
    }

    /**
     * Copy [source] (a snapshot the caller already verified as [sourceBytes]
     * bytes with digest [sourceSha256]) into a fresh writable working copy.
     * Throws [Failure] with a stable code on any honest limit; the immutable
     * source is untouched on every path. Call on the service IO dispatcher,
     * never the UI thread; [isCurrent] must fence the captured owning
     * operation, not whichever task is selected now.
     */
    fun stage(
        source: File,
        sourceBytes: Long,
        sourceSha256: String,
        extension: String,
        isCurrent: () -> Boolean,
    ): EditableCopy {
        val ext = extension.lowercase(Locale.ROOT)
        if (ext !in EDIT_EXTENSIONS) throw Failure("invalidCopyExtension")
        if (sourceBytes !in 1..MAX_BYTES || !SHA256_HEX.matches(sourceSha256)) throw Failure("invalidCopySource")
        if (!isCurrent()) throw Failure("ownerChanged")
        // The immutable snapshot must be a real, non-symlink regular file.
        if (Files.isSymbolicLink(source.toPath()) || !source.isFile) throw Failure("copySourceUnavailable")
        if ((!root.isDirectory && !root.mkdirs()) || Files.isSymbolicLink(root.toPath())) {
            throw Failure("copyStorageUnavailable")
        }
        val sessionID = UUID.randomUUID().toString()
        val directory = File(root.canonicalFile, sessionID)
        Files.createDirectory(directory.toPath())
        var published = false
        try {
            val part = File(directory, "document.part")
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            FileInputStream(source).use { input ->
                FileChannel.open(
                    part.toPath(),
                    StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE,
                ).use { output ->
                    val page = ByteArray(CHUNK_BYTES)
                    while (true) {
                        if (!isCurrent()) throw Failure("ownerChanged")
                        val n = input.read(page)
                        if (n < 0) break
                        if (total + n > MAX_BYTES) throw Failure("contentTooLarge")
                        digest.update(page, 0, n)
                        var written = 0
                        while (written < n) written += output.write(ByteBuffer.wrap(page, written, n - written))
                        total += n
                    }
                    if (!isCurrent()) throw Failure("ownerChanged")
                    // Durability before publication: the working copy a later
                    // digest check must survive re-reads, not page cache luck.
                    output.force(true)
                }
            }
            // The streamed bytes must be EXACTLY the verified snapshot content.
            if (total != sourceBytes) throw Failure("copyLengthMismatch")
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (actual != sourceSha256) throw Failure("copySourceChanged")
            if (!isCurrent()) throw Failure("ownerChanged")
            val file = File(directory, "document.$ext")
            Files.move(part.toPath(), file.toPath())
            // Mutable by contract: the module EDIT admission re-checks
            // file.canWrite() against the live file, never against this return.
            if (Files.isSymbolicLink(file.toPath()) || !file.isFile || !file.canWrite()) {
                throw Failure("copyProtectionFailed")
            }
            val canonical = file.canonicalFile
            if (canonical.parentFile?.path != directory.canonicalFile.path ||
                canonical.name != "document.$ext"
            ) {
                throw Failure("copyOwnershipFailed")
            }
            published = true
            return EditableCopy(sessionID, canonical, sourceBytes, sourceSha256, ext)
        } finally {
            if (!published) {
                // Only this attempt's own never-exposed partial directory; the
                // immutable source and every earlier working copy stay intact.
                directory.listFiles()?.forEach { it.delete() }
                directory.delete()
            }
        }
    }
}
