// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.TimeoutCancellationException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RuntimeMetadataReadTest {
    private fun envelope(value: JSONObject) = JSONObject().put("ok", true).put("result", value)

    @Test fun directInstalledSnapshotIsUnchanged() = runBlocking {
        val snapshot = JSONObject().put("phase", "installed")
        assertSame(snapshot, RuntimeMetadataRead.read("install.status") { op, _, _ ->
            assertEquals("install.status", op)
            envelope(snapshot)
        })
    }

    @Test fun queuedCatalogPollsOriginalReceiptWithoutResubmission() = runBlocking {
        var original = ""
        val calls = mutableListOf<String>()
        val catalog = JSONObject().put("environments", org.json.JSONArray())
        val actual = RuntimeMetadataRead.read("environment.list") { op, payload, requestID ->
            calls += op
            if (op == "environment.list") {
                original = requestID
                envelope(JSONObject().put("requestID", requestID).put("state", "queued"))
            } else {
                assertEquals(original, payload.getString("requestID"))
                assertNotEquals(original, requestID)
                envelope(JSONObject().put("requestID", original)
                    .put("state", if (calls.size == 2) "running" else "completed")
                    .also { if (calls.size == 3) it.put("result", catalog) })
            }
        }
        assertSame(catalog, actual)
        assertEquals(listOf("environment.list", "request.status", "request.status"), calls)
    }

    @Test fun foreignReceiptCannotPublishMetadata() = runBlocking {
        try {
            RuntimeMetadataRead.read("environment.list") { _, _, _ ->
                envelope(JSONObject().put("requestID", "foreign").put("state", "completed")
                    .put("result", JSONObject().put("environments", org.json.JSONArray())))
            }
            fail("foreign receipt accepted")
        } catch (expected: IllegalStateException) {
            assertEquals("metadataReceiptMismatch", expected.message)
        }
    }

    @Test fun failedReceiptDoesNotBecomeAnEmptyCatalog() = runBlocking {
        var calls = 0
        try {
            RuntimeMetadataRead.read("environment.list") { _, _, id ->
                calls++
                envelope(JSONObject().put("requestID", id).put("state", "failed"))
            }
            fail("failed receipt accepted")
        } catch (expected: IllegalStateException) {
            assertEquals("metadataRequestUnsettled", expected.message)
        }
        assertEquals(1, calls)
    }

    @Test fun deadlineDoesNotResubmitOrCancelAnotherWorkload() = runBlocking {
        var submissions = 0
        var original = ""
        try {
            RuntimeMetadataRead.read("environment.list", timeoutMillis = 60) { op, payload, id ->
                if (op == "environment.list") { submissions++; original = id }
                else { assertEquals("request.status", op); assertEquals(original, payload.getString("requestID")) }
                envelope(JSONObject().put("requestID", original).put("state", "running"))
            }
            fail("deadline not enforced")
        } catch (_: TimeoutCancellationException) { }
        assertEquals(1, submissions)
    }
}
