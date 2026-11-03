// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import java.io.File
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic JVM tests for the durable recovery journal. They exercise
 * atomic round-trip facts, corrupt/oversize preservation, bounded retention
 * vetoes, and the exact transitions the Save-Copy host performs. No Android
 * framework type is used.
 */
class OfficeRecoveryJournalTest {

    private fun newDir(prefix: String): File = File.createTempFile(prefix, "").let {
        it.delete()
        check(it.mkdirs())
        it
    }

    private fun hex(char: Char): String = char.toString().repeat(64)

    private fun candidate(
        root: File,
        id: String = UUID.randomUUID().toString(),
        phase: OfficeRecoveryPhase = OfficeRecoveryPhase.EDITING,
        updatedAt: Long = System.currentTimeMillis(),
        output: Boolean = false,
    ): OfficeRecoveryCandidate {
        val working = File(root, "$id/document.docx")
        return OfficeRecoveryCandidate(
            id = id,
            createdAtMillis = updatedAt,
            updatedAtMillis = updatedAt,
            phase = phase,
            route = OfficeRecoveryRoute.WORKSPACE,
            displayName = "Notes.docx",
            format = "docx",
            ownerTaskId = UUID.randomUUID().toString(),
            workspaceId = UUID.randomUUID().toString(),
            nativeEpoch = "3",
            hostGeneration = "4",
            sourceLogicalPath = "docs/Notes.docx",
            sourceId = "source-id",
            sourceRevision = "rev-1",
            sourceSha256 = hex('a'),
            sourceBytes = 4L,
            workingCopyPath = working.absolutePath,
            workingCopyBaseSha256 = hex('b'),
            workingCopyBaseBytes = 4L,
            outputPath = if (output) File(root, "7/export-1-9.docx").absolutePath else null,
            outputSha256 = if (output) hex('c') else null,
            outputBytes = if (output) 4L else 0L,
            outputFormat = if (output) "docx" else null,
            outputOpId = if (output) "export-1" else null,
            outputNativeGeneration = if (output) 7L else 0L,
        )
    }

    private fun receipt(path: String, sha: String = hex('c')): OfficeSaveReceipt = OfficeSaveReceipt(
        opId = "export-1",
        sessionToken = "session",
        generation = 7L,
        operation = OfficeSaveOperation.STAGED_EXPORT,
        state = OfficeSaveState.OUTPUT_READY,
        format = "docx",
        suggestedName = "Notes.docx",
        expectedBaseSha256 = hex('b'),
        workingCopySha256 = null,
        workingCopyBytes = 0L,
        outputDocumentPath = path,
        outputSha256 = sha,
        outputBytes = 4L,
        failure = null,
        message = null,
        cancelRequested = false,
        attestation = "test",
        submittedAtElapsedMs = 1L,
        completedAtElapsedMs = 2L,
    )

    @Test
    fun roundTripPreservesExactFacts() {
        val root = newDir("recovery-journal")
        val workingRoot = newDir("recovery-work")
        val outputsRoot = newDir("recovery-out")
        val candidate = candidate(workingRoot, output = true)
        val journal = OfficeRecoveryJournal(root)
        journal.add(candidate)

        val reloaded = OfficeRecoveryJournal(root).snapshot()
        assertEquals(1, reloaded.size)
        val fact = reloaded.single()
        assertEquals(candidate.id, fact.id)
        assertEquals(candidate.phase, fact.phase)
        assertEquals(candidate.route, fact.route)
        assertEquals(candidate.ownerTaskId, fact.ownerTaskId)
        assertEquals(candidate.sourceRevision, fact.sourceRevision)
        assertEquals(candidate.workingCopyPath, fact.workingCopyPath)
        assertEquals(candidate.outputPath, fact.outputPath)
        assertEquals(candidate.outputOpId, fact.outputOpId)
        assertEquals(candidate.outputNativeGeneration, fact.outputNativeGeneration)
        assertNull(journal.loadDiagnostic)
    }

    @Test
    fun corruptJournalIsPreservedAndValidEntriesSurvive() {
        val root = newDir("recovery-corrupt")
        val workingRoot = newDir("recovery-corrupt-work")
        val journal = OfficeRecoveryJournal(root)
        val candidate = candidate(workingRoot)
        journal.add(candidate)
        val file = File(root, "recovery-journal.json")
        val json = JSONObject(file.readText())
        json.getJSONArray("candidates").put(JSONObject().put("id", "not-a-real-record"))
        file.writeText(json.toString())

        val reloaded = OfficeRecoveryJournal(root)
        val entries = reloaded.snapshot()
        assertEquals(1, entries.size)
        assertEquals(candidate.id, entries.single().id)
        assertNotNull(reloaded.loadDiagnostic)
        assertTrue(
            root.listFiles()?.any { it.name.startsWith("recovery-journal.corrupt-") } == true,
        )
    }

