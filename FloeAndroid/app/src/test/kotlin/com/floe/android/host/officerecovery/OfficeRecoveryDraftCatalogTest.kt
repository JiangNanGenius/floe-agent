// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import java.io.File
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored NOTRUN regressions for the C08 owned-content enumeration. Main runs
 * the focused JVM test after the unified build. No device/provider is needed.
 */
class OfficeRecoveryDraftCatalogTest {
    private fun newDir(prefix: String): File = File.createTempFile(prefix, "").let {
        it.delete()
        check(it.mkdirs())
        it
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun docx(extra: ByteArray = byteArrayOf()): ByteArray =
        byteArrayOf(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00) + extra

    private fun candidate(
        workingRoot: File,
        outputRoot: File,
        workingContent: ByteArray? = docx(),
        outputContent: ByteArray? = null,
    ): OfficeRecoveryCandidate {
        val id = UUID.randomUUID().toString()
        val directory = File(workingRoot, id)
        check(directory.mkdirs())
        val working = File(directory, "document.docx")
        if (workingContent != null) working.writeBytes(workingContent)
        var outputPath: String? = null
        var outputSha: String? = null
        var outputBytes = 0L
        if (outputContent != null) {
            val outputDirectory = File(outputRoot, "7")
            check(outputDirectory.mkdirs() || outputDirectory.isDirectory)
            val output = File(outputDirectory, "export-1-1234.docx")
            output.writeBytes(outputContent)
            outputPath = output.absolutePath
            outputSha = sha(outputContent)
            outputBytes = outputContent.size.toLong()
        }
        return OfficeRecoveryCandidate(
            id = id,
            createdAtMillis = 1_700_000_000_000,
            updatedAtMillis = 1_700_000_001_000,
            phase = OfficeRecoveryPhase.EXPORT_READY,
            route = OfficeRecoveryRoute.WORKSPACE,
            displayName = "Quarterly report.docx",
            format = "docx",
            sourceSha256 = sha(docx()),
            sourceBytes = docx().size.toLong(),
            workingCopyPath = working.absolutePath,
            workingCopyBaseSha256 = sha(workingContent ?: docx()),
            workingCopyBaseBytes = (workingContent ?: docx()).size.toLong(),
            outputPath = outputPath,
            outputSha256 = outputSha,
            outputBytes = outputBytes,
            outputFormat = if (outputContent != null) "docx" else null,
            outputOpId = if (outputContent != null) "export-1" else null,
            outputNativeGeneration = if (outputContent != null) 7L else 0L,
        )
    }

    @Test
    fun bothWorkingAndVerifiedCandidatesAreEnumeratedForExactDedupe() {
        val working = newDir("c08-work")
        val outputs = newDir("c08-out")
        val bytes = docx(byteArrayOf(9, 9, 9))
        val journal = OfficeRecoveryJournal(newDir("c08-journal"))
        journal.add(candidate(working, outputs, bytes, bytes))
        val catalog = OfficeRecoveryDraftCatalog(
            journal,
            OfficeRecoveryArtifacts(working, outputs),
            restoredRoot = newDir("c08-restored"),
        )
        val capture = catalog.capture()
        // Both candidates travel; the trusted Swift copy dedupes only after
        // it verifies the exact bytes, so an export race keeps the fallback.
        assertEquals(2, capture.records.size)
        assertEquals(
            setOf(
                OfficeDraftCaptureRecord.Kind.VERIFIED_OUTPUT,
                OfficeDraftCaptureRecord.Kind.WORKING_COPY,
            ),
            capture.records.map { it.kind }.toSet(),
        )
        assertEquals(0, capture.deduplicated)
        assertTrue(capture.omissions.isEmpty())
        val json = capture.toJson()
        assertEquals("floe.office-drafts/1", json.getString("format"))
        val record = json.getJSONArray("records").getJSONObject(0)
        assertFalse(record.has("id"))
        assertFalse(record.has("sessionToken"))
        assertFalse(record.has("destinationUri"))
        assertFalse(record.has("nativeGeneration"))
        assertFalse(record.has("taskId"))
    }

    @Test
    fun changedWorkingBytesAreCarriedAtTheirCurrentDigest() {
        val working = newDir("c08-work")
        val outputs = newDir("c08-out")
        val journal = OfficeRecoveryJournal(newDir("c08-journal"))
        val candidate = candidate(working, outputs, docx())
        journal.add(candidate)
        val changed = docx(byteArrayOf(1, 2, 3, 4, 5))
        File(candidate.workingCopyPath).writeBytes(changed)
        val capture = OfficeRecoveryDraftCatalog(
            journal,
            OfficeRecoveryArtifacts(working, outputs),
            restoredRoot = newDir("c08-restored"),
        ).capture()
        assertEquals(1, capture.records.size)
        assertEquals(sha(changed), capture.records.first().sha256)
        assertEquals(changed.size.toLong(), capture.records.first().bytes)
    }

    @Test
    fun missingAndCorruptSourcesBecomeExplicitOmissions() {
        val working = newDir("c08-work")
        val outputs = newDir("c08-out")
        val journal = OfficeRecoveryJournal(newDir("c08-journal"))
        val missing = candidate(working, outputs, workingContent = null)
        journal.add(missing)
        val corrupt = candidate(working, outputs, docx(byteArrayOf(7)))
        File(corrupt.workingCopyPath).writeBytes("not-an-ooxml-package".toByteArray())
        journal.add(corrupt)
        val capture = OfficeRecoveryDraftCatalog(
            journal,
            OfficeRecoveryArtifacts(working, outputs),
            restoredRoot = newDir("c08-restored"),
        ).capture()
        assertTrue(capture.records.isEmpty())
        val reasons = capture.omissions.map { it.reason }.toSet()
        assertTrue(reasons.contains("missing"))
        assertTrue(reasons.contains("corrupt"))
    }

    @Test
    fun displayNameNeverCarriesALocalPath() {
        val capture = OfficeDraftCapture(
            records = listOf(
                OfficeDraftCaptureRecord(
                    root = OfficeDraftCaptureRecord.Root.WORKING,
                    relativePath = "${UUID.randomUUID()}/document.docx",
                    kind = OfficeDraftCaptureRecord.Kind.WORKING_COPY,
                    displayName = "/Users/alice/secret/report.docx",
                    format = "docx",
                    bytes = 4,
                    sha256 = "a".repeat(64),
                    createdAtMillis = 1,
                    updatedAtMillis = 2,
                ),
            ),
            omissions = emptyList(),
            deduplicated = 0,
        )
        val json = capture.toJson()
        val record = json.getJSONArray("records").getJSONObject(0)
        assertEquals("report.docx", record.getString("displayName"))
        assertFalse(json.toString().contains("Users"))
    }
}
