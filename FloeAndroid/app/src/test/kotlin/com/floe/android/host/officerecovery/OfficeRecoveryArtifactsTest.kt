// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for the ONLY recovery path/ownership decisions. */
class OfficeRecoveryArtifactsTest {

    private fun newDir(prefix: String): File = File.createTempFile(prefix, "").let {
        it.delete()
        check(it.mkdirs())
        it
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun docx(): ByteArray = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00)

    private fun candidate(
        workingRoot: File,
        outputRoot: File,
        workingContent: ByteArray = docx(),
        outputContent: ByteArray = docx(),
        workingPathOverride: String? = null,
    ): OfficeRecoveryCandidate {
        val id = UUID.randomUUID().toString()
        val directory = File(workingRoot, id)
        check(directory.mkdirs())
        val working = File(directory, "document.docx")
        working.writeBytes(workingContent)
        val generation = 7L
        val outputDir = File(outputRoot, generation.toString())
        check(outputDir.mkdirs() || outputDir.isDirectory)
        val output = File(outputDir, "export-1-1234.docx")
        output.writeBytes(outputContent)
        return OfficeRecoveryCandidate(
            id = id,
            createdAtMillis = System.currentTimeMillis(),
            updatedAtMillis = System.currentTimeMillis(),
            phase = OfficeRecoveryPhase.EXPORT_READY,
            route = OfficeRecoveryRoute.WORKSPACE,
            displayName = "Notes.docx",
            format = "docx",
            sourceSha256 = sha(docx()),
            sourceBytes = docx().size.toLong(),
            workingCopyPath = workingPathOverride ?: working.absolutePath,
            workingCopyBaseSha256 = sha(workingContent),
            workingCopyBaseBytes = workingContent.size.toLong(),
            outputPath = output.absolutePath,
            outputSha256 = sha(outputContent),
            outputBytes = outputContent.size.toLong(),
            outputFormat = "docx",
            outputOpId = "export-1",
            outputNativeGeneration = generation,
        )
    }

    @Test
    fun validWorkingCopyIsMeasuredAndChangedBytesAreNotCorruption() {
        val workingRoot = newDir("artifacts-work")
        val outputRoot = newDir("artifacts-out")
        val candidate = candidate(workingRoot, outputRoot)
        val artifacts = OfficeRecoveryArtifacts(workingRoot, outputRoot)

        val facts = artifacts.inspectWorkingCopy(candidate)
        assertEquals(OfficeRecoveryFileState.AVAILABLE, facts.state)
        assertFalse(facts.changedSinceBase)

        // The module may legitimately write the mutable working copy. A valid
        // OOXML-shaped file with a different digest is "changed", not corrupt.
        val changed = docx() + byteArrayOf(1, 2, 3, 4)
        File(candidate.workingCopyPath).writeBytes(changed)
        val after = artifacts.inspectWorkingCopy(candidate)
        assertEquals(OfficeRecoveryFileState.AVAILABLE, after.state)
        assertTrue(after.changedSinceBase)
        assertEquals(sha(changed), after.sha256)
    }

    @Test
    fun missingCorruptAndUntrustedWorkingCopiesAreReported() {
        val workingRoot = newDir("artifacts-missing")
        val outputRoot = newDir("artifacts-missing-out")
        val candidate = candidate(workingRoot, outputRoot)
        val artifacts = OfficeRecoveryArtifacts(workingRoot, outputRoot)

        File(candidate.workingCopyPath).delete()
        assertEquals(OfficeRecoveryFileState.MISSING, artifacts.inspectWorkingCopy(candidate).state)

        File(candidate.workingCopyPath).writeBytes("not an ooxml file".toByteArray())
        assertEquals(OfficeRecoveryFileState.CORRUPT, artifacts.inspectWorkingCopy(candidate).state)

        val outside = File(workingRoot.parentFile, "outside-${UUID.randomUUID()}.docx")
        outside.writeBytes(docx())
        val outsideCandidate = candidate.copy(workingCopyPath = outside.absolutePath)
        assertEquals(OfficeRecoveryFileState.UNTRUSTED, artifacts.inspectWorkingCopy(outsideCandidate).state)
        outside.delete()
    }

    @Test
    fun symlinkedWorkingCopyIsNeverAccepted() {
        val workingRoot = newDir("artifacts-symlink")
        val outputRoot = newDir("artifacts-symlink-out")
        val candidate = candidate(workingRoot, outputRoot)
        val real = File(workingRoot, "real.docx")
        real.writeBytes(docx())
        Files.delete(File(candidate.workingCopyPath).toPath())
        Files.createSymbolicLink(
            File(candidate.workingCopyPath).toPath(),
            real.toPath(),
        )
        val artifacts = OfficeRecoveryArtifacts(workingRoot, outputRoot)
        assertEquals(OfficeRecoveryFileState.UNTRUSTED, artifacts.inspectWorkingCopy(candidate).state)
    }

    @Test
    fun verifiedOutputRequiresExactRecordedDigestAndLength() {
        val workingRoot = newDir("artifacts-output")
        val outputRoot = newDir("artifacts-output-out")
        val candidate = candidate(workingRoot, outputRoot)
        val artifacts = OfficeRecoveryArtifacts(workingRoot, outputRoot)
        assertEquals(OfficeRecoveryFileState.AVAILABLE, artifacts.inspectOutput(candidate).state)

        File(candidate.outputPath!!).writeBytes(docx() + byteArrayOf(9))
        assertEquals(OfficeRecoveryFileState.CORRUPT, artifacts.inspectOutput(candidate).state)

        File(candidate.outputPath!!).writeBytes(docx())
        assertEquals(OfficeRecoveryFileState.AVAILABLE, artifacts.inspectOutput(candidate).state)
        assertEquals(
            OfficeRecoveryFileState.CORRUPT,
            artifacts.inspectOutput(candidate.copy(outputSha256 = "0".repeat(64))).state,
        )
    }

    @Test
    fun deleteOwnedRemovesOnlyItsExactArtifacts() {
        val workingRoot = newDir("artifacts-delete")
        val outputRoot = newDir("artifacts-delete-out")
        val candidate = candidate(workingRoot, outputRoot)
        val unrelated = File(File(candidate.outputPath!!).parentFile, "other-1-999.docx")
        unrelated.writeBytes(docx())
        val outside = File(outputRoot.parentFile, "outside-${UUID.randomUUID()}.docx")
        outside.writeBytes(docx())
        val artifacts = OfficeRecoveryArtifacts(workingRoot, outputRoot)

        assertTrue(artifacts.deleteOwned(candidate))
        assertFalse(File(candidate.workingCopyPath).exists())
        assertFalse(File(candidate.workingCopyPath).parentFile.exists())
        assertFalse(File(candidate.outputPath!!).exists())
        assertTrue(unrelated.exists())
        assertTrue(outside.exists())
        outside.delete()
    }

    @Test
    fun untrustedPathsAreNeverDeleted() {
        val workingRoot = newDir("artifacts-untrusted")
        val outputRoot = newDir("artifacts-untrusted-out")
        val outside = File(workingRoot.parentFile, "outside-${UUID.randomUUID()}.docx")
        outside.writeBytes(docx())
        val candidate = candidate(workingRoot, outputRoot).copy(workingCopyPath = outside.absolutePath)
        val artifacts = OfficeRecoveryArtifacts(workingRoot, outputRoot)
        assertTrue(artifacts.deleteOwned(candidate))
        assertTrue(outside.exists())
        outside.delete()
    }
}
