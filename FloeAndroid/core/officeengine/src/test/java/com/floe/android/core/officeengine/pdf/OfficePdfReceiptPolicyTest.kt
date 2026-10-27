// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * Contract regression for the receipt-to-snapshot open proof: ONLY the exact
 * owned op's OUTPUT_READY STAGED_EXPORT pdf receipt, whose claims re-verify
 * against the REAL bytes inside this app's owned outputs root, may open a
 * local PDF surface. Stale sessions, foreign ops, path escapes, symlinked
 * claims, truncated/tampered bytes and attestation-less receipts each get
 * their named, path-free refusal.
 */
class OfficePdfReceiptPolicyTest {

    private val sha = sha256Of(PDF_BODY)

    private fun makeRoot(): File {
        val base = File(System.getProperty("java.io.tmpdir"), "pdfpolicy-${System.nanoTime()}")
        base.mkdirs()
        return base.canonicalFile
    }

    private fun stageOutput(root: File, generation: Long, opId: String, name: String, body: ByteArray): File {
        val dir = File(File(root, OfficePdfReceiptPolicy.OUTPUTS_DIR_NAME), generation.toString())
        dir.mkdirs()
        val f = File(dir, name)
        f.writeBytes(body)
        return f
    }

    private fun receipt(
        opId: String = "export-1",
        token: String = "tok-1",
        generation: Long = 7L,
        state: OfficeSaveState = OfficeSaveState.OUTPUT_READY,
        operation: OfficeSaveOperation = OfficeSaveOperation.STAGED_EXPORT,
        format: String? = "pdf",
        path: String? = null,
        sha256: String? = sha,
        bytes: Long = PDF_BODY.size.toLong(),
        attestation: String = "jni-saveas-sync+output-verified",
    ) = OfficeSaveReceipt(
        opId = opId,
        sessionToken = token,
        generation = generation,
        operation = operation,
        state = state,
        format = format,
        suggestedName = "doc.pdf",
        expectedBaseSha256 = null,
        workingCopySha256 = null,
        workingCopyBytes = 0L,
        outputDocumentPath = path,
        outputSha256 = sha256,
        outputBytes = bytes,
        failure = null,
        message = null,
        cancelRequested = false,
        attestation = attestation,
        submittedAtElapsedMs = 0L,
        completedAtElapsedMs = 1L,
    )

    // ---- fenceReceipt: pure identity/shape rules -------------------------

    @Test
    fun fenceRejectsForeignOpAndStaleSession() {
        val good = receipt(path = "/x")
        assertEquals(OfficePdfOpenError.FOREIGN_OP, OfficePdfReceiptPolicy.fenceReceipt(good, "other-op", "tok-1", 7L))
        assertEquals(OfficePdfOpenError.STALE_SESSION, OfficePdfReceiptPolicy.fenceReceipt(good, "export-1", "tok-2", 7L))
        assertEquals(OfficePdfOpenError.STALE_SESSION, OfficePdfReceiptPolicy.fenceReceipt(good, "export-1", "tok-1", 8L))
        assertNull(OfficePdfReceiptPolicy.fenceReceipt(good, "export-1", "tok-1", 7L))
    }

    @Test
    fun fenceRequiresPdfOutputReady() {
        val path = "/x"
        assertEquals(
            OfficePdfOpenError.NOT_PDF_OUTPUT,
            OfficePdfReceiptPolicy.fenceReceipt(receipt(state = OfficeSaveState.FLUSHED, path = path), "export-1", "tok-1", 7L),
        )
        assertEquals(
            OfficePdfOpenError.NOT_PDF_OUTPUT,
            OfficePdfReceiptPolicy.fenceReceipt(receipt(format = "docx", path = path), "export-1", "tok-1", 7L),
        )
        assertEquals(
            OfficePdfOpenError.NOT_PDF_OUTPUT,
            OfficePdfReceiptPolicy.fenceReceipt(
                receipt(operation = OfficeSaveOperation.WORKING_COPY_FLUSH, format = null, path = path),
                "export-1", "tok-1", 7L,
            ),
        )
    }

