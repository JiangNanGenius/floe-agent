package com.floe.android.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device regression source for the bridge v2 schema repair. These cases must
 * be executed by Main only after the real shared-core `.so`, JNI library and
 * APK are built: every response below is either a typed invalidEnvelope or
 * the fail-closed runtimeUnavailable seam. No case is allowed to report
 * success, and no binder is registered by this class.
 */
@RunWith(AndroidJUnit4::class)
class BridgeEnvelopeV2InstrumentedTest {
    private val task = UUID.randomUUID().toString()
    private val run = UUID.randomUUID().toString()
    private val environment = UUID.randomUUID().toString()
    private val job = UUID.randomUUID().toString()

    private fun ownerJson(jobID: String = job): String =
        """{"taskID":"$task","runID":"$run","environmentID":"$environment","jobID":"$jobID"}"""

    private fun envelope(
        stateful: String = "false",
        revision: String? = null,
        cursor: String? = null,
        correlation: String = "\"c-1\"",
        owner: String = ownerJson(),
    ): String {
        val parts = mutableListOf(
            "\"scope\":\"taskExecution\"",
            "\"owner\":$owner",
            "\"command\":\"chat.send\"",
            "\"stateful\":$stateful",
            "\"correlationID\":$correlation",
        )
        if (revision != null) parts += "\"revision\":$revision"
        if (cursor != null) parts += "\"cursor\":$cursor"
        return parts.joinToString(separator = ",", prefix = "{", postfix = "}")
    }

    private fun request(
        operation: String,
        body: String,
        requestID: String = "c-1",
    ): String = """{"version":2,"requestID":"$requestID","operation":"$operation","envelope":$body}"""

    private fun exchange(request: String): JSONObject = JSONObject(SwiftCore.exchange(request))

    private fun assertInvalid(response: JSONObject, reason: String) {
        assertFalse(response.getBoolean("ok"))
        assertEquals("invalidEnvelope", response.getString("error"))
        assertEquals(reason, response.getString("reason"))
    }

    @Test
    fun numericStatefulIsNotCoercedToBoolean() {
        val revision = """{"resourceID":"r","version":"1"}"""
        for (literal in listOf("0", "1", "0.0", "\"false\"")) {
            val response = exchange(request("command.submit",
                envelope(stateful = literal, revision = revision)))
            assertInvalid(response, "invalidStatefulFlag")
        }
    }

    @Test
    fun eventCursorSequenceRejectsNonIntegerPrimitives() {
        for (literal in listOf("true", "false", "\"1\"", "1.5", "9223372036854775808", "-1")) {
            val cursor = """{"runID":"$run","sequence":$literal}"""
            val response = exchange(request("event.poll",
                envelope(stateful = "false", cursor = cursor), requestID = "p-1"))
            assertInvalid(response, "invalidEventCursor")
        }
    }

    @Test
    fun whitespaceOnlyRevisionAndCorrelationAreRejected() {
        for (revision in listOf(
            """{"resourceID":"   ","version":"1"}""",
            """{"resourceID":"r","version":"\t\n"}""",
        )) {
            val response = exchange(request("command.submit",
                envelope(revision = revision)))
            assertInvalid(response, "invalidRevision")
        }
        val blankCorrelation = exchange(request("command.submit",
            envelope(correlation = "\" \\t \"")))
        assertInvalid(blankCorrelation, "missingCorrelation")
    }

    @Test
    fun validTypedControlStillFailsClosedAtUnboundBinder() {
        val response = exchange(request("command.submit",
            envelope(revision = """{"resourceID":"r","version":"1"}""")))
        assertFalse(response.getBoolean("ok"))
        assertEquals("runtimeUnavailable", response.getString("error"))
        assertEquals("commandBinderUnbound", response.getString("reason"))
    }

    @Test
    fun aliasedRoleIDsParseWithoutGrantingOrExecuting() {
        // Root jobID == runID is a legitimate explicit role alias. Reaching
        // the unbound seam proves structural acceptance only; it must never
        // become execution or authorization success.
        val response = exchange(request("command.submit",
            envelope(owner = ownerJson(jobID = run))))
        assertFalse(response.getBoolean("ok"))
        assertEquals("runtimeUnavailable", response.getString("error"))
        assertEquals("commandBinderUnbound", response.getString("reason"))
    }
}
