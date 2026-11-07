// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import com.floe.android.safgateway.PickKind
import com.floe.android.safgateway.PickRequestSpec
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic JVM tests for the recovery review/action controller. All IO
 * dispatchers run unconfined so every transition is synchronous; fakes replace
 * only the App-owned SAF/viewer ports, never the journal or artifact checks.
 */
class OfficeRecoveryControllerTest {

    private fun newDir(prefix: String): File = File.createTempFile(prefix, "").let {
        it.delete()
        check(it.mkdirs())
        it
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun docx(extra: ByteArray = byteArrayOf()): ByteArray =
        byteArrayOf(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00) + extra

    private val token = "11111111-2222-3333-4444-555555555555"

    private inner class Fixture {
        val root = newDir("recovery-controller")
        val workingRoot = newDir("recovery-controller-work")
        val outputsRoot = newDir("recovery-controller-out")
        val journalRoot = newDir("recovery-controller-journal")
        val journal = OfficeRecoveryJournal(journalRoot)
        val artifacts = OfficeRecoveryArtifacts(workingRoot, outputsRoot)
        val export = FakeExport()
        val open = FakeOpen()
        val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
        val controller: OfficeRecoveryController by lazy {
            OfficeRecoveryController(
                scope = scope,
                journal = journal,
                artifacts = artifacts,
                exportPort = export,
                openPort = open,
                ioDispatcher = Dispatchers.Unconfined,
            )
        }

        /** Seeds a terminal SAVED record without initializing the controller. */
        fun seedSaved(index: Int, laterBytes: Boolean): OfficeRecoveryCandidate {
            val id = UUID.randomUUID().toString()
            val dir = File(workingRoot, id)
            check(dir.mkdirs())
            val working = File(dir, "document.docx")
            working.writeBytes(if (laterBytes) docx(byteArrayOf(1)) else docx())
            val outputDir = File(outputsRoot, "7")
            check(outputDir.mkdirs() || outputDir.isDirectory)
            val output = File(outputDir, "saved-$index-1234.docx")
            val outputBytes = docx()
            output.writeBytes(outputBytes)
            val base = sha(docx())
            val candidate = OfficeRecoveryCandidate(
                id = id,
                createdAtMillis = System.currentTimeMillis() + index,
                updatedAtMillis = System.currentTimeMillis() + index,
                phase = OfficeRecoveryPhase.SAVED,
                route = OfficeRecoveryRoute.WORKSPACE,
                displayName = "Saved.docx",
                format = "docx",
                sourceSha256 = base,
                sourceBytes = docx().size.toLong(),
                workingCopyPath = working.absolutePath,
                workingCopyBaseSha256 = base,
                workingCopyBaseBytes = docx().size.toLong(),
                outputWorkingCopyBaseSha256 = base,
                savedWorkingCopySha256 = base,
                outputPath = output.absolutePath,
                outputSha256 = sha(outputBytes),
                outputBytes = outputBytes.size.toLong(),
                outputFormat = "docx",
                outputOpId = "saved-$index",
                outputNativeGeneration = 7L,
                destinationUri = "content://provider/doc/saved-$index",
                destinationVerified = true,
            )
            journal.add(candidate)
            return candidate
        }

        fun candidate(working: ByteArray = docx(), withOutput: Boolean = false, phase: OfficeRecoveryPhase? = null): OfficeRecoveryCandidate {
            val id = UUID.randomUUID().toString()
            val dir = File(workingRoot, id)
            check(dir.mkdirs())
            val workingFile = File(dir, "document.docx")
            workingFile.writeBytes(working)
            val outputFile = if (withOutput) {
                val outputDir = File(outputsRoot, "7")
                check(outputDir.mkdirs() || outputDir.isDirectory)
                File(outputDir, "export-1-1234.docx").also { it.writeBytes(docx(byteArrayOf(7))) }
            } else {
                null
            }
            val candidate = OfficeRecoveryCandidate(
                id = id,
                createdAtMillis = System.currentTimeMillis(),
                updatedAtMillis = System.currentTimeMillis(),
                phase = phase ?: if (withOutput) OfficeRecoveryPhase.EXPORT_READY else OfficeRecoveryPhase.EDITING,
                route = OfficeRecoveryRoute.WORKSPACE,
                displayName = "Notes.docx",
                format = "docx",
                ownerTaskId = UUID.randomUUID().toString(),
                workspaceId = UUID.randomUUID().toString(),
                nativeEpoch = "3",
                hostGeneration = "4",
                sourceLogicalPath = "docs/Notes.docx",
                sourceSha256 = sha(docx()),
                sourceBytes = docx().size.toLong(),
                workingCopyPath = workingFile.absolutePath,
                workingCopyBaseSha256 = sha(working),
                workingCopyBaseBytes = working.size.toLong(),
                outputPath = outputFile?.absolutePath,
                outputSha256 = outputFile?.let { sha(it.readBytes()) },
                outputBytes = outputFile?.length() ?: 0L,
                outputFormat = if (outputFile != null) "docx" else null,
                outputOpId = if (outputFile != null) "export-1" else null,
                outputNativeGeneration = if (outputFile != null) 7L else 0L,
                savedWorkingCopySha256 = if (phase == OfficeRecoveryPhase.SAVED) sha(working) else null,
                destinationVerified = phase == OfficeRecoveryPhase.SAVED,
                originSessionToken = token,
            )
            journal.add(candidate)
            controller.refresh()
            return candidate
        }
    }

    private class FakeExport : OfficeRecoveryExportPort {
        var prepared: OfficeRecoveryPrepareOutcome = OfficeRecoveryPrepareOutcome.Ready(
            "req-1",
            PickRequestSpec(
                requestKey = "key-1",
                kind = PickKind.CREATE_DOCUMENT,
                mimeTypes = listOf("application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
                suggestedName = "Notes.docx",
                initialDirectory = null,
            ),
        )
        var delivered: OfficeRecoveryExportOutcome? = null
        var destination: OfficeRecoveryDestinationCheck = OfficeRecoveryDestinationCheck.Unavailable("none")
        var reauthorized: OfficeRecoveryDestinationCheck = OfficeRecoveryDestinationCheck.Unavailable("none")
        var reauthorizePrepared: OfficeRecoveryPrepareOutcome = OfficeRecoveryPrepareOutcome.Ready(
            "reauth-1",
            PickRequestSpec(
                requestKey = "reauth-key-1",
                kind = PickKind.OPEN_DOCUMENT,
                mimeTypes = listOf("application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
                suggestedName = null,
                initialDirectory = null,
            ),
        )
        var reauthorizeCalls = 0
        var original: OfficeRecoveryOriginalState = OfficeRecoveryOriginalState.UNAVAILABLE
        var activeFor = false
        var sessionBusy = false
        var onBusyProbe: (() -> Unit)? = null
        var prepareCalls = 0
        var deliverCalls = 0
        var cancelCalls = 0
        var checkCalls = 0
        var probeCalls = 0
        var lastUri: String? = null
        var phaseAtDeliver: OfficeRecoveryPhase? = null
        var phaseProbe: (() -> OfficeRecoveryPhase?)? = null
        var lastPreparedSource: OfficeRecoveryVerifiedSource? = null

        override fun prepare(
            candidate: OfficeRecoveryCandidate,
            source: OfficeRecoveryVerifiedSource,
        ): OfficeRecoveryPrepareOutcome {
            prepareCalls++
            lastPreparedSource = source
            return prepared
        }

        override fun deliver(
            requestId: String,
            uriString: String?,
            resultFlags: Int,
            callback: (OfficeRecoveryExportOutcome) -> Unit,
        ): Boolean {
            deliverCalls++
            lastUri = uriString
            phaseAtDeliver = phaseProbe?.invoke()
            delivered?.let(callback)
            return true
        }

        override fun cancel(requestId: String) {
            cancelCalls++
        }

        override fun hasActiveFor(candidateId: String): Boolean = activeFor

        override fun isSessionBusy(sessionToken: String): Boolean {
            val observed = sessionBusy
            onBusyProbe?.let { callback ->
                onBusyProbe = null
                callback()
            }
            return observed
        }

        override fun checkDestination(
            uriString: String,
            expectedSha256: String,
            expectedBytes: Long,
        ): OfficeRecoveryDestinationCheck {
            checkCalls++
            return destination
        }

        override fun prepareDestinationReauthorization(
            candidate: OfficeRecoveryCandidate,
        ): OfficeRecoveryPrepareOutcome = reauthorizePrepared

        override fun deliverDestinationReauthorization(
            requestId: String,
            uriString: String?,
            resultFlags: Int,
            expectedUri: String,
            expectedSha256: String,
            expectedBytes: Long,
        ): OfficeRecoveryDestinationCheck {
            reauthorizeCalls++
            return reauthorized
        }

        override fun probeOriginal(
            uriString: String,
            expectedSha256: String,
            expectedBytes: Long,
        ): OfficeRecoveryOriginalState {
            probeCalls++
            return original
        }
    }

    private class FakeOpen : OfficeRecoveryOpenPort {
        var result: OfficeRecoveryOpenResult = OfficeRecoveryOpenResult.Accepted("session")
        var active: String? = null
        var opens = 0
        var lastSha: String? = null
        var lastBytes: Long = 0L
        var original: OfficeRecoveryOriginalState = OfficeRecoveryOriginalState.UNAVAILABLE
        var probes = 0

        override fun open(
            candidate: OfficeRecoveryCandidate,
            observedSha256: String,
            observedBytes: Long,
        ): OfficeRecoveryOpenResult {
            opens++
            lastSha = observedSha256
            lastBytes = observedBytes
            return result
        }

        override fun activeCandidateId(): String? = active

        override fun probeOriginal(candidate: OfficeRecoveryCandidate): OfficeRecoveryOriginalState {
            probes++
            return original
        }
    }

    @Test
    fun coldStartSurfacesRecoverableCopyWithoutActing() {
        val fixture = Fixture()
        val candidate = fixture.candidate()
        val state = fixture.controller.state.value
        assertTrue(state.visible)
        assertEquals(1, state.candidates.size)
        assertTrue(state.candidates.single().canOpen)
        assertEquals(0, fixture.export.prepareCalls)
        assertEquals(0, fixture.export.deliverCalls)
        assertEquals(0, fixture.open.opens)
    }

    @Test
    fun missingOrCorruptWorkingCopyIsTruthful() {
        val fixture = Fixture()
        val corrupt = fixture.candidate(working = "not ooxml".toByteArray())
        val view = fixture.controller.state.value.candidates.single()
        assertEquals(OfficeRecoveryFileState.CORRUPT, view.workingCopy)
        assertFalse(view.canOpen)
        assertTrue(view.limitations.contains(OfficeRecoveryLimitation.MISSING_OR_CORRUPT))

        File(corrupt.workingCopyPath).delete()
        fixture.controller.refresh()
        val missing = fixture.controller.state.value.candidates.single()
        assertEquals(OfficeRecoveryFileState.MISSING, missing.workingCopy)
    }

    @Test
    fun saveCopyRequiresModuleVerifiedOutput() {
        val fixture = Fixture()
        val editOnly = fixture.candidate()
        assertFalse(fixture.controller.state.value.candidates.single().canExport)
        fixture.controller.saveCopy(editOnly.id)
        assertEquals(0, fixture.export.prepareCalls)
        assertEquals("exportUnavailable", fixture.controller.state.value.message)
    }

    @Test
    fun verifiedOutputPreparesTheExistingPickerExactlyOnce() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true)
        val view = fixture.controller.state.value.candidates.single()
        assertTrue(view.canExport)
        assertEquals(OfficeRecoveryFileState.AVAILABLE, view.output)
        fixture.controller.saveCopy(candidate.id)
        assertEquals(1, fixture.export.prepareCalls)
        assertEquals(candidate.outputSha256, fixture.export.lastPreparedSource?.sha256)
        assertNotNull(fixture.controller.state.value.launch)
        assertEquals("req-1", fixture.controller.state.value.launch?.requestId)
    }

    @Test
    fun acceptedTargetIsPersistedTransferredAndOnlyVerifiedEqualityClaimed() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true)
        fixture.controller.saveCopy(candidate.id)
        fixture.export.phaseProbe = { fixture.journal.candidate(candidate.id)?.phase }
        fixture.export.delivered = OfficeRecoveryExportOutcome.Saved(
            "req-1",
            "content://provider/doc/1",
            candidate.outputSha256!!,
            candidate.outputBytes,
        )
        fixture.controller.onPickerResult("req-1", -1, "content://provider/doc/1", 3)
        val fact = fixture.journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.SAVED, fact.phase)
        assertTrue(fact.destinationVerified)
        assertEquals("content://provider/doc/1", fact.destinationUri)
        assertEquals(candidate.outputSha256, fact.destinationSha256)
        assertEquals(candidate.outputBytes, fact.destinationBytes)
        assertEquals(1, fixture.export.deliverCalls)
        // The journal was already TRANSFERRING when the real transfer started.
        assertEquals(OfficeRecoveryPhase.TRANSFERRING, fixture.export.phaseAtDeliver)
    }

    @Test
    fun cancelledPickerWritesNothingAndReturnsToReady() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true)
        fixture.controller.saveCopy(candidate.id)
        fixture.controller.onPickerResult("req-1", 0, null, 0)
        assertEquals(0, fixture.export.deliverCalls)
        assertEquals(1, fixture.export.cancelCalls)
        assertEquals(OfficeRecoveryPhase.EXPORT_READY, fixture.journal.candidate(candidate.id)!!.phase)
    }

    @Test
    fun stalePickerResultCannotBindTheCurrentLaunch() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true)
        fixture.controller.saveCopy(candidate.id)
        fixture.controller.onPickerResult("old-request", -1, "content://provider/doc/old", 3)
        assertEquals(0, fixture.export.deliverCalls)
        assertEquals(0, fixture.export.cancelCalls)
        assertEquals(OfficeRecoveryPhase.EXPORT_READY, fixture.journal.candidate(candidate.id)!!.phase)
        assertNotNull(fixture.controller.state.value.launch)
    }

    @Test
    fun journalFailureAbortsBeforeAnyProviderWrite() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true)
        fixture.controller.saveCopy(candidate.id)
        // Replace the journal directory with a regular file: the exact durable
        // TRANSFERRING commit can no longer succeed.
        fixture.journalRoot.deleteRecursively()
        fixture.journalRoot.writeText("not a directory")
        fixture.controller.onPickerResult("req-1", -1, "content://provider/doc/1", 3)
        assertEquals(0, fixture.export.deliverCalls)
        assertEquals("journalUnavailable", fixture.controller.state.value.message)
        assertEquals(OfficeRecoveryPhase.EXPORT_READY, fixture.journal.candidate(candidate.id)!!.phase)
    }

    @Test
    fun capacityReclaimRemovesOnlySavedCopiesWithoutLaterWorkingBytes() {
        val fixture = Fixture()
        val later = fixture.seedSaved(0, laterBytes = true)
        val normal = (1 until 20).map { fixture.seedSaved(it, laterBytes = false) }
        // Lazy controller construction runs the cold projection: the later
        // working bytes become CLOSED_UNSAVED, while the rest stay SAVED.
        val controller = fixture.controller
        assertEquals(OfficeRecoveryPhase.CLOSED_UNSAVED, fixture.journal.candidate(later.id)!!.phase)
        assertEquals(OfficeRecoveryPhase.SAVED, fixture.journal.candidate(normal.first().id)!!.phase)
        controller.reclaimCapacity()
        assertTrue(fixture.journal.snapshot().size < 20)
        assertNotNull(fixture.journal.candidate(later.id))
        assertTrue(File(later.workingCopyPath).exists())
    }

    @Test
    fun savedCopyWithNoLaterWorkingBytesStaysSaved() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true, phase = OfficeRecoveryPhase.SAVED)
        val bytes = File(candidate.workingCopyPath).readBytes()
        val digest = sha(bytes)
        File(candidate.outputPath!!).writeBytes(bytes)
        fixture.journal.update(candidate.id) {
            it.copy(
                outputSha256 = digest,
                outputBytes = bytes.size.toLong(),
                outputWorkingCopyBaseSha256 = digest,
                savedWorkingCopySha256 = digest,
                destinationVerified = true,
            )
        }
        val cold = OfficeRecoveryController(
            scope = fixture.scope,
            journal = fixture.journal,
            artifacts = fixture.artifacts,
            exportPort = fixture.export,
            openPort = fixture.open,
            ioDispatcher = Dispatchers.Unconfined,
        )
        val fact = fixture.journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.SAVED, fact.phase)
        assertFalse(cold.state.value.candidates.single().unresolved)
    }

    @Test
    fun savedWorkingBytesAfterTheVerifiedDestinationStayUnresolved() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true, phase = OfficeRecoveryPhase.SAVED)
            .copy(
                destinationUri = "content://provider/doc/1",
                destinationVerified = true,
                destinationSha256 = null,
                savedWorkingCopySha256 = "0".repeat(64),
            )
        fixture.journal.update(candidate.id) { candidate }
        val cold = OfficeRecoveryController(
            scope = fixture.scope,
            journal = fixture.journal,
            artifacts = fixture.artifacts,
            exportPort = fixture.export,
            openPort = fixture.open,
            ioDispatcher = Dispatchers.Unconfined,
        )
        val fact = fixture.journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.CLOSED_UNSAVED, fact.phase)
        val view = cold.state.value.candidates.single()
        assertTrue(view.unresolved)
        assertTrue(view.limitations.contains(OfficeRecoveryLimitation.UNSAVED_AFTER_SAVE))
        assertTrue(view.canOpen)
        // The verified output is the EARLIER copy; do not offer it as a save
        // of the later working bytes. The user opens the retained copy and
        // performs a fresh engine-verified Save Copy.
        assertFalse(view.canExport)
    }

    @Test
    fun coldStartNormalizesAnInterruptedTransferToUncertain() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true, phase = OfficeRecoveryPhase.TRANSFERRING)
            .copy(destinationUri = "content://provider/doc/1", attemptCount = 1)
        fixture.journal.update(candidate.id) { candidate }
        // A NEW controller instance is the cold-start projection.
        val cold = OfficeRecoveryController(
            scope = fixture.scope,
            journal = fixture.journal,
            artifacts = fixture.artifacts,
            exportPort = fixture.export,
            openPort = fixture.open,
            ioDispatcher = Dispatchers.Unconfined,
        )
        val view = cold.state.value.candidates.single()
        assertEquals(OfficeRecoveryPhase.UNCERTAIN, view.phase)
        assertTrue(view.canCheckDestination)
        assertEquals(OfficeRecoveryPhase.UNCERTAIN, fixture.journal.candidate(candidate.id)!!.phase)
        assertEquals("process-loss", fixture.journal.candidate(candidate.id)!!.lastErrorCode)
        assertEquals(0, fixture.export.prepareCalls)
        assertEquals(0, fixture.export.deliverCalls)
    }

    @Test
    fun uncertainDestinationIsNeverAutomaticallyRetried() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true, phase = OfficeRecoveryPhase.UNCERTAIN)
            .copy(destinationUri = "content://provider/doc/1", attemptCount = 1)
        fixture.journal.update(candidate.id) { candidate }
        fixture.controller.refresh()
        val view = fixture.controller.state.value.candidates.single()
        assertTrue(view.canCheckDestination)
        assertEquals(0, fixture.export.prepareCalls)
        assertEquals(0, fixture.export.deliverCalls)
        assertEquals(0, fixture.export.checkCalls)

        fixture.export.destination = OfficeRecoveryDestinationCheck.Verified(candidate.outputSha256!!, candidate.outputBytes)
        fixture.controller.checkDestination(candidate.id)
        val fact = fixture.journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.SAVED, fact.phase)
        assertTrue(fact.destinationVerified)
    }

    @Test
    fun reauthorizedDestinationMustMatchIdentityAndBytes() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true, phase = OfficeRecoveryPhase.UNCERTAIN)
            .copy(destinationUri = "content://provider/doc/1")
        fixture.journal.update(candidate.id) { candidate }
        fixture.controller.refresh()
        fixture.controller.reauthorizeDestination(candidate.id)
        val launch = fixture.controller.state.value.launch
        assertNotNull(launch)
        assertEquals(OfficeRecoveryLaunchPurpose.REAUTHORIZE, launch?.purpose)
        fixture.export.reauthorized = OfficeRecoveryDestinationCheck.Verified(
            candidate.outputSha256!!,
            candidate.outputBytes,
        )
        fixture.controller.onPickerResult("reauth-1", -1, "content://provider/doc/1", 3)
        val fact = fixture.journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.SAVED, fact.phase)
        assertTrue(fact.destinationVerified)
        assertEquals("content://provider/doc/1", fact.destinationUri)
        assertEquals(1, fixture.export.reauthorizeCalls)
    }

    @Test
    fun reauthorizedDifferentFileIsNotAcceptedAsTheDestination() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true, phase = OfficeRecoveryPhase.UNCERTAIN)
            .copy(destinationUri = "content://provider/doc/1")
        fixture.journal.update(candidate.id) { candidate }
        fixture.controller.refresh()
        fixture.controller.reauthorizeDestination(candidate.id)
        fixture.export.reauthorized = OfficeRecoveryDestinationCheck.Differs(null, null, "identity-mismatch")
        fixture.controller.onPickerResult("reauth-1", -1, "content://provider/doc/other", 3)
        val fact = fixture.journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.UNCERTAIN, fact.phase)
        assertFalse(fact.destinationVerified)
        assertEquals("destination-differs", fact.lastErrorCode)
        assertEquals(0, fixture.export.deliverCalls)
    }

    @Test
    fun missingGrantKeepsTheDestinationUncertain() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true, phase = OfficeRecoveryPhase.UNCERTAIN)
            .copy(destinationUri = "content://provider/doc/1")
        fixture.journal.update(candidate.id) { candidate }
        fixture.controller.refresh()
        fixture.export.destination = OfficeRecoveryDestinationCheck.GrantRequired("grant_missing")
        fixture.controller.checkDestination(candidate.id)
        val fact = fixture.journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.UNCERTAIN, fact.phase)
        assertFalse(fact.destinationVerified)
        assertEquals("grant-required", fact.lastErrorCode)
        assertEquals("checkGrant", fixture.controller.state.value.message)
    }

    @Test
    fun discardRefusesAnOpenCandidateThenDeletesOnlyOwnedFiles() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true)
        fixture.open.active = candidate.id
        fixture.controller.refresh()
        assertFalse(fixture.controller.state.value.candidates.single().canDiscard)
        fixture.controller.discard(candidate.id)
        assertTrue(File(candidate.workingCopyPath).exists())
        assertEquals("discardBusy", fixture.controller.state.value.message)

        fixture.open.active = null
        fixture.controller.refresh()
        fixture.controller.discard(candidate.id)
        assertFalse(File(candidate.workingCopyPath).exists())
        assertFalse(File(candidate.outputPath!!).exists())
        assertNull(fixture.journal.candidate(candidate.id))
    }

    @Test
    fun viewerDiscardWaitsForActualSessionQuiescence() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true)
        fixture.export.sessionBusy = true
        fixture.controller.onViewerClosed(
            candidateId = candidate.id,
            sessionToken = token,
            resultPresent = true,
            closedCleanly = true,
            dirtyAtClose = true,
            discarded = true,
            outputDescriptors = emptyList(),
        )
        assertEquals(OfficeRecoveryPhase.DISCARDED, fixture.journal.candidate(candidate.id)!!.phase)
        assertTrue(File(candidate.workingCopyPath).exists())

        fixture.export.sessionBusy = false
        fixture.controller.onSessionQuiescent(token)
        assertFalse(File(candidate.workingCopyPath).exists())
        assertNull(fixture.journal.candidate(candidate.id))
    }

    @Test
    fun viewerDiscardCannotMissTheFinalWriterDuringBusyProbe() {
        val fixture = Fixture()
        val candidate = fixture.candidate(withOutput = true)
        val original = File(fixture.root, "original.docx").apply { writeBytes(docx(byteArrayOf(9))) }
        fixture.export.sessionBusy = true
        fixture.export.onBusyProbe = {
            fixture.export.sessionBusy = false
            fixture.controller.onSessionQuiescent(token)
        }
        fixture.controller.onViewerClosed(candidate.id, token, true, true, true, true, emptyList())
        assertFalse(File(candidate.workingCopyPath).exists())
        assertFalse(File(candidate.outputPath!!).exists())
        assertNull(fixture.journal.candidate(candidate.id))
        // Duplicate drain cannot remove an original or another candidate.
        fixture.controller.onSessionQuiescent(token)
        assertTrue(original.exists())
    }

    @Test
    fun cleanCloseIsNotResurfacedButDirtyCloseIs() {
        val fixture = Fixture()
        val clean = fixture.candidate()
        fixture.controller.dismiss()
        fixture.controller.onViewerClosed(
            candidateId = clean.id,
            sessionToken = token,
            resultPresent = true,
            closedCleanly = true,
            dirtyAtClose = false,
            discarded = false,
            outputDescriptors = emptyList(),
        )
        assertEquals(OfficeRecoveryPhase.CLOSED_CLEAN, fixture.journal.candidate(clean.id)!!.phase)
        assertFalse(fixture.controller.state.value.visible)

        fixture.controller.show()
        val dirty = fixture.candidate()
        fixture.controller.onViewerClosed(
            candidateId = dirty.id,
            sessionToken = token,
            resultPresent = true,
            closedCleanly = true,
            dirtyAtClose = true,
            discarded = false,
            outputDescriptors = emptyList(),
        )
        assertEquals(OfficeRecoveryPhase.CLOSED_UNSAVED, fixture.journal.candidate(dirty.id)!!.phase)
        assertTrue(fixture.controller.state.value.visible)
    }

    @Test
    fun missedOutputDescriptorIsAdoptedOnlyAfterRealBytesVerify() {
        val fixture = Fixture()
        val candidate = fixture.candidate()
        val outputDir = File(fixture.outputsRoot, "7")
        check(outputDir.mkdirs() || outputDir.isDirectory)
        val output = File(outputDir, "export-9-555.docx")
        val bytes = docx(byteArrayOf(9))
        output.writeBytes(bytes)
        val receipt = OfficeSaveReceipt(
            opId = "export-9",
            sessionToken = "",
            generation = 0L,
            operation = OfficeSaveOperation.STAGED_EXPORT,
            state = OfficeSaveState.OUTPUT_READY,
            format = "docx",
            suggestedName = null,
            expectedBaseSha256 = null,
            workingCopySha256 = null,
            workingCopyBytes = 0L,
            outputDocumentPath = output.absolutePath,
            outputSha256 = sha(bytes),
            outputBytes = bytes.size.toLong(),
            failure = null,
            message = null,
            cancelRequested = false,
            attestation = "test",
            submittedAtElapsedMs = 1L,
            completedAtElapsedMs = 2L,
        )
        fixture.controller.onViewerClosed(
            candidateId = candidate.id,
            sessionToken = token,
            resultPresent = true,
            closedCleanly = true,
            dirtyAtClose = false,
            discarded = false,
            outputDescriptors = listOf(receipt.descriptorLine()),
        )
        val fact = fixture.journal.candidate(candidate.id)!!
        assertEquals(OfficeRecoveryPhase.EXPORT_READY, fact.phase)
        assertEquals(output.absolutePath, fact.outputPath)
        assertEquals(7L, fact.outputNativeGeneration)
    }

    @Test
    fun openUsesTheMeasuredWorkingCopyBytes() {
        val fixture = Fixture()
        val candidate = fixture.candidate()
        fixture.controller.open(candidate.id)
        assertEquals(1, fixture.open.opens)
        assertEquals(sha(File(candidate.workingCopyPath).readBytes()), fixture.open.lastSha)
        assertEquals(File(candidate.workingCopyPath).length(), fixture.open.lastBytes)
        // The review stays reachable after a failed/returning mount.
        assertTrue(fixture.controller.state.value.visible)
    }

    @Test
    fun explicitOriginalProbeAddsAChangedLimitation() {
        val fixture = Fixture()
        val candidate = fixture.candidate()
        fixture.open.original = OfficeRecoveryOriginalState.CHANGED
        fixture.controller.probeOriginal(candidate.id)
        val view = fixture.controller.state.value.candidates.single()
        assertEquals(OfficeRecoveryOriginalState.CHANGED, view.originalState)
        assertTrue(view.limitations.contains(OfficeRecoveryLimitation.ORIGINAL_CHANGED))
        assertEquals(0, fixture.export.prepareCalls)
        assertEquals(0, fixture.open.opens)
    }
}