    @Test
    fun fenceRefusesMissingOrInvalidProofClaims() {
        assertEquals(
            OfficePdfOpenError.MISSING_PROOF,
            OfficePdfReceiptPolicy.fenceReceipt(receipt(path = null), "export-1", "tok-1", 7L),
        )
        assertEquals(
            OfficePdfOpenError.MISSING_PROOF,
            OfficePdfReceiptPolicy.fenceReceipt(receipt(path = "/x", sha256 = "ABCDEF"), "export-1", "tok-1", 7L),
        )
        assertEquals(
            OfficePdfOpenError.MISSING_PROOF,
            OfficePdfReceiptPolicy.fenceReceipt(receipt(path = "/x", bytes = 0L), "export-1", "tok-1", 7L),
        )
        assertEquals(
            OfficePdfOpenError.MISSING_PROOF,
            OfficePdfReceiptPolicy.fenceReceipt(receipt(path = "/x", attestation = "cancel-before-dispatch"), "export-1", "tok-1", 7L),
        )
    }

    // ---- resolveOwnedOutput: containment + identity on real files --------

    @Test
    fun resolvesCanonicalOwnedOutput() {
        val root = makeRoot()
        val f = stageOutput(root, 7L, "export-1", "export-1-123.pdf", PDF_BODY)
        val (file, error) = OfficePdfReceiptPolicy.resolveOwnedOutput(root, 7L, "export-1", f.canonicalFile.path)
        assertNull(error)
        assertNotNull(file)
        assertEquals(f.canonicalFile.path, file!!.path)
    }

    @Test
    fun refusesEscapesWrongGenerationAndForeignNames() {
        val root = makeRoot()
        val outside = File(root, "somewhere-else.pdf").apply { writeBytes(PDF_BODY) }
        val (f1, e1) = OfficePdfReceiptPolicy.resolveOwnedOutput(root, 7L, "export-1", outside.canonicalFile.path)
        assertNull(f1)
        assertEquals(OfficePdfOpenError.PATH_ESCAPE, e1)

        val wrongGen = stageOutput(root, 9L, "export-1", "export-1-1.pdf", PDF_BODY)
        val (f2, e2) = OfficePdfReceiptPolicy.resolveOwnedOutput(root, 7L, "export-1", wrongGen.canonicalFile.path)
        assertNull(f2)
        assertEquals(OfficePdfOpenError.PATH_ESCAPE, e2)

        val foreignName = stageOutput(root, 7L, "export-1", "export-OTHER-1.pdf", PDF_BODY)
        val (f3, e3) = OfficePdfReceiptPolicy.resolveOwnedOutput(root, 7L, "export-1", foreignName.canonicalFile.path)
        assertNull(f3)
        assertEquals(OfficePdfOpenError.PATH_NOT_MINE, e3)

        val wrongExt = stageOutput(root, 7L, "export-1", "export-1-1.pdfx", PDF_BODY)
        val (f4, e4) = OfficePdfReceiptPolicy.resolveOwnedOutput(root, 7L, "export-1", wrongExt.canonicalFile.path)
        assertNull(f4)
        assertEquals(OfficePdfOpenError.PATH_NOT_MINE, e4)
    }

    @Test
    fun refusesSymlinkedClaimEvenWhenTargetIsOurs() {
        val root = makeRoot()
        val real = stageOutput(root, 7L, "export-1", "export-1-real.pdf", PDF_BODY)
        val link = File(real.parentFile, "export-1-link.pdf")
        java.nio.file.Files.createSymbolicLink(link.toPath(), real.toPath())
        val (file, error) = OfficePdfReceiptPolicy.resolveOwnedOutput(root, 7L, "export-1", link.path)
        assertNull(file)
        assertEquals(OfficePdfOpenError.PATH_NOT_MINE, error)
    }

    // ---- proveBytes: re-hash the REAL file, compare to the claims --------