    @Test
    fun oversizeJournalIsQuarantinedNotRead() {
        val root = newDir("recovery-oversize")
        File(root, "recovery-journal.json").writeText("x".repeat(600 * 1024))
        val journal = OfficeRecoveryJournal(root)
        assertTrue(journal.snapshot().isEmpty())
        assertEquals("journal-oversize", journal.loadDiagnostic)
        assertTrue(
            root.listFiles()?.any { it.name.startsWith("recovery-journal.oversize-") } == true,
        )
    }

    @Test
    fun outputReadyAndTransferFactsAreDurableBeforeSettlement() {
        val root = newDir("recovery-transitions")
        val workingRoot = newDir("recovery-transitions-work")
        val outputsRoot = newDir("recovery-transitions-out")
        val journal = OfficeRecoveryJournal(root)
        val candidate = candidate(workingRoot)
        journal.add(candidate)

        val output = File(outputsRoot, "7/export-1-9.docx").absolutePath
        assertTrue(journal.recordOutputReady(candidate.id, receipt(output)))
        var fact = journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.EXPORT_READY, fact.phase)
        assertEquals(output, fact.outputPath)
        assertEquals(hex('c'), fact.outputSha256)
        assertFalse(fact.destinationVerified)

        assertTrue(journal.markTransferStarted(candidate.id, "export-1", "content://provider/doc/9"))
        fact = journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.TRANSFERRING, fact.phase)
        assertEquals("content://provider/doc/9", fact.destinationUri)
        assertEquals(1, fact.attemptCount)
        assertEquals(OfficeRecoveryPhase.TRANSFERRING, OfficeRecoveryJournal(root).candidate(candidate.id)!!.phase)

        journal.settleSave(
            candidate.id,
            "export-1",
            OfficeRecoverySaveFacts(
                saved = false,
                uncertain = true,
                code = "provider-io",
                destinationUri = "content://provider/doc/9",
                destinationSha256 = null,
                destinationBytes = 0L,
            ),
        )
        fact = OfficeRecoveryJournal(root).candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.UNCERTAIN, fact.phase)
        assertFalse(fact.destinationVerified)
        assertEquals("provider-io", fact.lastErrorCode)
    }

    @Test
    fun verifiedSaveIsTheOnlyStateThatClearsUncertainty() {
        val root = newDir("recovery-saved")
        val workingRoot = newDir("recovery-saved-work")
        val journal = OfficeRecoveryJournal(root)
        val candidate = candidate(workingRoot)
        journal.add(candidate)
        journal.settleSave(
            candidate.id,
            "export-1",
            OfficeRecoverySaveFacts(
                saved = true,
                uncertain = false,
                code = null,
                destinationUri = "content://provider/doc/9",
                destinationSha256 = hex('d'),
                destinationBytes = 4L,
            ),
        )
        val fact = journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.SAVED, fact.phase)
        assertTrue(fact.destinationVerified)
        assertEquals(hex('d'), fact.destinationSha256)
        assertEquals(4L, fact.destinationBytes)
    }

    @Test
    fun failedPreWriteAttemptReturnsToExportReady() {
        val root = newDir("recovery-failed")
        val workingRoot = newDir("recovery-failed-work")
        val journal = OfficeRecoveryJournal(root)
        val candidate = candidate(workingRoot)
        journal.add(candidate)
        journal.recordOutputReady(candidate.id, receipt(File(workingRoot, "7/export-1-9.docx").absolutePath))
        journal.markTransferStarted(candidate.id, "export-1", "content://provider/doc/9")
        journal.settleSave(
            candidate.id,
            "export-1",
            OfficeRecoverySaveFacts(
                saved = false,
                uncertain = false,
                code = "open-unsupported",
                destinationUri = null,
                destinationSha256 = null,
                destinationBytes = 0L,
            ),
        )
        val fact = journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.EXPORT_READY, fact.phase)
        assertFalse(fact.destinationVerified)
        assertEquals("open-unsupported", fact.lastErrorCode)
    }

    @Test
    fun viewerCloseFactsNeverUpgradeAnUnprovenState() {
        val root = newDir("recovery-close")
        val workingRoot = newDir("recovery-close-work")
        val journal = OfficeRecoveryJournal(root)
        val editing = candidate(workingRoot)
        val unsaved = candidate(workingRoot)
        val clean = candidate(workingRoot)
        journal.add(editing)
        journal.add(unsaved)
        journal.add(clean)
        journal.markViewerClosed(editing.id, resultPresent = false, closedCleanly = false, dirtyAtClose = false, discarded = false)
        journal.markViewerClosed(unsaved.id, resultPresent = true, closedCleanly = true, dirtyAtClose = true, discarded = false)
        journal.markViewerClosed(clean.id, resultPresent = true, closedCleanly = true, dirtyAtClose = false, discarded = false)
        assertEquals(OfficeRecoveryPhase.EDITING, journal.candidate(editing.id)!!.phase)
        assertEquals(OfficeRecoveryPhase.CLOSED_UNSAVED, journal.candidate(unsaved.id)!!.phase)
        assertEquals(OfficeRecoveryPhase.CLOSED_CLEAN, journal.candidate(clean.id)!!.phase)
    }

    @Test
    fun savedCloseDoesNotInventLaterWorkingBytesWithoutByteAccess() {
        val root = newDir("recovery-post-save")
        val workingRoot = newDir("recovery-post-save-work")
        val journal = OfficeRecoveryJournal(root)
        val candidate = candidate(workingRoot).copy(
            phase = OfficeRecoveryPhase.SAVED,
            destinationVerified = true,
            workingCopyBaseSha256 = hex('d'),
            savedWorkingCopySha256 = hex('b'),
        )
        journal.add(candidate)
        journal.markViewerClosed(
            candidate.id,
            resultPresent = true,
            closedCleanly = true,
            dirtyAtClose = true,
            discarded = false,
        )
        val fact = journal.candidate(candidate.id)!!
        // The controller measures the real working copy against the verified
        // output digest; the journal must not certify or invent later bytes.
        assertEquals(OfficeRecoveryPhase.SAVED, fact.phase)
        assertTrue(fact.destinationVerified)
    }

    @Test
    fun savedCloseWithNoLaterWorkingBytesStaysSaved() {
        val root = newDir("recovery-saved-close")
        val workingRoot = newDir("recovery-saved-close-work")
        val journal = OfficeRecoveryJournal(root)
        val candidate = candidate(workingRoot).copy(
            phase = OfficeRecoveryPhase.SAVED,
            destinationVerified = true,
            workingCopyBaseSha256 = hex('b'),
            savedWorkingCopySha256 = hex('b'),
        )
        journal.add(candidate)
        journal.markViewerClosed(
            candidate.id,
            resultPresent = true,
            closedCleanly = true,
            dirtyAtClose = true,
            discarded = false,
        )
        assertEquals(OfficeRecoveryPhase.SAVED, journal.candidate(candidate.id)!!.phase)
    }

    @Test
    fun savedCloseWithMeasuredLaterWorkingBytesBecomesUnresolved() {
        val root = newDir("recovery-measured-save")
        val workingRoot = newDir("recovery-measured-save-work")
        val journal = OfficeRecoveryJournal(root)
        val candidate = candidate(workingRoot).copy(
            phase = OfficeRecoveryPhase.SAVED,
            destinationVerified = true,
            workingCopyBaseSha256 = hex('d'),
            savedWorkingCopySha256 = hex('b'),
        )
        journal.add(candidate)
        journal.markViewerClosed(
            candidate.id,
            resultPresent = true,
            closedCleanly = true,
            dirtyAtClose = true,
            discarded = false,
            workingCopyChangedAfterSave = true,
        )
        val fact = journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.CLOSED_UNSAVED, fact.phase)
        assertTrue(fact.destinationVerified)
    }

    @Test
    fun explicitDiscardIsTerminal() {
        val root = newDir("recovery-discard")
        val workingRoot = newDir("recovery-discard-work")
        val journal = OfficeRecoveryJournal(root)
        val candidate = candidate(workingRoot)
        journal.add(candidate)
        journal.markViewerClosed(candidate.id, true, true, true, true)
        assertEquals(OfficeRecoveryPhase.DISCARDED, journal.candidate(candidate.id)!!.phase)
        assertTrue(journal.candidate(candidate.id)!!.dirtyAtClose == true)
    }

    @Test
    fun activeRecordsAreNeverEvictedAndVetoIsHonored() {
        val root = newDir("recovery-retention")
        val workingRoot = newDir("recovery-retention-work")
        val evicted = ArrayList<String>()
        var allow = false
        val journal = OfficeRecoveryJournal(
            root = root,
            canEvict = { allow },
            onEvict = { evicted += it.id },
        )
        val ids = (0 until 20).map { UUID.randomUUID().toString() }
        ids.forEach { id -> journal.add(candidate(workingRoot, id = id)) }
        assertEquals(20, journal.snapshot().size)
        assertThrows(OfficeRecoveryJournal.Full::class.java) {
            journal.add(candidate(workingRoot))
        }

        // Only the OLDEST SAVED record is a legal victim; with the veto it is
        // kept and the add still refuses instead of deleting an active copy.
        journal.update(ids.first()) { it.copy(phase = OfficeRecoveryPhase.SAVED) }
        assertThrows(OfficeRecoveryJournal.Full::class.java) {
            journal.add(candidate(workingRoot))
        }
        allow = true
        journal.add(candidate(workingRoot))
        assertEquals(listOf(ids.first()), evicted)
        assertEquals(20, journal.snapshot().size)
        assertNull(journal.candidate(ids.first()))
    }

    @Test
    fun malformedCandidateIsSkippedButRawJournalIsKept() {
        val root = newDir("recovery-malformed")
        File(root, "recovery-journal.json").writeText(
            JSONObject()
                .put("schema", OFFICE_RECOVERY_SCHEMA)
                .put(
                    "candidates",
                    JSONArray().put(
                        JSONObject()
                            .put("id", "bad")
                            .put("phase", "EDITING"),
                    ),
                )
                .toString(),
        )
        val journal = OfficeRecoveryJournal(root)
        assertTrue(journal.snapshot().isEmpty())
        assertNotNull(journal.loadDiagnostic)
    }
}
