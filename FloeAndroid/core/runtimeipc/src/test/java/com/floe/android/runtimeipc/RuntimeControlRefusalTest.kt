// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused C06 regression: the binder's failure classification must never
 * collapse every IllegalStateException into the historical `runtime_not_ready`
 * code, because that code was consumed as proof that nothing had been
 * admitted. Only the closed typed refusals may carry that meaning.
 */
class RuntimeControlRefusalTest {

    @Test
    fun typedPreAdmissionRefusalsKeepTheirOwnCode() {
        assertEquals(
            "runtime_foreground_inactive",
            RuntimeControlRefusal.codeOf(
                RuntimeOperationRefused(RuntimeAdmissionRefusal.FOREGROUND_INACTIVE)))
        assertEquals(
            "runtime_stopping",
            RuntimeControlRefusal.codeOf(
                RuntimeOperationRefused(RuntimeAdmissionRefusal.STOPPING)))
        assertEquals(
            "runtime_workspace_grant_missing",
            RuntimeControlRefusal.codeOf(
                RuntimeOperationRefused(RuntimeAdmissionRefusal.WORKSPACE_GRANT_MISSING)))
    }

    @Test
    fun anUnclassifiedIllegalStateIsNeverReportedAsPreAdmissionProof() {
        val code = RuntimeControlRefusal.codeOf(IllegalStateException("private details"))
        assertEquals("runtime_state_unknown", code)
        assertFalse("the old ambiguous catch-all must not be emitted", code == "runtime_not_ready")
    }

    @Test
    fun genericArgumentFailureIsAmbiguousAfterDispatch() {
        assertEquals(RuntimeControlRefusal.UNCERTAIN,
            RuntimeControlRefusal.codeOf(IllegalArgumentException("bad payload")))
        assertEquals(RuntimeControlRefusal.UNCERTAIN,
            RuntimeControlRefusal.codeOf(org.json.JSONException("bad json")))
    }

    @Test
    fun unrelatedRuntimeFailuresAreNotTurnedIntoRefusals() {
        assertNull(RuntimeControlRefusal.codeOf(RuntimeException("transport exploded")))
    }

    @Test
    fun everyClosedRefusalCodeIsABoundedWireToken() {
        val token = Regex("^[a-z][a-z0-9_]{0,47}$")
        val codes = RuntimeAdmissionRefusal.values().map { it.code }
        assertEquals("codes stay unique", codes.size, codes.toSet().size)
        for (code in codes) {
            assertTrue("not a bounded wire token: $code", token.matches(code))
        }
    }
}