    @Test
    fun proveBytesDetectsTruncationTamperAndNonMagic() {
        val root = makeRoot()
        val good = stageOutput(root, 7L, "export-1", "export-1-a.pdf", PDF_BODY)
        assertNull(OfficePdfReceiptPolicy.proveBytes(good, sha, PDF_BODY.size.toLong()))

        val tamperedSameLen = stageOutput(root, 7L, "export-1", "export-1-b.pdf", "%PDF-X".toByteArray() + PDF_BODY.copyOfRange(5, PDF_BODY.size))
        // The claim under test is the RECEIPT's original digest: proving the
        // re-hash of the REAL bytes detects tampering means comparing the
        // recomputed digest against `sha`, never against the tampered file's
        // own digest (a self-consistent claim could not mismatch).
        assertEquals(OfficePdfOpenError.DIGEST_MISMATCH, OfficePdfReceiptPolicy.proveBytes(tamperedSameLen, sha, tamperedSameLen.length()))

        val claimedWrong = stageOutput(root, 7L, "export-1", "export-1-c.pdf", PDF_BODY)
        assertEquals(OfficePdfOpenError.LENGTH_MISMATCH, OfficePdfReceiptPolicy.proveBytes(claimedWrong, sha, PDF_BODY.size.toLong() + 1L))

        val noMagicButDigestMatches = stageOutput(root, 7L, "export-1", "export-1-d.pdf", ("JUNK-" + "%PDF-tail").toByteArray(Charsets.US_ASCII))
        val junkSha = sha256Of(noMagicButDigestMatches.readBytes())
        assertEquals(OfficePdfOpenError.DIGEST_MISMATCH, OfficePdfReceiptPolicy.proveBytes(noMagicButDigestMatches, junkSha, noMagicButDigestMatches.length()))

        val missing = File(root, "absent.pdf")
        assertEquals(OfficePdfOpenError.FILE_GONE, OfficePdfReceiptPolicy.proveBytes(missing, sha, 1L))
    }

    // ---- openFromReceipt: the full owned-receipt -> snapshot path --------

    @Test
    fun openFromReceiptEndToEnd() {
        val root = makeRoot()
        val f = stageOutput(root, 7L, "export-1", "export-1-99.pdf", PDF_BODY)
        val (snapshot, error) = OfficePdfReceiptPolicy.openFromReceipt(
            receipt(path = f.canonicalFile.path), root, "tok-1", 7L, "export-1",
        )
        assertNull(error)
        assertNotNull(snapshot)
        assertEquals(f.canonicalFile.path, snapshot!!.file.path)
        assertEquals(sha, snapshot.sha256)
        assertEquals(PDF_BODY.size.toLong(), snapshot.lengthBytes)
        assertEquals("export-1", snapshot.opId)
        assertEquals(7L, snapshot.generation)
    }

    @Test
    fun openFromReceiptRefusesEveryBrokenShape() {
        val root = makeRoot()
        val f = stageOutput(root, 7L, "export-1", "export-1-99.pdf", PDF_BODY)
        // stale generation on the live side
        assertNotNull(OfficePdfReceiptPolicy.openFromReceipt(receipt(path = f.path), root, "tok-1", 6L, "export-1").second)
        // foreign op
        assertNotNull(OfficePdfReceiptPolicy.openFromReceipt(receipt(path = f.path), root, "tok-1", 7L, "export-2").second)
        // wrong claimed digest (bytes are fine, proof disagrees)
        assertNotNull(OfficePdfReceiptPolicy.openFromReceipt(
            receipt(path = f.path, sha256 = "0".repeat(64)), root, "tok-1", 7L, "export-1",
        ).second)
        // missing file at open time
        f.delete()
        val (snap2, err2) = OfficePdfReceiptPolicy.openFromReceipt(receipt(path = f.path), root, "tok-1", 7L, "export-1")
        assertNull(snap2)
        assertTrue(err2 == OfficePdfOpenError.FILE_GONE || err2 == OfficePdfOpenError.PATH_ESCAPE)
    }

    private companion object {
        val PDF_BODY: ByteArray =
            ("%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n").toByteArray(Charsets.US_ASCII)

        fun sha256Of(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
