// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import com.floe.android.core.officeengine.OfficeRequestPolicy
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import java.io.File

/**
 * The EXACT proof gate between one OUTPUT_READY receipt and any local PDF
 * surface (preview, print, or the renderer itself). Nothing here opens a
 * picker, saves anything for the user, clears dirty state or deletes files:
 * it only decides whether the receipt's claims are TRUE against the real
 * bytes, and returns the verified snapshot to open.
 *
 * Every error is an enum value — never a path, message or engine detail —
 * so ordinary UI can stay path-free (Main UI contract; technical detail
 * belongs only to the diagnostics view).
 */
enum class OfficePdfOpenError {
    /** Receipt not for this exact op (unknown opId, already-consumed op, stale or duplicate terminal). */
    FOREIGN_OP,

    /** Receipt session token or mount generation is not the live one. */
    STALE_SESSION,

    /** Receipt is not an OUTPUT_READY STAGED_EXPORT of format pdf. */
    NOT_PDF_OUTPUT,

    /** Receipt carries no canonical path / digest / size claims. */
    MISSING_PROOF,

    /** The claimed path escapes the module's owned outputs root for this generation. */
    PATH_ESCAPE,

    /** The claimed path is not a plain regular canonical file, or the name does not belong to this op. */
    PATH_NOT_MINE,

    /** Re-reading the file: missing / not a regular file / unreadable. */
    FILE_GONE,

    /** File length disagrees with the receipt (bounded 1..256 MiB rules included). */
    LENGTH_MISMATCH,

    /** Whole-file SHA-256 disagrees with the receipt, or the leading bytes are not %PDF-. */
    DIGEST_MISMATCH,
}

/**
 * A PDF artifact this module verified WITH ITS OWN EYES after the receipt.
 * It is one concrete [OfficePdfVerifiedSource]: Office identity fields
 * (opId/generation) stay for the viewer ledger; the renderer family consumes
 * it through the shared source contract (readableFile/expectedSha256/
 * expectedBytes) so a future sealed run-output consumer can bind the SAME
 * renderer with its own verifier — never a second renderer.
 */
data class VerifiedPdfSnapshot(
    /** Canonical regular file inside the module-owned outputs root. */
    val file: File,
    /** 64 lowercase hex — recomputed here, not merely echoed from the receipt. */
    val sha256: String,
    /** Positive bounded length, re-measured here. */
    val lengthBytes: Long,
    /** The exact op this snapshot belongs to (retention + diagnostics identity). */
    val opId: String,
    /** The exact native generation that produced it. */
    val generation: Long,
) : OfficePdfVerifiedSource {
    override val readableFile: java.io.File get() = file
    override val expectedSha256: String get() = sha256
    override val expectedBytes: Long get() = lengthBytes
}

object OfficePdfReceiptPolicy {

    private val SHA256_REGEX = Regex("^[0-9a-f]{64}$")

    /** Directory name the pinned engine service stages verified outputs under (kept in sync by design; the SERVICE owns it — this only READS the layout it already publishes to receipts). */
    const val OUTPUTS_DIR_NAME = "floe-office-outputs"

    /**
     * Pure receipt-shape fence: the receipt must describe THIS exact op for
     * THIS exact live session/generation and be a verified PDF export.
     * The attestation substring mirrors the service's pinned proof string
     * ("jni-saveas-sync+output-verified"); a receipt that does not carry its
     * own proof identity is refused fail-closed.
     */
    fun fenceReceipt(
        receipt: OfficeSaveReceipt,
        expectedOpId: String,
        expectedSessionToken: String,
        expectedGeneration: Long,
    ): OfficePdfOpenError? {
        if (receipt.opId != expectedOpId) return OfficePdfOpenError.FOREIGN_OP
        if (receipt.sessionToken != expectedSessionToken) return OfficePdfOpenError.STALE_SESSION
        if (receipt.generation != expectedGeneration) return OfficePdfOpenError.STALE_SESSION
        if (receipt.state != OfficeSaveState.OUTPUT_READY ||
            receipt.operation.name != "STAGED_EXPORT" ||
            receipt.format?.lowercase(java.util.Locale.ROOT) != "pdf"
        ) {
            return OfficePdfOpenError.NOT_PDF_OUTPUT
        }
        val path = receipt.outputDocumentPath
        val sha = receipt.outputSha256
        val bytes = receipt.outputBytes
        if (path.isNullOrBlank() || sha == null || !SHA256_REGEX.matches(sha) ||
            bytes <= 0L || bytes > OfficeRequestPolicy.MAX_STAGED_BYTES
        ) {
            return OfficePdfOpenError.MISSING_PROOF
        }
        if (!receipt.attestation.contains("output-verified")) return OfficePdfOpenError.MISSING_PROOF
        return null
    }

