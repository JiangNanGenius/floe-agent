package com.floe.android.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BridgeInstrumentedTest {
    @Test fun realSharedPolicyPreservesUnicodeAndCorrelation() {
        val policy = JSONObject().put("approvalMode", "ask").put("recoveryPolicy", "safePoint").put("notificationPolicy", "critical")
        val input = JSONObject().put("version", 1).put("requestID", "设备-🧊").put("operation", "policy.inspect")
            .put("policy", policy).put("echo", "中文 🧊")
        val output = JSONObject(SwiftCore.exchange(input.toString()))
        assertTrue(output.getBoolean("ok"))
        assertEquals("设备-🧊", output.getString("requestID"))
        assertEquals("中文 🧊", output.getString("echo"))
        assertFalse(output.getBoolean("notifySuccess"))
        assertTrue(output.getBoolean("notifyFailure"))
        assertFalse(output.getBoolean("notifyCancellation"))
    }
    @Test fun rejectsUnknownVersionAndOperation() {
        // Version 2 is now a SUPPORTED envelope version (append-only v2 seam);
        // unknown versions must still fail closed. This assertion was updated
        // with the v2 addition and must be re-run on device (compiled here,
        // device execution remains a Main-owned gate).
        assertEquals("unsupportedVersion", JSONObject(SwiftCore.exchange("""{"version":999,"operation":"handshake"}""")).getString("error"))
        assertEquals("unsupportedOperation", JSONObject(SwiftCore.exchange("""{"version":1,"operation":"exec.shell"}""")).getString("error"))
        assertEquals("unsupportedOperation", JSONObject(SwiftCore.exchange("""{"version":2,"operation":"linux.exec"}""")).getString("error"))
    }
    @Test fun rejectsOversizeAndEmbeddedNull() {
        for (request in listOf("x".repeat(65_537), "\u0000")) {
            assertThrows(IllegalArgumentException::class.java) { SwiftCore.exchange(request) }
        }
    }
    @Test fun v1HandshakeSurfaceIsUnchanged() {
        val output = JSONObject(SwiftCore.exchange("""{"version":1,"requestID":"f","operation":"handshake"}"""))
        assertTrue(output.getBoolean("ok"))
        assertEquals(1, output.getInt("version"))
        assertEquals("f", output.getString("requestID"))
        assertEquals(listOf("handshake", "policy.inspect"),
            output.getJSONArray("operations").let { a -> (0 until a.length()).map(a::getString) })
        assertFalse(output.getBoolean("localLLM"))
    }
    @Test fun v2HandshakeAdvertisesStagedOperationsAsUnbound() {
        val output = JSONObject(SwiftCore.exchange("""{"version":2,"requestID":"h2","operation":"handshake"}"""))
        assertTrue(output.getBoolean("ok"))
        assertEquals(2, output.getInt("version"))
        assertEquals("h2", output.getString("requestID"))
        val ops = output.getJSONArray("operations")
        assertEquals(listOf("handshake", "credential.status"), (0 until ops.length()).map(ops::getString))
        val staged = output.getJSONArray("stagedOperations")
        assertEquals(2, staged.length())
        for (i in 0 until staged.length()) {
            assertFalse(staged.getJSONObject(i).getBoolean("bound"))
        }
    }
    @Test fun v2CredentialStatusIsFailClosed() {
        val backend = JSONObject(
            SwiftCore.exchange("""{"version":2,"requestID":"s","operation":"credential.status"}"""
        )).getJSONObject("secretBackend")
        val registered = backend.getBoolean("registered")
        assertEquals(if (registered) "AVAILABLE" else "NEEDS_CONFIGURATION", backend.getString("availability"))
        assertFalse(backend.getBoolean("memoryFallback"))
    }
    @Test fun v2CorrelationMismatchAndUnboundBinderFailClosed() {
        // Build the owner with Kotlin interpolation and JSONObject, not a
        // Swift-style "\\(...)" sequence: the latter stays literal in a Kotlin
        // raw string and makes the whole request invalid JSON, so the
        // production decoder correctly answered invalidJSON instead of
        // reaching the correlation/unbound checks this test exists to prove.
        val owner = JSONObject()
            .put("taskID", UUID.randomUUID().toString())
            .put("runID", UUID.randomUUID().toString())
            .put("environmentID", UUID.randomUUID().toString())
            .put("jobID", UUID.randomUUID().toString())
        val bad = JSONObject(SwiftCore.exchange(
            """{"version":2,"requestID":"req-1","operation":"command.submit","envelope":{"scope":"taskExecution","owner":${owner},"command":"chat.send","stateful":false,"correlationID":"other"}}"""))
        assertEquals("correlationMismatch", bad.getString("error"))
        val unbound = JSONObject(SwiftCore.exchange(
            """{"version":2,"requestID":"req-2","operation":"command.submit","envelope":{"scope":"taskExecution","owner":${owner},"command":"chat.send","stateful":false,"correlationID":"req-2"}}"""))
        assertEquals("runtimeUnavailable", unbound.getString("error"))
        assertEquals("commandBinderUnbound", unbound.getString("reason"))
    }
}
