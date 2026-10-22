// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class WorkspaceSweepSafetyTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun acknowledged(parent: File): File {
        val key = "a".repeat(32)
        return File(parent, ".floe-wt-$key").apply {
            mkdirs()
            File(this, "marker.json").writeText(JSONObject().put("record", "session")
                .put("sessionKey", key).put("createdAtMs", 1000L).toString())
            File(this, "journal.jsonl").writeText(JSONObject().put("record", "ack")
                .put("sessionKey", key).toString() + "\n")
        }
    }

    @Test fun staleJournalLinkCannotRemoveAnotherWorkspace() {
        val parent = temporary.newFolder("workspaces")
        val outside = temporary.newFolder("user-files")
        val file = File(outside, "keep.txt").apply { writeText("user bytes") }
        val journal = acknowledged(parent)
        Files.createSymbolicLink(File(journal, "linked-directory").toPath(), outside.toPath())
        val result = RuntimeWorkspaceSession.sweepStaleRuntimeJournals(parent, 10000L, 1000L)
        assertEquals(1, result.getInt("cleaned"))
        assertEquals("user bytes", file.readText())
        assertFalse(journal.exists())
    }

    @Test fun linkedRecoveryPayloadIsPreservedWithoutTraversal() {
        val parent = temporary.newFolder("workspaces")
        val outside = temporary.newFolder("recovery")
        val journal = acknowledged(parent)
        Files.createSymbolicLink(File(journal, "preserve").toPath(), outside.toPath())
        val result = RuntimeWorkspaceSession.sweepStaleRuntimeJournals(parent, 10000L, 1000L)
        assertEquals(0, result.getInt("cleaned"))
        assertTrue(journal.exists())
        assertTrue(outside.exists())
    }
}
