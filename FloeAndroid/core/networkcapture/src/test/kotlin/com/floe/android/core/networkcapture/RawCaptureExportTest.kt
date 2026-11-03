// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RawCaptureExportTest {
    private val root: File = Files.createTempDirectory("floe-raw-export").toFile()

    @After
    fun cleanup() {
        root.deleteRecursively()
    }

    private fun pcap(payload: Int = 20): ByteArray {
        val header = ByteArray(24)
        header[0] = 0xD4.toByte()
        header[1] = 0xC3.toByte()
        header[2] = 0xB2.toByte()
        header[3] = 0xA1.toByte()
        header[4] = 2
        header[6] = 4
        header[20] = 101
        val record = ByteArray(16 + payload) { 0x45 }
        record[8] = payload.toByte()
        return header + record
    }

    private fun digest(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun writeArtifact(
        sessionId: String = UUID.randomUUID().toString(),
        bytes: ByteArray = pcap(),
        complete: Boolean = true,
        fileOverride: String? = null,
        sizeOverride: Long? = null,
        requireValid: Boolean = true,
    ): RawCaptureRecord? {
        val suffix = if (complete) "" else "-partial"
        val name = "capture-$sessionId$suffix.pcap"
        val file = File(root, name)
        file.writeBytes(bytes)
        val owner = JSONObject()
            .put("ownerId", "test")
            .put("nativeEpoch", 1)
        val manifest = JSONObject()
            .put("schema", "floe.capture-artifact.v1")
            .put("sessionId", sessionId)
            .put("mode", "vpn")
            .put("createdAt", 123L)
            .put("endedAt", 456L)
            .put("phase", if (complete) "completed" else "failed")
            .put("endReason", if (complete) JSONObject.NULL else "stopTimeout")
            .put("complete", complete)
            .put("file", fileOverride ?: name)
            .put("bytes", sizeOverride ?: file.length())
            .put("sha256", digest(bytes))
            .put("owner", owner)
            .put("detailed", false)
        File(root, "capture-$sessionId.json").writeText(manifest.toString())
        val record = RawCaptureLibrary(root).find(sessionId)
        if (requireValid) {
            assertNotNull(record)
            return record!!
        }
        return record
    }

    private class MemorySink(
        private val tamperReadback: Boolean = false,
    ) : RawExportSink {
        val written = ByteArrayOutputStream()
        var deleted = false
        override fun openDestination(): OutputStream = object : OutputStream() {
            override fun write(b: Int) = written.write(b)
            override fun write(b: ByteArray, off: Int, len: Int) = written.write(b, off, len)
        }

        override fun openDestinationForRead(): InputStream {
            val bytes = written.toByteArray()
            if (!tamperReadback) return ByteArrayInputStream(bytes)
            return ByteArrayInputStream(bytes + byteArrayOf(0x00))
        }

        override fun deleteCreatedDestination(): Boolean {
            deleted = true
            return true
        }
    }

    @Test
    fun listsAndExportsExactBytesWithDigestReceipt() {
        val record = writeArtifact()!!
        val library = RawCaptureLibrary(root)
        assertEquals(1, library.list().records.size)
        assertEquals(0, library.list().invalid)
        val sink = MemorySink()
        val outcome = RawCaptureExporter().export(record, sink, "floe.pcap")
        assertTrue(outcome is RawExportOutcome.Success)
        val receipt = (outcome as RawExportOutcome.Success).receipt
        assertEquals(record.bytes, receipt.bytes)
        assertEquals(record.sha256, receipt.sha256)
        assertEquals(record.sessionId, receipt.sessionId)
        assertFalse(receipt.partial)
        assertTrue(record.file.readBytes().contentEquals(sink.written.toByteArray()))
        assertFalse(sink.deleted)
    }

    @Test
    fun partialArtifactKeepsItsPartialReceipt() {
        val record = writeArtifact(complete = false)!!
        val outcome = RawCaptureExporter().export(record, MemorySink(), "partial.pcap")
        assertTrue(outcome is RawExportOutcome.Success)
        assertTrue((outcome as RawExportOutcome.Success).receipt.partial)
    }

    @Test
    fun manifestTraversalAndSizeDriftAreHidden() {
        val valid = writeArtifact()!!
        val invalidId = UUID.randomUUID().toString()
        writeArtifact(
            sessionId = invalidId,
            fileOverride = "../../outside.pcap",
            requireValid = false,
        )
        val other = writeArtifact()!!
        val manifest = File(root, "capture-${other.sessionId}.json")
        val tampered = JSONObject(manifest.readText()).put("bytes", 999_999L)
        manifest.writeText(tampered.toString())
        val listing = RawCaptureLibrary(root).list()
        assertEquals(1, listing.records.size)
        assertEquals(valid.sessionId, listing.records[0].sessionId)
        assertEquals(2, listing.invalid)
    }

    @Test
    fun sourceDigestMismatchDeletesOnlyTheNewDestination() {
        val record = writeArtifact()!!
        val changed = record.copy(sha256 = "0".repeat(64))
        val sink = MemorySink()
        val outcome = RawCaptureExporter().export(changed, sink, "floe.pcap")
        assertEquals(RawExportOutcome.Failed("sourceDigestMismatch"), outcome)
        assertTrue(sink.deleted)
        assertTrue(record.file.isFile)
        assertTrue(record.file.length() == record.bytes)
    }

    @Test
    fun readbackMismatchIsNeverReportedAsSuccess() {
        val record = writeArtifact()!!
        val sink = MemorySink(tamperReadback = true)
        val outcome = RawCaptureExporter().export(record, sink, "floe.pcap")
        assertEquals(RawExportOutcome.Failed("destinationVerifyFailed"), outcome)
        assertTrue(sink.deleted)
        assertTrue(record.file.isFile)
    }

    @Test
    fun cancellationAbortsAndDeletesTheCreatedDestination() {
        val record = writeArtifact(bytes = pcap(payload = 20_000))!!
        val sink = MemorySink()
        var cancelled = false
        val outcome = RawCaptureExporter(chunkBytes = 4 * 1024).export(
            record = record,
            sink = sink,
            displayName = "floe.pcap",
            checkCancelled = { cancelled },
            onProgress = { copied, _ -> if (copied >= 4 * 1024) cancelled = true },
        )
        assertEquals(RawExportOutcome.Cancelled, outcome)
        assertTrue(sink.deleted)
        assertTrue(record.file.isFile)
    }

    @Test
    fun extraSourceBytesBeyondManifestAreRejected() {
        val base = pcap(payload = 100)
        val record = writeArtifact(bytes = base)!!
        // Grow the source behind the manifest's back.
        record.file.appendBytes(byteArrayOf(0x45))
        val sink = MemorySink()
        val outcome = RawCaptureExporter().export(record, sink, "floe.pcap")
        assertEquals(RawExportOutcome.Failed("sourceChanged"), outcome)
        assertTrue(sink.deleted)
        assertNull(RawCaptureLibrary(root).find(record.sessionId))
    }
}
