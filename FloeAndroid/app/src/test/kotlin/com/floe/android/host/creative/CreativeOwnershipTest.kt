// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CreativeOwnershipTest {
    private fun root(): File {
        val value = File(
            System.getProperty("java.io.tmpdir"),
            "floe-accepted-${java.util.UUID.randomUUID()}")
        value.mkdirs()
        return value
    }

    @Test
    fun `accepted root and epoch must match the live generation`() {
        val accepted = CreativeAcceptedRoot(root().path, 5)
        val live = CreativeOwnership.requireLive(accepted, 5)
        assertEquals(accepted, live)
        for ((value, epoch) in listOf(
            null to 5L,
            accepted to 4L,
            accepted to null,
        )) {
            val error = runCatching {
                CreativeOwnership.requireLive(value as CreativeAcceptedRoot?, epoch)
            }.exceptionOrNull()
            assertTrue(error is CreativeException)
            assertEquals("staleGeneration", (error as CreativeException).code)
        }
    }

    @Test
    fun `staging file stays under the accepted creative incoming directory`() {
        val root = root()
        try {
            val accepted = CreativeAcceptedRoot(root.path, 1)
            val token = "session-1.${java.util.UUID.randomUUID()}"
            val target = CreativeOwnership.stagingFile(accepted, token)
            assertTrue(target.path.contains(File.separator + "FloeAgent" + File.separator))
            assertTrue(target.path.contains("CreativeIncoming"))
            assertTrue(target.path.startsWith(File(root, "FloeAgent/CreativeIncoming").canonicalPath + File.separator))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `staging tokens reject path separators traversal and empty names`() {
        val accepted = CreativeAcceptedRoot(root().path, 1)
        for (bad in listOf("", "../x", "a/b", ".hidden", "x".repeat(201))) {
            assertFalse(bad, CreativeOwnership.isSafeStagingToken(bad))
            val error = runCatching {
                CreativeOwnership.stagingFile(accepted, bad)
            }.exceptionOrNull()
            assertTrue(bad, error is CreativeException)
        }
    }
}
