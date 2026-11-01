// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.export.ExportRecoveryStore
import com.floe.android.core.workbenchmedia.export.RecoveryExpectation
import com.floe.android.core.workbenchmedia.export.RecoveryOwner
import com.floe.android.core.workbenchmedia.export.RecoveryRecord
import com.floe.android.core.workbenchmedia.export.RECOVERY_OWNER_VERSION
import com.floe.android.core.workbenchmedia.util.Digests
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.feature.workbench.ExportVerification
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportState
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportRecoveryTest {
    private val clock = MediaClock { 1_700_000_000_000L }
    private val root = Files.createTempDirectory("workbenchmedia-recovery").toFile()
    private val store = ExportRecoveryStore(clock)
    private val owner = RecoveryOwner(
        projectID = "project-1",
        storageKey = "app-owned",
        originKey = "standalone",
        ownerKey = "native-owner-key-1",
    )
    private val expectation = RecoveryExpectation(owner, root.path)

    @After
    fun cleanup() {
        root.deleteRecursively()
    }

    @Test
    fun terminalReceiptRoundTripsForAReauthorizedNewSessionOwner() {
        val bytes = ByteArray(1234) { index -> (index % 251).toByte() }
        val output = File(root, "Workbench/Exports/attempt-1.png")
        output.parentFile?.mkdirs()
        output.writeBytes(bytes)
        val record = completedRecord(
            jobID = "export-1",
            attemptID = "attempt-1",
            bytes = bytes,
            outputRelativePath = "Workbench/Exports/attempt-1.png",
        )
        store.write(root, record)

        // The store is given the native-reauthorized stable owner/root, not an
        // editor session token. A new authorized editor session uses exactly
        // this expectation.
        val status = store.statusFromRecovery(root, expectation, "export-1")
        assertNotNull(status)
        assertEquals(MediaExportState.COMPLETED, status!!.state)
        assertEquals(1.0, status.progress!!, 0.0)
        assertEquals("Workbench/Exports/attempt-1.png", status.receipt!!.outputRelativePath)
        assertEquals(Digests.sha256(bytes), status.receipt!!.sha256)
    }

    @Test
    fun aForeignOwnerCannotReadTheJournal() {
        val bytes = "terminal".toByteArray()
        writeOutput("Workbench/Exports/attempt-2.png", bytes)
        store.write(
            root,
            completedRecord("export-2", "attempt-2", bytes, "Workbench/Exports/attempt-2.png"),
        )
        val foreign = expectation.copy(
            owner = owner.copy(ownerKey = "native-owner-key-foreign"),
        )
        assertNull(store.statusFromRecovery(root, foreign, "export-2"))
        val otherStorage = expectation.copy(owner = owner.copy(storageKey = "workspace:1"))
        assertNull(store.statusFromRecovery(root, otherStorage, "export-2"))
        val otherOrigin = expectation.copy(owner = owner.copy(originKey = "files"))
        assertNull(store.statusFromRecovery(root, otherOrigin, "export-2"))
    }

    @Test
    fun sameSizeOutputTamperIsFailedNotAStaleSuccess() {
        val original = ByteArray(4096) { 7.toByte() }
        val tampered = original.copyOf().also { it[2048] = 8.toByte() }
        writeOutput("Workbench/Exports/attempt-3.png", tampered)
        store.write(
            root,
            completedRecord(
                "export-3",
                "attempt-3",
                original,
                "Workbench/Exports/attempt-3.png",
            ),
        )
        val status = store.statusFromRecovery(root, expectation, "export-3")
        assertNotNull(status)
        assertEquals(MediaExportState.FAILED, status!!.state)
        assertEquals("recoveryOutputChanged", status.errorCode)
        assertNull(status.receipt)
    }

    @Test
    fun aRecordCopiedToAnotherProjectRootIsNotAccepted() {
        val bytes = "root-bound".toByteArray()
        writeOutput("Workbench/Exports/attempt-4.png", bytes)
        store.write(
            root,
            completedRecord("export-4", "attempt-4", bytes, "Workbench/Exports/attempt-4.png"),
        )
        val otherRoot = Files.createTempDirectory("workbenchmedia-other-root").toFile()
        try {
            val otherDirectory = File(otherRoot, "MediaRecovery/Exports")
            otherDirectory.mkdirs()
            File(root, "MediaRecovery/Exports/export-4.json")
                .copyTo(File(otherDirectory, "export-4.json"))
            File(otherRoot, "Workbench/Exports").mkdirs()
            File(otherRoot, "Workbench/Exports/attempt-4.png").writeBytes(bytes)
            val otherExpectation = RecoveryExpectation(owner, otherRoot.path)
            assertNull(store.statusFromRecovery(otherRoot, otherExpectation, "export-4"))
        } finally {
            otherRoot.deleteRecursively()
        }
    }

    @Test
    fun oldJournalFormatIsAnExplicitMigrationRefusalNotAStaleSuccess() {
        val directory = File(root, "MediaRecovery/Exports")
        directory.mkdirs()
        File(directory, "export-old.json").writeText(
            """
            {
              "jobID": "export-old",
              "projectID": "project-1",
              "attemptID": "attempt-old",
              "kind": "image",
              "state": "completed",
              "updatedAt": "2026-11-01T00:00:00Z",
              "ownerFingerprint": "${Digests.sha256("old".toByteArray())}",
              "revision": 1,
              "timelineDigest": "digest",
              "outputRelativePath": "Workbench/Exports/attempt-old.png",
              "mimeType": "image/png",
              "byteCount": 1,
              "sha256": "${"a".repeat(64)}",
              "verification": {
                "playable": true,
                "width": 1,
                "height": 1,
                "audioTrackCount": 0,
                "container": "png",
                "codec": "png"
              }
            }
            """.trimIndent(),
        )
        val status = store.statusFromRecovery(root, expectation, "export-old")
        assertNotNull(status)
        assertEquals(MediaExportState.FAILED, status!!.state)
        assertEquals("recoveryRecordMigrationRequired", status.errorCode)
        assertNull(status.receipt)
    }

    @Test
    fun nonTerminalRecordSurfacesAsInterruptedNotSuccess() {
        val record = RecoveryRecord(
            jobID = "export-5",
            projectID = owner.projectID,
            attemptID = "attempt-5",
            kind = MediaExportKind.VIDEO,
            state = MediaExportState.RUNNING,
            updatedAt = "2026-11-01T00:00:00Z",
            ownerFingerprint = owner.fingerprint,
            revision = 4L,
            timelineDigest = "digest",
            ownerVersion = RECOVERY_OWNER_VERSION,
            ownerKey = owner.ownerKey,
            storageKey = owner.storageKey,
            originKey = owner.originKey,
            mediaRootPath = root.path,
            writtenEpoch = 7L,
        )
        store.write(root, record)
        val status = store.statusFromRecovery(root, expectation, "export-5")
        assertNotNull(status)
        assertEquals(MediaExportState.INTERRUPTED, status!!.state)
        assertEquals("processInterrupted", status.errorCode)
        assertNull(status.receipt)
    }

    @Test
    fun recoveryCandidatesAreBoundedAndIgnoreNonJsonPartials() {
        repeat(3) { index ->
            val jobID = "export-candidate-$index"
            store.write(
                root,
                store.initial(
                    jobID = jobID,
                    owner = owner,
                    attemptID = jobID,
                    kind = MediaExportKind.IMAGE,
                    revision = 1L,
                    timelineDigest = "digest",
                    mediaRootPath = root.path,
                    writtenEpoch = 1L,
                ),
            )
        }
        File(root, "MediaRecovery/Exports/.export-candidate-0.json.part").writeText("{}")
        val candidates = store.recoveryCandidates(root, maxScan = 2)
        assertEquals(2, candidates.size)
        assertTrue(candidates.all { it.jobID.startsWith("export-candidate-") })
    }

    @Test
    fun readingAnUnrelatedJobReturnsNull() {
        assertNull(store.statusFromRecovery(root, expectation, "missing"))
    }

    private fun completedRecord(
        jobID: String,
        attemptID: String,
        bytes: ByteArray,
        outputRelativePath: String,
    ): RecoveryRecord = RecoveryRecord(
        jobID = jobID,
        projectID = owner.projectID,
        attemptID = attemptID,
        kind = MediaExportKind.IMAGE,
        state = MediaExportState.COMPLETED,
        updatedAt = "2026-11-01T00:00:00Z",
        ownerFingerprint = owner.fingerprint,
        revision = 3L,
        timelineDigest = "digest",
        ownerVersion = RECOVERY_OWNER_VERSION,
        ownerKey = owner.ownerKey,
        storageKey = owner.storageKey,
        originKey = owner.originKey,
        mediaRootPath = root.path,
        writtenEpoch = 7L,
        progress = 1.0,
        outputRelativePath = outputRelativePath,
        mimeType = "image/png",
        byteCount = bytes.size.toLong(),
        sha256 = Digests.sha256(bytes),
        verification = ExportVerification(true, null, 100, 100, 0, "png", "png"),
    )

    private fun writeOutput(relativePath: String, bytes: ByteArray) {
        val output = File(root, relativePath)
        output.parentFile?.mkdirs()
        output.writeBytes(bytes)
    }
}
