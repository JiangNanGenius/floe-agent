// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.dataexchange

import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authored NOTRUN wire regression for the C08 Office draft backup section. */
class C07OfficeDraftBackupTest {
    private class CaptureTransport(
        private val response: JSONObject,
    ) : C07DataExchangeTransport {
        var request: JSONObject? = null
        override fun exchange(request: String): String {
            this.request = JSONObject(request)
            return response.toString()
        }
    }

    @Test
    fun backupBeginCarriesOnlyBoundedContentMetadata() {
        val transport = CaptureTransport(JSONObject().put("ok", true)
            .put("jobID", UUID.randomUUID().toString()))
        val client = C07DataExchangeClient(transport)
        val drafts = JSONObject().apply {
            put("format", "floe.office-drafts/1")
            put("records", JSONArray().put(JSONObject().apply {
                put("root", "working")
                put("relativePath", "${UUID.randomUUID()}/document.docx")
                put("kind", "workingCopy")
                put("displayName", "Report.docx")
                put("format", "docx")
                put("bytes", 12)
                put("sha256", "a".repeat(64))
                put("createdAtMillis", 1_700_000_000_000)
                put("updatedAtMillis", 1_700_000_001_000)
            }))
            put("omissions", JSONArray())
            put("deduplicated", 0)
        }
        client.backupBegin(
            C07ExchangeOwner("owner-token-1234", 7),
            includeRetainedProjects = true,
            officeDrafts = drafts,
        )
        val request = requireNotNull(transport.request)
        assertEquals("c07.backup.begin", request.getString("operation"))
        val sent = request.getJSONObject("officeDrafts")
        assertEquals("floe.office-drafts/1", sent.getString("format"))
        assertEquals(1, sent.getJSONArray("records").length())
        val record = sent.getJSONArray("records").getJSONObject(0)
        assertEquals("working", record.getString("root"))
        assertFalse(record.has("candidateID"))
        assertFalse(record.has("sessionToken"))
        assertFalse(record.has("taskID"))
        assertFalse(record.has("destinationUri"))
        assertFalse(record.has("nativeGeneration"))
    }

    @Test
    fun planAndReceiptExposeTheOfficeDraftCount() {
        val transport = CaptureTransport(JSONObject().put("ok", true)
            .put("jobID", UUID.randomUUID().toString())
            .put("kind", "restore")
            .put("phase", "ready")
            .put("plan", JSONObject().put("officeDrafts", 2)
                .put("officeDraftBytes", 4096))
            .put("receipt", JSONObject().put("officeDrafts", 2)))
        val job = C07DataExchangeClient(transport).status(
            C07ExchangeOwner("owner-token-1234", 7),
            UUID.randomUUID().toString(),
        )
        assertEquals(2, job.plan?.officeDrafts ?: -1)
        assertEquals(4096L, job.plan?.officeDraftBytes ?: -1L)
        assertEquals(2, job.receipt?.officeDrafts ?: -1)
        assertTrue(job.canCommit.not())
    }
}
