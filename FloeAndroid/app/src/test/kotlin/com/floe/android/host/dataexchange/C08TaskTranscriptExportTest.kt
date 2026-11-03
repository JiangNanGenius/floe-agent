// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.dataexchange

import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class C08TaskTranscriptExportTest {
    private class Transport(val badDigest: Boolean = false, val badOffset: Boolean = false, val badJob: Boolean = false,
        val onRead: () -> Unit = {}) : C07DataExchangeTransport {
        val data = ("""{"type":"event","payload":{"summary":"real output"}}""" + "\n").repeat(1500).toByteArray()
        val operations = mutableListOf<String>()
        override fun exchange(request: String): String {
            val value = JSONObject(request)
            val operation = value.getString("operation")
            operations += operation
            val result = JSONObject().put("ok", true)
            when (operation) {
                "c07.document.exportTask" -> {
                    assertEquals("task", value.getString("conversationID"))
                    result.put("jobID", "job")
                }
                "c07.job.status" -> result.put("jobID", if (badJob) "foreign-job" else "job").put("kind", "taskExport")
                    .put("phase", "ready").put("fileByteCount", data.size)
                    .put("fileSHA256", if (badDigest) "0".repeat(64) else MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and 0xff) })
                "c07.job.read" -> {
                    onRead()
                    val offset = value.getInt("offset")
                    val end = minOf(data.size, offset + value.getInt("maxBytes"))
                    result.put("dataBase64", Base64.getEncoder().encodeToString(data.copyOfRange(offset, end)))
                        .put("nextOffset", if (badOffset) end + 1 else end)
                        .put("totalBytes", data.size).put("eof", end == data.size)
                }
                "c07.job.close", "c07.job.cancel" -> Unit
                else -> error("unexpected operation")
            }
            return result.toString()
        }
    }

    @Test fun completeChunkedTranscriptMatchesNativeReceiptAndClosesJob() = runBlocking {
        val root = Files.createTempDirectory("task-export-test").toFile()
        try {
            val transport = Transport()
            val file = C08TaskTranscriptExport.create(root, "task", 1, { true }, C07DataExchangeClient(transport))
            assertArrayEquals(transport.data, file.readBytes())
            assertTrue(transport.operations.count { it == "c07.job.read" } > 1)
            assertEquals("c07.job.close", transport.operations.last())
            assertFalse(transport.operations.contains("c07.job.cancel"))
        } finally { root.deleteRecursively() }
    }

    private fun refuses(transport: Transport, current: () -> Boolean = { true }) = runBlocking {
        val root = Files.createTempDirectory("task-export-refusal").toFile()
        try {
            try {
                C08TaskTranscriptExport.create(root, "task", 1, current, C07DataExchangeClient(transport))
                fail("invalid transcript accepted")
            } catch (_: IllegalArgumentException) { }
              catch (_: IllegalStateException) { }
            assertTrue(root.resolve("task-exports").listFiles().orEmpty().isEmpty())
            if (transport.operations.contains("c07.document.exportTask")) {
                assertTrue(transport.operations.contains("c07.job.cancel"))
                assertEquals("c07.job.close", transport.operations.last())
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun hashMismatchRemovesPartialFileAndCancelsOnlyItsJob() { refuses(Transport(badDigest = true)) }
    @Test fun invalidChunkCursorCannotProduceShareableFile() { refuses(Transport(badOffset = true)) }
    @Test fun replacedOwnerDuringReadCannotPublishFile() {
        var current = true
        refuses(Transport(onRead = { current = false }), { current })
    }
    @Test fun foreignJobReceiptCannotPublishFile() { refuses(Transport(badJob = true)) }
    @Test fun absentOwnerDoesNotCreateNativeJob() { refuses(Transport(), { false }) }
}
