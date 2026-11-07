// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.core.officeengine.OfficeCloseAckPolicy
import com.floe.android.core.officeengine.OfficeCloseProof
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OfficeCloseFileVerificationTest {
    @get:Rule val temporary = TemporaryFolder()
    private val bytes = "original staged file".toByteArray()
    private fun stage(root: File): File = File(File(root, UUID.randomUUID().toString()).apply { mkdirs() }, "document.docx")
        .apply { writeBytes(bytes) }.canonicalFile
    private fun receipt() = OfficeCloseProof.Receipt(
        OfficeCloseAckPolicy.AckRequest("mount", 5, 9, "user-back"), false, false,
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }, bytes.size.toLong(),
    )

    @Test fun requiresActualExitEvenWhenFileMatches() {
        val root = temporary.newFolder("owned")
        val file = stage(root)
        assertFalse(OfficeCloseFileVerification.matches(file, setOf(root), receipt(), false))
        assertTrue(OfficeCloseFileVerification.matches(file, setOf(root), receipt(), true))
    }

    @Test fun bytesChangedOrRemovedDuringNativeCloseStayRecoverable() {
        val root = temporary.newFolder("owned")
        val file = stage(root)
        file.writeText("different byte count")
        assertFalse(OfficeCloseFileVerification.matches(file, setOf(root), receipt(), true))
        assertEquals("different byte count", file.readText())
        file.writeBytes(bytes.reversedArray())
        assertFalse(OfficeCloseFileVerification.matches(file, setOf(root), receipt(), true))
        assertTrue(file.delete())
        assertFalse(OfficeCloseFileVerification.matches(file, setOf(root), receipt(), true))
    }

    @Test fun sameBytesFromForeignMountOrSymlinkNeverAuthorizeCleanup() {
        val owned = temporary.newFolder("owned")
        val foreign = stage(temporary.newFolder("foreign"))
        assertFalse(OfficeCloseFileVerification.matches(foreign, setOf(owned), receipt(), true))
        val link = stage(owned)
        assertTrue(link.delete())
        Files.createSymbolicLink(link.toPath(), foreign.toPath())
        assertFalse(OfficeCloseFileVerification.matches(link, setOf(owned), receipt(), true))
        assertArrayEquals(bytes, foreign.readBytes())
    }
}
