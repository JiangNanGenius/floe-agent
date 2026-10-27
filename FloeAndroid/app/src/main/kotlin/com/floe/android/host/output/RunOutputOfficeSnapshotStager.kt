// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/** Read-only byte transport over the EXISTING native run-output authority,
 * mirroring the reviewed `WorkspaceOfficeSnapshotStager` discipline exactly
 * (same chunk bound, same cap, same streaming SHA + exact EOF + digest
 * equality, same CREATE_NEW part → fsync → rename → setReadOnly immutable
 * snapshot, same ticket close in `finally` and own-dir-only cleanup).
 *
 * The consumer never asks for a path: it names one exact (conversation,
 * run, output) triple; native re-derives the sealed receipt from the run's
 * OWN durable toolResult record, verifies the snapshot bytes under the
 * trusted artifact root, and streams the verified URL. Every returned fact
 * (displayName, byteCount, sha256, relativePath) is validated against the
 * canonical namespace re-derived from the identities themselves — a reply
 * field that disagrees fails the stage closed. The produced file is an
 * immutable input snapshot; it is NOT permission to touch the run-output
 * original (which stays runtime-owned and copy-only).
 *
 * Lane 17 extension (ONE storage implementation, never a rewritten one):
 * the accepted format set is now the constructor's [formats], defaulted to
 * the reviewed OOXML triple so EVERY existing Office caller is byte-identical
 * in behaviour. A PDF-format instance adds two extra closed proofs BEFORE
 * the snapshot is published: the native host header's declared MIME MUST
 * agree with the sealed extension (`application/pdf` ⇄ `.pdf`, the
 * [RunOutputReply.egressInfo]-validated facts — a reply naming another MIME
 * for a pdf-named output is refused whole), and the FIRST streamed bytes
 * carry the real `%PDF-` magic (a byte-level header proof measured on the
 * copy, alongside the existing exact length + whole-stream SHA + clean EOF;
 * a receipt claiming pdf identity over non-PDF bytes is refused and its own
 * directory removed like every other failure).
 *
 * Call on an IO dispatcher, never the UI thread.
 */
