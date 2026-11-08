// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ConversationTaskExportTest {
    @Test fun recreatedActivityCannotLaunchTheSamePickerTwice() {
        val slot = TaskExportPickerSlot<String?>()
        val (request, result) = slot.admit("task.jsonl")
        assertTrue(slot.claimLaunch(request.id))
        assertFalse(slot.claimLaunch(request.id))
        assertTrue(slot.complete(request.id, "actual-destination"))
        assertEquals("actual-destination", runBlocking { result.await() })
        assertNull(slot.requests.value)
    }

    @Test fun abandonedLaunchedPickerCannotDeliverItsUriToTheNextTask() {
        val slot = TaskExportPickerSlot<String?>()
        val (old, result) = slot.admit("old.jsonl")
        assertTrue(slot.claimLaunch(old.id))
        slot.abandon(old.id)
        assertTrue(result.isCancelled)
        try { slot.admit("next.jsonl"); fail("old OS picker must still own its slot") }
        catch (_: IllegalStateException) { }
        assertTrue(slot.complete(old.id, "old-uri"))
        val (next, nextResult) = slot.admit("next.jsonl")
        assertFalse(slot.complete(old.id, "late-old-uri"))
        assertFalse(nextResult.isCompleted)
        assertTrue(slot.complete(next.id, "new-uri"))
        assertEquals("new-uri", runBlocking { nextResult.await() })
    }

    @Test fun cancellationBeforeLaunchAndRealPickerCancelReleaseTheirOwnSlots() {
        val slot = TaskExportPickerSlot<String?>()
        val (first, _) = slot.admit("first.jsonl")
        slot.abandon(first.id)
        assertFalse(slot.claimLaunch(first.id))
        val (second, result) = slot.admit("second.jsonl")
        assertTrue(slot.claimLaunch(second.id))
        assertTrue(slot.complete(second.id, null))
        assertNull(runBlocking { result.await() })
        assertNotNull(slot.admit("third.jsonl"))
    }

    @Test fun staleLaunchFailureCannotClearANewerRequest() {
        val slot = TaskExportPickerSlot<String?>()
        val (first, _) = slot.admit("first.jsonl")
        assertTrue(slot.fail(first.id, IOException("no activity")))
        val (next, result) = slot.admit("next.jsonl")
        assertFalse(slot.fail(first.id, IOException("late")))
        assertEquals(next, slot.requests.value)
        assertFalse(result.isCompleted)
    }

    @Test fun savedReceiptRequiresCompleteChunkedDestinationReadback() = runBlocking {
        val directory = Files.createTempDirectory("task-document-save").toFile()
        try {
            val bytes = ("{\"type\":\"event\",\"summary\":\"real tool output\"}\n").repeat(6000).toByteArray()
            val source = directory.resolve("task.jsonl").apply { writeBytes(bytes) }
            val output = ByteArrayOutputStream()
            val receipt = TaskTranscriptDocumentWriter.write(source, { output },
                { ByteArrayInputStream(output.toByteArray()) }, { true })
            assertEquals(bytes.size.toLong(), receipt.bytes)
            val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
            assertEquals(sha, receipt.sha256)
            assertArrayEquals(bytes, output.toByteArray())
            assertArrayEquals(bytes, source.readBytes())
        } finally { directory.deleteRecursively() }
    }

    @Test fun providerCorruptionOrTruncationNeverProducesASavedReceipt() = runBlocking {
        val directory = Files.createTempDirectory("task-document-corrupt").toFile()
        try {
            val source = directory.resolve("task.jsonl").apply { writeText("original transcript\n") }
            for (readback in listOf("", "original transcript!")) {
                try {
                    TaskTranscriptDocumentWriter.write(source, { ByteArrayOutputStream() },
                        { ByteArrayInputStream(readback.toByteArray()) }, { true })
                    fail("unverified destination accepted")
                } catch (_: IllegalArgumentException) { }
                assertEquals("original transcript\n", source.readText())
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun retiredOwnerStopsTransferAndKeepsTheSource() = runBlocking {
        val directory = Files.createTempDirectory("task-document-retire").toFile()
        try {
            val source = directory.resolve("task.jsonl").apply { writeBytes(ByteArray(200_000) { 7 }) }
            var current = true
            val output = object : ByteArrayOutputStream() {
                override fun write(bytes: ByteArray, off: Int, len: Int) {
                    super.write(bytes, off, len)
                    current = false
                }
            }
            try {
                TaskTranscriptDocumentWriter.write(source, { output },
                    { fail("retired operation read back a destination"); ByteArrayInputStream(byteArrayOf()) }, { current })
                fail("retired operation saved")
            } catch (_: IllegalStateException) { }
            assertTrue(output.size() in 1 until source.length().toInt())
            assertEquals(200_000L, source.length())
        } finally { directory.deleteRecursively() }
    }

    @Test fun missingSourceAndStalledReadbackFailWithoutFalseSuccess() = runBlocking {
        val directory = Files.createTempDirectory("task-document-invalid").toFile()
        try {
            try {
                TaskTranscriptDocumentWriter.write(directory.resolve("absent"),
                    { fail("invalid source opened a destination"); ByteArrayOutputStream() },
                    { ByteArrayInputStream(byteArrayOf()) }, { true })
                fail("missing source saved")
            } catch (_: IllegalArgumentException) { }
            val source = directory.resolve("task.jsonl").apply { writeText("original\n") }
            val stalled = object : InputStream() {
                override fun read(): Int = 0
                override fun read(buffer: ByteArray, off: Int, len: Int): Int = 0
            }
            try {
                TaskTranscriptDocumentWriter.write(source, { ByteArrayOutputStream() }, { stalled }, { true })
                fail("stalled readback accepted")
            } catch (_: IOException) { }
            assertEquals("original\n", source.readText())
        } finally { directory.deleteRecursively() }
    }
}