    /**
     * Canonical containment in the module-owned outputs root for THIS
     * generation: the file must be a plain regular canonical file directly
     * inside `<noBackupFilesDir>/floe-office-outputs/<generation>/`, named
     * `<opId>-…pdf`, and must not be a symlink. [expectedOpId] is the exact
     * op that produced the receipt — a foreign staged file can never be
     * opened even when its bytes digest correctly.
     */
    fun resolveOwnedOutput(
        appNoBackupDir: File,
        generation: Long,
        expectedOpId: String,
        claimedCanonicalPath: String,
    ): Pair<File?, OfficePdfOpenError?> {
        if (generation < 1L || expectedOpId.isBlank()) return null to OfficePdfOpenError.PATH_ESCAPE
        val claimed = File(claimedCanonicalPath)
        val canonical = runCatching { claimed.canonicalFile }.getOrNull()
            ?: return null to OfficePdfOpenError.FILE_GONE
        val canonicalNoBackup = runCatching { appNoBackupDir.canonicalFile }.getOrNull()
            ?: return null to OfficePdfOpenError.FILE_GONE
        val root = File(canonicalNoBackup, "$OUTPUTS_DIR_NAME/$generation")
        if (canonical.parentFile != root) return null to OfficePdfOpenError.PATH_ESCAPE
        val name = canonical.name
        if (!name.startsWith("$expectedOpId-") || !name.endsWith(".pdf")) {
            return null to OfficePdfOpenError.PATH_NOT_MINE
        }
        if (!canonical.isFile) return null to OfficePdfOpenError.FILE_GONE
        if (claimed.absolutePath != canonical.path) {
            // Symlink or non-canonical claim: only the canonical identity is ours.
            return null to OfficePdfOpenError.PATH_NOT_MINE
        }
        return canonical to null
    }

    /**
     * Re-prove the bytes with the pinned module verifier and compare against
     * the receipt's claims. Uses [OfficeRequestPolicy.verifyStagedOutput] —
     * the same regular-file / 1..256 MiB / %PDF- magic / whole-read SHA rules
     * the engine used for OUTPUT_READY — never a weaker local check.
     */
    fun proveBytes(file: File, claimedSha256: String, claimedBytes: Long): OfficePdfOpenError? {
        if (!file.isFile || !file.canRead()) return OfficePdfOpenError.FILE_GONE
        val length = file.length()
        if (length <= 0L) return OfficePdfOpenError.FILE_GONE
        if (length != claimedBytes) return OfficePdfOpenError.LENGTH_MISMATCH
        val proof = OfficeRequestPolicy.verifyStagedOutput(file, "pdf")
        if (!proof.verified) {
            return when (proof.failure) {
                com.floe.android.core.officeengine.OfficeSaveFailureCode.OUTPUT_TOO_LARGE ->
                    OfficePdfOpenError.LENGTH_MISMATCH
                com.floe.android.core.officeengine.OfficeSaveFailureCode.OUTPUT_MISSING,
                com.floe.android.core.officeengine.OfficeSaveFailureCode.OUTPUT_EMPTY,
                com.floe.android.core.officeengine.OfficeSaveFailureCode.OUTPUT_UNREADABLE,
                -> OfficePdfOpenError.FILE_GONE
                else -> OfficePdfOpenError.DIGEST_MISMATCH
            }
        }
        if (proof.sha256 != claimedSha256 || proof.bytes != claimedBytes) {
            return OfficePdfOpenError.DIGEST_MISMATCH
        }
        return null
    }

    /**
     * Full receipt-to-snapshot open proof. [liveSessionToken]/[liveGeneration]
     * must be the CURRENT mount identity at the moment of opening; [opId]
     * must already have been consumed FROM THE PURPOSE LEDGER by the caller
     * (this function never touches the ledger).
     */
    fun openFromReceipt(
        receipt: OfficeSaveReceipt,
        appNoBackupDir: File,
        liveSessionToken: String,
        liveGeneration: Long,
        expectedOpId: String,
    ): Pair<VerifiedPdfSnapshot?, OfficePdfOpenError?> {
        fenceReceipt(receipt, expectedOpId, liveSessionToken, liveGeneration)?.let { return null to it }
        val path = receipt.outputDocumentPath!!
        val (file, pathError) = resolveOwnedOutput(appNoBackupDir, receipt.generation, expectedOpId, path)
        if (file == null) return null to (pathError ?: OfficePdfOpenError.FILE_GONE)
        proveBytes(file, receipt.outputSha256!!, receipt.outputBytes)?.let { return null to it }
        return VerifiedPdfSnapshot(
            file = file,
            sha256 = receipt.outputSha256!!,
            lengthBytes = receipt.outputBytes,
            opId = receipt.opId,
            generation = receipt.generation,
        ) to null
    }
}