internal class RunOutputOfficeSnapshotStager(
    private val root: File,
    private val channel: RunOutputEgressChannel,
    private val formats: Set<String> = OFFICE_FORMAT_EXTENSIONS,
) {
    data class Owner(
        val conversationID: String, val runID: String, val outputID: String,
        val nativeEpoch: Long, val hostGeneration: Long,
    ) {
        init {
            require(UUID.fromString(conversationID).toString().equals(conversationID, true))
            require(UUID.fromString(runID).toString().equals(runID, true))
            require(outputID.matches(Regex("[0-9a-f]{64}")))
            require(nativeEpoch > 0 && hostGeneration >= 0)
        }
    }

    data class Snapshot(
        val sessionID: String, val owner: Owner, val outputID: String,
        val displayName: String, val relativePath: String, val mimeType: String,
        val file: File, val bytes: Long, val sha256: String,
    )

    class Failure(val code: String) : Exception(code)

    /** [isCurrent] must check this captured owner (epoch/generation/surface
     * liveness), not whichever conversation is now selected; it also carries
     * the operation's cancellation fence. */
    @Suppress("ReturnCount", "CyclomaticComplexMethod")
    fun stage(owner: Owner, isCurrent: () -> Boolean): Snapshot {
        fun checkOwner() {
            if (Thread.currentThread().isInterrupted || !isCurrent()) throw Failure("ownerChanged")
        }
        checkOwner()
        val ticket = try { channel.open(owner.nativeEpoch, owner.conversationID, owner.runID,
                                        owner.outputID) }
            catch (_: LinkageError) { throw Failure("sourceUnavailable") }
        if (ticket <= 0) throw Failure("sourceRefused:$ticket")
        var directory: File? = null
        var snapshot: Snapshot? = null
        var failure: Throwable? = null
        try {
            checkOwner()
            val info = RunOutputReply.call { channel.info(ticket, it) }
            // EARLIEST typed refusal boundary: a raw claimed byteCount beyond
            // the frozen 256MiB per-file egress cap (mirrors Core
            // RunOutputSnapshotStore safeDefault perFileBytes) is answered
            // with the honest contentTooLarge BEFORE the reply is ever parsed
            // as trusted info. The strict egressInfo gate below still refuses
            // the same over-cap claim as a shape violation for every other
            // consumer, so no oversized payload is staged, read or advertised
            // through any path — this gate only makes the stager's refusal
            // typed instead of folding it into invalidSnapshotInfo.
            val claimedBytes = info.number("byteCount")
            if (claimedBytes != null && claimedBytes > MAX_BYTES) {
                throw Failure("contentTooLarge")
            }
            val facts = RunOutputReply.egressInfo(info, owner.conversationID, owner.runID,
                                                  owner.outputID)
                ?: throw Failure("invalidSnapshotInfo")
            val bytes = facts.byteCount
            if (bytes > MAX_BYTES) throw Failure("contentTooLarge")
            if (bytes < 1) throw Failure("invalidSnapshotInfo")
            val fileExtension = facts.displayName.substringAfterLast('.', "")
                .lowercase(Locale.ROOT)
            if (fileExtension != extensionOf(facts.displayName) ||
                fileExtension !in formats) {
                // extensionOf is the SAME derivation the engine's format
                // detection uses; the second clause is the frozen R1 gate
                // (now against the instance's accepted format set).
                throw Failure("invalidOfficeFormat")
            }
            // PDF identity agreement BEFORE any byte is staged: the native
            // host header's declared MIME must MATCH the sealed extension.
            val wantsPdfProof = fileExtension == FORMAT_PDF
            if (wantsPdfProof && facts.mimeType != PDF_MIME) {
                throw Failure("invalidPdfFormat")
            }
            checkOwner()
            if ((!root.isDirectory && !root.mkdirs()) || Files.isSymbolicLink(root.toPath())) {
                throw Failure("snapshotStorageUnavailable")
            }
            val sessionID = UUID.randomUUID().toString()
            directory = File(root.canonicalFile, sessionID)
            Files.createDirectory(directory.toPath())
            val part = File(directory, "document.part")
            val file = File(directory, "document.$fileExtension")
            val digest = MessageDigest.getInstance("SHA-256")
            var header: ByteArray? = null
            FileChannel.open(part.toPath(), StandardOpenOption.CREATE_NEW,
                             StandardOpenOption.WRITE).use { output ->
                val page = ByteArray(CHUNK_BYTES)
                var offset = 0L
                while (offset < bytes) {
                    checkOwner()
                    val copied = channel.read(ticket, offset, page)
                    if (copied <= 0 || copied > page.size || copied > bytes - offset) {
                        throw Failure("invalidSnapshotChunk:$copied")
                    }
                    checkOwner()
                    if (wantsPdfProof && offset == 0L) {
                        // Capture the FIRST streamed bytes of the actual copy
                        // (never a re-open of anything) for the magic proof.
                        header = page.copyOfRange(0, minOf(copied, PDF_MAGIC.size))
                    }
                    digest.update(page, 0, copied)
                    val buffer = ByteBuffer.wrap(page, 0, copied)
                    while (buffer.hasRemaining()) output.write(buffer)
                    offset += copied
                }
                checkOwner()
                // Exact EOF matters as well as the header's digest/size.
                if (channel.read(ticket, bytes, page) != 0) {
                    throw Failure("snapshotLengthMismatch")
                }
                val actual = digest.digest().joinToString("") { "%02x".format(it) }
                if (actual != facts.sha256) throw Failure("snapshotDigestMismatch")
                // The captured first bytes must BE the magic (a "PDF"
                // shorter than %PDF- fails the equality honestly too), and
                // this runs BEFORE the part is renamed/published.
                if (wantsPdfProof && header?.contentEquals(PDF_MAGIC) != true) {
                    throw Failure("invalidPdfMagic")
                }
                output.force(true)
            }
            checkOwner()
            Files.move(part.toPath(), file.toPath())
            if (!file.setReadOnly()) throw Failure("snapshotProtectionFailed")
            snapshot = Snapshot(sessionID, owner, facts.outputID, facts.displayName,
                                facts.relativePath, facts.mimeType, file, bytes, facts.sha256)
        } catch (error: Throwable) {
            failure = error
        } finally {
            // Close the exact ticket even when the owner retired: this is
            // the lease release, not a new admission.
            try {
                val status = channel.close(ticket)
                if (status != 0) throw Failure("snapshotCloseRefused:$status")
            } catch (error: Throwable) {
                if (failure == null) failure = error else failure.addSuppressed(error)
            }
        }
        try { checkOwner() } catch (error: Throwable) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        if (failure != null) {
            // Only this unexposed, randomly allocated transport directory.
            directory?.listFiles()?.forEach { it.delete() }
            directory?.delete()
            throw failure
        }
        return snapshot ?: throw Failure("snapshotMissing")
    }

    private fun extensionOf(name: String): String =
        name.substringAfterLast('.', "").lowercase(Locale.ROOT)

    companion object {
        const val MAX_BYTES = 256L * 1024 * 1024
        private const val CHUNK_BYTES = 64 * 1024
        const val OFFICE_EXTENSIONS = "docx,xlsx,pptx"

        /** Lane 17: the reviewed OOXML triple stays the DEFAULT accepted set
         * (every existing Office construction is unchanged), while the PDF
         * consumer passes its own single-format set. */
        val OFFICE_FORMAT_EXTENSIONS = setOf("docx", "xlsx", "pptx")
        val PDF_FORMAT_EXTENSIONS = setOf("pdf")

        /** A sealed pdf output is only openable when the native host header
         * declares EXACTLY this MIME for a `.pdf` name (agreement, not OR). */
        const val FORMAT_PDF = "pdf"
        const val PDF_MIME = "application/pdf"

        /** The leading bytes every real PDF document carries (ISO 32000-1
         * Annex H file header identification — the same magic the module's
         * print adapter proves through its pinned descriptor). */
        val PDF_MAGIC: ByteArray = byteArrayOf(
            '%'.code.toByte(), 'P'.code.toByte(), 'D'.code.toByte(),
            'F'.code.toByte(), '-'.code.toByte(),
        )

        fun supportsDisplayName(name: String): Boolean =
            name.substringAfterLast('.', "").lowercase(Locale.ROOT) in setOf("docx", "xlsx", "pptx")

        /** The SAME closed agreement the card gate and the host router use:
         * verified sealed MIME must MATCH the sealed extension. */
        fun pdfOpenAgreement(mimeType: String, displayName: String): Boolean =
            mimeType == PDF_MIME &&
                displayName.substringAfterLast('.', "").lowercase(Locale.ROOT) == FORMAT_PDF
    }
}
