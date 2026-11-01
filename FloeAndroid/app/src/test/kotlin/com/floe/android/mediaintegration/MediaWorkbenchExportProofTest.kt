// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNoException
import org.junit.Test

class MediaWorkbenchExportProofTest {
    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    @Test
    fun relativePathMustStayBeneathProjectRoot() {
        assertTrue(MediaWorkbenchExportProof.isSafeRelativePath("Workbench/Exports/a.mp4"))
        assertTrue(!MediaWorkbenchExportProof.isSafeRelativePath("../a.mp4"))
        assertTrue(!MediaWorkbenchExportProof.isSafeRelativePath("Workbench/../../a.mp4"))
        assertTrue(!MediaWorkbenchExportProof.isSafeRelativePath("/absolute/a.mp4"))
        assertTrue(!MediaWorkbenchExportProof.isSafeRelativePath("Workbench//a.mp4"))
        assertTrue(!MediaWorkbenchExportProof.isSafeRelativePath("Workbench\\a.mp4"))
        assertTrue(!MediaWorkbenchExportProof.isSafeRelativePath(""))
    }

    @Test
    fun containedFileRejectsEscapeAndAcceptsExactChild() {
        val root = Files.createTempDirectory("floe-export-root").toFile()
        try {
            val child = File(root, "Workbench/Exports/a.mp4")
            child.parentFile?.mkdirs()
            child.writeBytes(byteArrayOf(1, 2, 3))
            val outside = File(root.parentFile, "outside-${System.nanoTime()}.mp4")
            outside.writeBytes(byteArrayOf(4))
            try {
                assertNull(
                    MediaWorkbenchExportProof.resolveContainedFile(
                        root.path, "../" + outside.name),
                )
                val resolved = MediaWorkbenchExportProof.resolveContainedFile(
                    root.path, "Workbench/Exports/a.mp4")
                assertNotNull(resolved)
                assertEquals(child.canonicalFile, resolved!!.canonicalFile)
                val link = File(root, "link.mp4")
                try {
                    Files.createSymbolicLink(link.toPath(), outside.toPath())
                } catch (unsupported: Throwable) {
                    assumeNoException(unsupported)
                }
                assertNull(
                    MediaWorkbenchExportProof.resolveContainedFile(root.path, "link.mp4"),
                )
            } finally {
                outside.delete()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun verifyAndStageRequiresExactSizeAndDigest() {
        val root = Files.createTempDirectory("floe-export-proof").toFile()
        try {
            val payload = ByteArray(4096) { (it % 251).toByte() }
            val source = File(root, "source.mp4")
            source.writeBytes(payload)
            val expected = sha256(payload)
            val part = File(root, "payload.part")
            val verified = MediaWorkbenchExportProof.verifyAndStage(
                source, payload.size.toLong(), expected, part)
            assertNotNull(verified)
            assertEquals(expected, verified!!.sha256)
            assertEquals(payload.size.toLong(), part.length())
            assertTrue(part.delete())

            val wrongDigest = "0".repeat(64)
            assertNull(
                MediaWorkbenchExportProof.verifyAndStage(
                    source, payload.size.toLong(), wrongDigest, part),
            )
            assertTrue(!part.exists())

            // A same-size tamper is a digest mismatch, never a prefix success.
            source.writeBytes(payload.copyOf().also { it[0] = (it[0] + 1).toByte() })
            assertNull(
                MediaWorkbenchExportProof.verifyAndStage(
                    source, payload.size.toLong(), expected, part),
            )

            // A shorter declared length must fail the exact-EOF probe.
            source.writeBytes(payload)
            assertNull(
                MediaWorkbenchExportProof.verifyAndStage(
                    source, payload.size - 1L, expected, part),
            )
            assertTrue(!part.exists())
        } finally {
            root.deleteRecursively()
        }
    }
}
