// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactHandoffJournalTest {
    private fun record(phase: ArtifactHandoffPhase = ArtifactHandoffPhase.LAUNCHED) =
        ArtifactHandoffRecord(
            id = UUID.randomUUID().toString(),
            owner = ExternalEditOwner(UUID.randomUUID().toString(), UUID.randomUUID().toString()),
            source = "workspace",
            logicalPath = "deliverables/poster.png",
            runID = null,
            outputID = null,
            displayName = "poster.png",
            mimeType = "image/png",
            sha256 = "a".repeat(64),
            bytes = 1234,
            targetPackage = "com.sec.android.gallery3d",
            targetComponent = "com.sec.android.gallery3d/View",
            phase = phase,
            launched = phase == ArtifactHandoffPhase.LAUNCHED,
            toolLaunchKey = "run:call",
            toolLaunchConfirmed = phase == ArtifactHandoffPhase.LAUNCHED,
            launchAttempt = if (phase == ArtifactHandoffPhase.LAUNCHED)
                ArtifactHandoffLaunchAttempt.ACCEPTED else ArtifactHandoffLaunchAttempt.NONE,
        )

    @Test
    fun durableRoundtripRetainsSourceTargetAndLaunchIdentity() {
        val directory = Files.createTempDirectory("artifact-handoff-journal").toFile()
        try {
            val row = record()
            ArtifactHandoffJournal(directory).save(row)
            assertEquals(row, ArtifactHandoffJournal(directory).load().single())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun outputSourceRoundtripRetainsTheSealedTriple() {
        val directory = Files.createTempDirectory("artifact-handoff-output").toFile()
        try {
            val row = record(ArtifactHandoffPhase.STAGED).copy(
                source = "output", logicalPath = null,
                runID = UUID.randomUUID().toString(), outputID = "b".repeat(64),
                launched = false, toolLaunchConfirmed = false, phase = ArtifactHandoffPhase.STAGED)
            ArtifactHandoffJournal(directory).save(row)
            val loaded = ArtifactHandoffJournal(directory).load().single()
            assertEquals("output", loaded.source)
            assertEquals(row.runID, loaded.runID)
            assertEquals(row.outputID, loaded.outputID)
            assertTrue(ArtifactHandoffPolicy.sourceMatches(loaded, "output", null, row.outputID))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun unknownVersionFailsWithoutDeletingRecovery() {
        val directory = Files.createTempDirectory("artifact-handoff-unknown").toFile()
        try {
            val file = File(directory, "${UUID.randomUUID()}.json")
            val original = "{\"version\":99,\"future\":true}"
            file.writeText(original)
            assertThrows(IllegalArgumentException::class.java) {
                ArtifactHandoffJournal(directory).load()
            }
            assertEquals(original, file.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun terminalRecordNeverClaimsLaunchOrCompletion() {
        val row = record(ArtifactHandoffPhase.CANCELLED).copy(
            launched = true, toolLaunchConfirmed = true,
            launchAttempt = ArtifactHandoffLaunchAttempt.ACCEPTED)
        assertEquals(ArtifactHandoffPhase.CANCELLED, row.phase)
        assertFalse(ArtifactHandoffPolicy.canResume(row))
        assertFalse(ArtifactHandoffPolicy.canResume(row.copy(phase = ArtifactHandoffPhase.FINISHED)))
    }
}
