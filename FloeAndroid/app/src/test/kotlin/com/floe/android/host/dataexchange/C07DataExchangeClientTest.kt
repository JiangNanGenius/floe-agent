// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.dataexchange

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class C07DataExchangeClientTest {
    private class FakeTransport : C07DataExchangeTransport {
        val requests = mutableListOf<JSONObject>()
        var failNext = false

        override fun exchange(request: String): String {
            val value = JSONObject(request)
            requests += value
            if (failNext) {
                failNext = false
                return JSONObject()
                    .put("ok", false)
                    .put("code", "hashMismatch")
                    .put("reason", "resource")
                    .put("retryable", false)
                    .toString()
            }
            return when (value.optString("operation")) {
                "c07.capabilities" -> JSONObject()
                    .put("ok", true)
                    .put("formatVersion", 1)
                    .put("backupExtension", "floebackup")
                    .put("notesExtension", "floenote")
                    .put("chunkBytes", 24_576)
                    .put("databaseCopied", false)
                    .put("included", JSONArray().put("managedProjects").put("notesDocuments"))
                    .put("excluded", JSONArray().put(JSONObject()
                        .put("id", "credentials").put("reason", "neverExported")))
                    .toString()
                "c07.backup.begin" -> JSONObject()
                    .put("ok", true).put("jobID", "11111111-1111-1111-1111-111111111111")
                    .toString()
                "c07.job.status" -> JSONObject()
                    .put("ok", true)
                    .put("jobID", value.optString("jobID"))
                    .put("kind", "backup")
                    .put("phase", "ready")
                    .put("doneBytes", 3)
                    .put("totalBytes", 3)
                    .put("warnings", JSONArray())
                    .put("fileByteCount", 3)
                    .put("fileSHA256", "abc")
                    .put("canCommit", false)
                    .put("plan", JSONObject()
                        .put("projects", 1).put("projectFiles", 2)
                        .put("noteDocuments", 0).put("noteResources", 0)
                        .put("notebooks", 0).put("settingsKeys", 0)
                        .put("trashedNotesExcluded", 0).put("skippedProjects", 0))
                    .toString()
                "c07.job.read" -> JSONObject()
                    .put("ok", true)
                    .put("offset", value.optLong("offset"))
                    .put("nextOffset", value.optLong("offset") + 3)
                    .put("totalBytes", 3)
                    .put("eof", true)
                    .put("dataBase64", java.util.Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3)))
                    .toString()
                "c07.restore.stageBegin" -> JSONObject()
                    .put("ok", true)
                    .put("stageID", "22222222-2222-2222-2222-222222222222")
                    .put("chunkBytes", 24_576)
                    .put("totalBytes", value.optLong("byteCount"))
                    .toString()
                "c07.restore.stageAppend" -> JSONObject()
                    .put("ok", true)
                    .put("receivedBytes", 3)
                    .put("totalBytes", 3)
                    .toString()
                "c07.restore.inspect" -> JSONObject()
                    .put("ok", true).put("jobID", "33333333-3333-3333-3333-333333333333")
                    .toString()
                "c07.restore.pending" -> JSONObject()
                    .put("ok", true).put("pendingRecoveries", 0).toString()
                else -> JSONObject().put("ok", true).toString()
            }
        }
    }

    private fun owner() = C07ExchangeOwner("a".repeat(32), 7)

    @Test
    fun capabilitiesCarrySchemaAndExcludedScope() {
        val transport = FakeTransport()
        val client = C07DataExchangeClient(transport)
        val capabilities = client.capabilities(owner())
        assertEquals(1, capabilities.formatVersion)
        assertEquals("floebackup", capabilities.backupExtension)
        assertEquals(24_576, capabilities.chunkBytes)
        assertFalse(capabilities.databaseCopied)
        assertEquals(listOf("managedProjects", "notesDocuments"), capabilities.included)
        assertEquals("credentials", capabilities.excluded.single().first)
        val request = transport.requests.single()
        assertEquals(16, request.getInt("version"))
        assertEquals("floe.data/16", request.getString("schema"))
        assertEquals(7L, request.getJSONObject("owner").getLong("nativeEpoch"))
    }

    @Test
    fun backupStatusPlanAndChunkAreBounded() {
        val transport = FakeTransport()
        val client = C07DataExchangeClient(transport)
        val jobID = client.backupBegin(owner(), includeRetainedProjects = true)
        assertEquals("11111111-1111-1111-1111-111111111111", jobID)
        val status = client.status(owner(), jobID)
        assertTrue(status.terminal)
        assertEquals("ready", status.phase)
        assertEquals(3L, status.fileByteCount)
        assertEquals(2, status.plan?.projectFiles)
        assertFalse(status.canCommit)
        val chunk = client.read(owner(), jobID, 0, C07DataExchangeClient.MAX_CHUNK)
        assertArrayEquals(byteArrayOf(1, 2, 3), chunk.data)
        assertEquals(3L, chunk.nextOffset)
        assertTrue(chunk.eof)
        val append = transport.requests.last { it.getString("operation") == "c07.job.read" }
        assertTrue(append.getLong("offset") == 0L)
    }

    @Test
    fun stageAppendUsesBoundChunkSizeAndBase64() {
        val transport = FakeTransport()
        val client = C07DataExchangeClient(transport)
        val stage = client.stageBegin(owner(), 3)
        assertEquals(24_576, stage.chunkBytes)
        val sent = client.stageAppend(owner(), stage.stageID, byteArrayOf(9, 8, 7))
        assertEquals(3L, sent.first)
        val request = transport.requests.last()
        assertEquals("c07.restore.stageAppend", request.getString("operation"))
        assertArrayEquals(
            byteArrayOf(9, 8, 7),
            java.util.Base64.getDecoder().decode(request.getString("dataBase64")),
        )
        assertTrue(request.toString().length < C07DataExchangeClient.MAX_CHUNK * 2)
    }

    @Test
    fun bridgeFailureKeepsTypedCode() {
        val transport = FakeTransport()
        val client = C07DataExchangeClient(transport)
        transport.failNext = true
        val failure = assertThrows(C07ClientFailure::class.java) {
            client.capabilities(owner())
        }
        assertEquals("hashMismatch", failure.code)
        assertFalse(failure.retryable)
    }
}
