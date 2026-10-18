package com.floe.android.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
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
        assertEquals("unsupportedVersion", JSONObject(SwiftCore.exchange("""{"version":2,"operation":"handshake"}""")).getString("error"))
        assertEquals("unsupportedOperation", JSONObject(SwiftCore.exchange("""{"version":1,"operation":"exec.shell"}""")).getString("error"))
    }
    @Test fun rejectsOversizeAndEmbeddedNull() {
        for (request in listOf("x".repeat(65_537), "\u0000")) {
            assertThrows(IllegalArgumentException::class.java) { SwiftCore.exchange(request) }
        }
    }
}
