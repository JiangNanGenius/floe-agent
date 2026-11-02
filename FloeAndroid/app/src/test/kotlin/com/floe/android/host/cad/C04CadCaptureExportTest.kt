// SPDX-License-Identifier: MPL-2.0
//
// C04C focused JVM tests for the verified capture-to-SAF document exporter.
// AUTHORED, NOT RUN by this source-only lane. They use an in-memory sink; the
// real Android ContentResolver path and the Compose picker remain Main's
// unified qualification.
package com.floe.android.host.cad

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class C04CadCaptureExportTest {
    private fun chunk(type: String, data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        val length = data.size
        out.write(byteArrayOf(
            (length ushr 24).toByte(), (length ushr 16).toByte(),
            (length ushr 8).toByte(), length.toByte(),
        ))
        out.write(type.toByteArray(Charsets.US_ASCII))
        out.write(data)
        out.write(byteArrayOf(0, 0, 0, 0))
        return out.toByteArray()
    }

    private fun png(width: Int = 640, height: Int = 480): ByteArray {
        val header = ByteArrayOutputStream().apply {
            write(byteArrayOf(
                (width ushr 24).toByte(), (width ushr 16).toByte(),
                (width ushr 8).toByte(), width.toByte(),
                (height ushr 24).toByte(), (height ushr 16).toByte(),
                (height ushr 8).toByte(), height.toByte(),
                8, 6, 0, 0, 0,
            ))
        }.toByteArray()
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ))
        out.write(chunk("IHDR", header))
        out.write(chunk("IDAT", byteArrayOf(1, 2, 3)))
        out.write(chunk("IEND", ByteArray(0)))
        return out.toByteArray()
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    private class MemorySink(
        override val uri: String,
        private val name: String = "part-preview.png",
    ) : C04CadExportSink {
        var target: ByteArray? = null
        var deleted = false
        var refuseWrite = false
        var corruptReadBack = false
        var onOpenOutput: (() -> Unit)? = null
        var onOpenInput: (() -> Unit)? = null

        override fun openOutput(): OutputStream? {
            if (refuseWrite) return null
            onOpenOutput?.invoke()
            var buffer = ByteArrayOutputStream()
            return object : OutputStream() {
                override fun write(value: Int) { buffer.write(value) }
                override fun write(bytes: ByteArray, offset: Int, length: Int) {
                    buffer.write(bytes, offset, length)
                }
                override fun close() { target = buffer.toByteArray() }
            }
        }

        override fun openInput(): InputStream? {
            onOpenInput?.invoke()
            val bytes = target ?: return null
            val value = bytes.copyOf()
            if (corruptReadBack && value.isNotEmpty()) value[value.size - 1] = (value.last().toInt() xor 1).toByte()
            return ByteArrayInputStream(value)
        }

        override fun delete(): Boolean {
            deleted = true
            target = null
            return true
        }

        override fun displayName(): String = name
    }

    private fun artifact(bytes: ByteArray, root: java.io.File): C04CadCaptureArtifact {
        val session = java.io.File(root, "session")
        session.mkdirs()
        val file = java.io.File(session, "part-preview.png")
        file.writeBytes(bytes)
        return C04CadCaptureArtifact(
            file = file,
            fileName = "part-preview.png",
            sha256 = sha(bytes),
            byteCount = bytes.size.toLong(),
            pixelWidth = 640,
            pixelHeight = 480,
            capturedAtMillis = 7L,
            format = C04CadFormat.FLOECAD,
            pngHeaderHex = "",
        )
    }

    @Test
    fun exportsTheExactVerifiedBytesAndReturnsTheDocumentUri() {
        val root = Files.createTempDirectory("c04c-capture").toFile()
        val bytes = png()
        val artifact = artifact(bytes, root)
        val sink = MemorySink("content://provider/document/part-preview.png")
        val exported = C04CadCaptureExporter(root).export(artifact, sink)
        assertEquals("content://provider/document/part-preview.png", exported.uri)
        assertEquals("part-preview.png", exported.displayName)
        assertEquals(artifact.sha256, exported.sha256)
        assertEquals(bytes.size.toLong(), exported.byteCount)
        assertNotNull(sink.target)
        assertTrue(bytes.contentEquals(sink.target!!))
        assertFalse(sink.deleted)
    }

    @Test
    fun aReadBackMismatchDeletesTheDocumentAndReturnsNoReceipt() {
        val root = Files.createTempDirectory("c04c-capture").toFile()
        val artifact = artifact(png(), root)
        val sink = MemorySink("content://provider/document/corrupt.png")
        sink.corruptReadBack = true
        try {
            C04CadCaptureExporter(root).export(artifact, sink)
            fail("expected targetDigest")
        } catch (error: C04CadExportFailure) {
            assertEquals("targetDigest", error.code)
            assertTrue(sink.deleted)
            assertNull(sink.target)
        }
    }

    @Test
    fun aRefusedOrCancelledWriteReturnsNoReceipt() {
        val root = Files.createTempDirectory("c04c-capture").toFile()
        val artifact = artifact(png(), root)
        val sink = MemorySink("content://provider/document/cancel.png")
        sink.refuseWrite = true
        try {
            C04CadCaptureExporter(root).export(artifact, sink)
            fail("expected targetOpen")
        } catch (error: C04CadExportFailure) {
            assertEquals("targetOpen", error.code)
            assertFalse(sink.deleted)
        }
    }

    @Test
    fun anOwnerFenceDuringTheWriteDeletesTheDocumentAndReturnsNoReceipt() {
        val root = Files.createTempDirectory("c04c-capture").toFile()
        val artifact = artifact(png(), root)
        val sink = MemorySink("content://provider/document/stale.png")
        var current = true
        sink.onOpenOutput = { current = false }
        try {
            C04CadCaptureExporter(root).export(artifact, sink) { current }
            fail("expected owner")
        } catch (error: C04CadExportFailure) {
            assertEquals("owner", error.code)
            assertTrue(sink.deleted)
            assertNull(sink.target)
        }
    }

    @Test
    fun anOwnerFenceDuringTheReadBackAlsoDeletesTheDocument() {
        val root = Files.createTempDirectory("c04c-capture").toFile()
        val artifact = artifact(png(), root)
        val sink = MemorySink("content://provider/document/stale-read.png")
        var current = true
        sink.onOpenInput = { current = false }
        try {
            C04CadCaptureExporter(root).export(artifact, sink) { current }
            fail("expected owner")
        } catch (error: C04CadExportFailure) {
            assertEquals("owner", error.code)
            assertTrue(sink.deleted)
            assertNull(sink.target)
        }
    }

    @Test
    fun onlyTheOwnedCaptureRootAndDigestAreExportable() {
        val root = Files.createTempDirectory("c04c-capture").toFile()
        val outside = Files.createTempDirectory("c04c-outside").toFile()
        val bytes = png()
        val outsideArtifact = artifact(bytes, outside)
        val sink = MemorySink("content://provider/document/outside.png")
        try {
            C04CadCaptureExporter(root).export(outsideArtifact, sink)
            fail("expected artifact")
        } catch (error: C04CadExportFailure) {
            assertEquals("artifact", error.code)
            assertFalse(sink.deleted)
        }

        val artifact = artifact(bytes, root).copy(sha256 = "0".repeat(64))
        try {
            C04CadCaptureExporter(root).export(artifact, sink)
            fail("expected artifactDigest")
        } catch (error: C04CadExportFailure) {
            assertEquals("artifactDigest", error.code)
        }

        val nonContent = MemorySink("file:///sdcard/part-preview.png")
        try {
            C04CadCaptureExporter(root).export(artifact(bytes, root), nonContent)
            fail("expected uri")
        } catch (error: C04CadExportFailure) {
            assertEquals("uri", error.code)
        }
    }
}
