// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class ExternalEditPolicyTest {
    private val base = "1".repeat(64)
    private val edited = "2".repeat(64)
    private val current = "3".repeat(64)

    @Test fun unchangedExternalCopyNeverOverwritesNewerOriginal() {
        assertEquals(ExternalEditPolicy.Decision.UNCHANGED,
            ExternalEditPolicy.decide(base, current, base))
    }

    @Test fun nativeCommitBeforeProcessDeathIsRecognizedWithoutRepeatingWrite() {
        assertEquals(ExternalEditPolicy.Decision.ALREADY_COMMITTED,
            ExternalEditPolicy.decide(base, edited, edited))
    }

    @Test fun simultaneousEditsRequireConflictWhileCleanBaselineAllowsReplacement() {
        assertEquals(ExternalEditPolicy.Decision.CONFLICT,
            ExternalEditPolicy.decide(base, current, edited))
        assertEquals(ExternalEditPolicy.Decision.REPLACE,
            ExternalEditPolicy.decide(base, base, edited))
    }

    @Test fun pathsAndOwnerIDsCannotSupplyAnOutsideSource() {
        for (path in listOf("../a", "/a", "a/../b", "a\\b", "a//b"))
            assertFalse(path, ExternalEditPolicy.validPath(path))
        assertTrue(ExternalEditPolicy.validPath("文档/草稿.docx"))
        assertThrows(IllegalArgumentException::class.java) { ExternalEditOwner("other-task", UUID.randomUUID().toString()) }
    }

    @Test fun actualJournalRoundtripRetainsPendingIdentityAndOriginalRecoveryHash() {
        val directory = Files.createTempDirectory("external-edit-journal").toFile()
        try {
            val owner = ExternalEditOwner(UUID.randomUUID().toString(), UUID.randomUUID().toString())
            val row = ExternalEditRecord(UUID.randomUUID().toString(), owner, "doc.txt", "doc.txt", base, 20,
                phase = ExternalEditPhase.COMMITTING, pendingSHA256 = edited, pendingBytes = 0,
                initialSHA256 = current)
            ExternalEditJournal(directory).save(row)
            assertEquals(row, ExternalEditJournal(directory).load().single())
        } finally { directory.deleteRecursively() }
    }

    @Test fun unknownJournalVersionFailsWithoutDeletingRecovery() {
        val directory = Files.createTempDirectory("external-edit-unknown").toFile()
        try {
            val file = File(directory, "${UUID.randomUUID()}.json")
            val original = "{\"version\":99,\"future\":true}"
            file.writeText(original)
            assertThrows(IllegalArgumentException::class.java) { ExternalEditJournal(directory).load() }
            assertEquals(original, file.readText())
        } finally { directory.deleteRecursively() }
    }
}
