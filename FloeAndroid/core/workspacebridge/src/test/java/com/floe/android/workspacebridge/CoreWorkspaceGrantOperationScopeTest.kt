// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G04-R2 terminal operation grant consumer — focused pure JVM boundary tests
 * for the UI operation-lease lane of [CoreWorkspaceGrant] (the same module-
 * local seam as the retained [CoreWorkspaceGrantRefusalTokenTest]).
 * AUTHORED NOT RUN here: Main's combined batch executes these together with
 * the Swift producer side — the Kotlin consumer compiles against the new C
 * symbol only at link time, so both halves land in the SAME batch or neither.
 *
 * Everything asserted is the closed, module-local decision grammar; the full
 * factory additionally needs the Core app Context and is exercised by Main's
 * grouped compile + device acceptance. The operation lane may only ever
 * REFUSE more, never less: every run/job assertion below proves the ordinary
 * paths stay byte-for-byte unconstrained.
 */
class CoreWorkspaceGrantOperationScopeTest {

    /** Canonical UPPERCASE UUID shape — the WorkspaceStrict.canonicalUUID form
     *  the frozen native envelope echoes for an operation-scoped binding. */
    private val trustedOperation = "0F9E1D2B-3C4A-4B5D-8E6F-7A8B9C0D1E2F"
    private val foreignOperation = "11A2B3C4-D5E6-4F70-8192-A3B4C5D6E7F8"
    private val jobCall = "jobs.55667766-ABCD-EF12-3456-56789ABCDEF0"

    /** Implements every ABSTRACT interface member (the run/job mints record
     *  their routing) but deliberately does NOT override bindingForOperation,
     *  so the operation lane runs the interface DEFAULT null. */
    private open class BaselineAuthority : WorkspaceNativeAuthority {
        val calls = mutableListOf<String>()
        var runReply: ByteArray? = null
        var callReply: ByteArray? = null

        override fun binding(rootEpoch: Long, runID: String, grantID: String): ByteArray? {
            calls += "binding($rootEpoch,$runID,$grantID)"
            return runReply
        }

        override fun bindingForCall(rootEpoch: Long, runID: String, toolCallID: String?, grantID: String): ByteArray? {
            calls += "bindingForCall($rootEpoch,$runID,$toolCallID,$grantID)"
            return callReply
        }

        override fun openSession(bindingJson: ByteArray): ByteArray =
            JSONObject().put("ok", false).put("code", "grantNotMinted").toString().toByteArray()

        override fun baselineBegin(sessionKey: String): ByteArray = "{}".toByteArray()
        override fun baselineHeader(sessionKey: String, index: Long): ByteArray = "{}".toByteArray()
        override fun baselineOpenData(sessionKey: String, index: Long): Int = -1
        override fun baselineFinish(sessionKey: String, appliedCount: Long, appliedBytes: Long): ByteArray = "{}".toByteArray()
        override fun exportBegin(sessionKey: String): ByteArray = "{}".toByteArray()
        override fun exportStage(sessionKey: String, headerJson: ByteArray, dataFd: Int): ByteArray = "{}".toByteArray()
        override fun exportFinish(sessionKey: String): ByteArray = "{}".toByteArray()
        override fun abort(sessionKey: String, reason: String): ByteArray = "{}".toByteArray()
        override fun closeSession(sessionKey: String): Int = 0
        override fun stats(): ByteArray = "{}".toByteArray()
        override fun sweep(nowSeconds: Long, graceSeconds: Long): ByteArray = "{}".toByteArray()
    }

    /** An authority that DOES implement the operation lane (the Core app's
     *  adapter shape): records the exact mint identity and returns a canned
     *  reply. */
    private class OperationAuthority : BaselineAuthority() {
        var operationReply: ByteArray? = null

        override fun bindingForOperation(rootEpoch: Long, operationID: String, runID: String, grantID: String): ByteArray? {
            calls += "bindingForOperation($rootEpoch,$operationID,$runID,$grantID)"
            return operationReply
        }
    }

    private fun operationReply(
        operationID: String?,
        runID: String = "RUN-1",
        rootEpoch: Long = 7L,
        grantID: String = "GRANT-1",
    ): JSONObject = JSONObject()
        .put("ok", true)
        .put("version", WorkspaceBridgeWire.VERSION)
        .put("projectID", "P-1")
        .put("runID", runID)
        .put("workspaceID", "W-1")
        .put("rootEpoch", rootEpoch)
        .put("grantID", grantID)
        .put("workspaceFingerprint", "F-1")
        .put("proof", "PROOF-1")
        .put("budgets", JSONObject())
        .also { if (operationID != null) it.put("operationID", operationID) }

    // MARK: 1. Default-null unsupported authority fails closed (no grant).

    @Test fun authorityWithoutOperationLaneDefaultsToNull() {
        val authority = BaselineAuthority()
        // The interface default itself: no override, no mint.
        assertNull(authority.bindingForOperation(7L, trustedOperation, "RUN-1", "GRANT-1"))
        // Routing a lease identity to such an authority yields NO binding
        // bytes; create() maps that to the existing REFUSAL_BINDING_UNPARSABLE
        // null return — never a fallback to the run/job mints.
        assertNull(CoreWorkspaceGrant.selectBindingBytes(authority, 7L, "RUN-1", "GRANT-1", null, trustedOperation))
        assertEquals(emptyList<String>(), authority.calls)
    }

    // MARK: 2. Exact operation-vs-run-vs-job routing.

    @Test fun leaseIdentityRoutesToOperationMintOnly() {
        val authority = OperationAuthority()
        val reply = "REPLY".toByteArray()
        authority.operationReply = reply
        val bytes = CoreWorkspaceGrant.selectBindingBytes(authority, 7L, "RUN-1", "GRANT-1", null, trustedOperation)
        assertSame(reply, bytes)
        assertEquals(listOf("bindingForOperation(7,$trustedOperation,RUN-1,GRANT-1)"), authority.calls)
    }

    @Test fun ordinaryAndDurableJobRoutingStayUnchanged() {
        val authority = OperationAuthority()
        val runReply = "RUN-REPLY".toByteArray()
        val callReply = "CALL-REPLY".toByteArray()
        authority.runReply = runReply
        authority.callReply = callReply
        // No lease, no call id: the ORIGINAL in-run mint.
        assertSame(runReply, CoreWorkspaceGrant.selectBindingBytes(authority, 3L, "RUN-9", "G-9", null, null))
        // Durable-job claim without a lease: the jobs.<UUID> mint.
        assertSame(callReply, CoreWorkspaceGrant.selectBindingBytes(authority, 3L, "RUN-9", "G-9", jobCall, null))
        assertEquals(
            listOf("binding(3,RUN-9,G-9)", "bindingForCall(3,RUN-9,$jobCall,G-9)"),
            authority.calls,
        )
    }

    // MARK: 3. Dual identity and malformed lease tokens refuse BEFORE mint.

    @Test fun dualJobAndLeaseIdentityRefusesBeforeMint() {
        // Factory-level fail-closed even if a caller bypassed the pump's
        // mutual-exclusion require: durable claim + operation lease together
        // is arguments-invalid, reusing the existing closed branch token.
        assertTrue(CoreWorkspaceGrant.operationArgumentsRejected(jobCall, trustedOperation))
        assertTrue(CoreWorkspaceGrant.operationArgumentsRejected("any-other-call-id", trustedOperation))
        // Ordinary run, durable job and well-formed lease inputs are all
        // unconstrained by this guard.
        assertFalse(CoreWorkspaceGrant.operationArgumentsRejected(null, null))
        assertFalse(CoreWorkspaceGrant.operationArgumentsRejected(jobCall, null))
        assertFalse(CoreWorkspaceGrant.operationArgumentsRejected(null, trustedOperation))
    }

    @Test fun malformedEmptyOversizeNonAsciiLeaseTokensRefuse() {
        // Empty: the pump collapses "" to null, but a factory caller passing
        // an empty token must also refuse before mint.
        assertTrue(CoreWorkspaceGrant.operationArgumentsRejected(null, ""))
        // Oversize: 65 printable chars, one past the frozen identifier bound.
        assertTrue(CoreWorkspaceGrant.operationArgumentsRejected(null, "A".repeat(65)))
        assertFalse(CoreWorkspaceGrant.operationArgumentsRejected(null, "A".repeat(64)))
        // Non-ASCII / control / space: the printable-ASCII grammar of the
        // existing JNI identifier() and the native UUID check.
        assertTrue(CoreWorkspaceGrant.operationArgumentsRejected(null, "op eration"))          // space 0x20
        assertTrue(CoreWorkspaceGrant.operationArgumentsRejected(null, "op\u0000eration"))    // control
        assertTrue(CoreWorkspaceGrant.operationArgumentsRejected(null, "op\u007Feration"))    // DEL
        assertTrue(CoreWorkspaceGrant.operationArgumentsRejected(null, "op\u00E9ration"))     // non-ASCII
        assertFalse(CoreWorkspaceGrant.operationArgumentsRejected(null, trustedOperation))
    }

    // MARK: 4. Foreign/malformed echo and leaked job scope cannot openSession.

    @Test fun foreignOrMismatchedOperationEchoRefuses() {
        // Exact case-sensitive echo of the trusted canonical identity.
        assertTrue(CoreWorkspaceGrant.operationReplyInScope(operationReply(trustedOperation), trustedOperation))
        assertFalse(CoreWorkspaceGrant.operationReplyInScope(operationReply(foreignOperation), trustedOperation))
        assertFalse(CoreWorkspaceGrant.operationReplyInScope(operationReply(null), trustedOperation))
        assertFalse(CoreWorkspaceGrant.operationReplyInScope(operationReply(trustedOperation.lowercase()), trustedOperation))
    }

    @Test fun operationReplyCarryingJobScopeRefuses() {
        // A binding carrying BOTH scopes is a widened object: refuse even if
        // the native strict parse ever let it through.
        val withToolCall = operationReply(trustedOperation).put("toolCallID", jobCall)
        assertFalse(CoreWorkspaceGrant.operationReplyInScope(withToolCall, trustedOperation))
        val withJobID = operationReply(trustedOperation).put("jobID", foreignOperation.lowercase())
        assertFalse(CoreWorkspaceGrant.operationReplyInScope(withJobID, trustedOperation))
    }

    @Test fun ordinaryRunAndJobRepliesPreserveScopeAndRejectUnrequestedOperation() {
        // Historical run/job replies keep their existing scope members and
        // continue to pass. The newly introduced operation scope must match
        // an explicit trusted request; it cannot widen an old route.
        assertTrue(CoreWorkspaceGrant.operationReplyInScope(operationReply(null), null))
        val jobReply = operationReply(null)
            .put("toolCallID", jobCall)
            .put("jobID", "55667766-abcd-ef12-3456-56789abcdef0")
        assertTrue(CoreWorkspaceGrant.operationReplyInScope(jobReply, null))
        // A stray new operation scope is refused when the caller selected
        // the historical run/job route (previous native grammar refused it).
        assertFalse(CoreWorkspaceGrant.operationReplyInScope(operationReply(foreignOperation), null))
    }

    // MARK: 5. Closed refusal vocabulary: no new tokens, no new native codes.

    @Test fun operationLaneReusesTheExistingClosedTokens() {
        assertEquals("grant_arguments_invalid", CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_ARGUMENTS_INVALID, null))
        assertEquals("grant_identity_mismatch", CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_IDENTITY_MISMATCH, null))
        // bindingForOperation refusals are the frozen flat codes (the same
        // closed envelope as binding/_for_call) — already enumerated.
        assertEquals("bindingUnavailable", CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED, "bindingUnavailable"))
        assertEquals("epochNotCurrent", CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED, "epochNotCurrent"))
        assertEquals("invalidArguments", CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED, "invalidArguments"))
        // The branch set and native code set are UNCHANGED in size and
        // membership (the retained CoreWorkspaceGrantRefusalTokenTest asserts
        // the same sets; this restates it for the consumer handoff).
        assertEquals(
            setOf(
                "grant_arguments_invalid", "grant_peer_refused",
                "grant_binding_unparsable", "grant_binding_refused",
                "grant_identity_mismatch", "grant_open_unparsable",
                "grant_open_refused", "grant_session_key_malformed",
            ),
            CoreWorkspaceGrant.BRANCH_REFUSAL_TOKENS,
        )
        assertEquals(9, CoreWorkspaceGrant.NATIVE_REFUSAL_CODES.size)
        assertTrue("bindingUnavailable" in CoreWorkspaceGrant.NATIVE_REFUSAL_CODES)
    }

    @Test fun matchingOperationReplyKeepsEveryExistingCheck() {
        // The operation reply carries the SAME envelope members as an ordinary
        // binding, so the pre-existing runID/rootEpoch/grantID equality checks
        // plus the unchanged openSession/sessionKey grammar apply identically;
        // this asserts a conforming reply passes every NEW gate so the flow
        // reaches those retained checks.
        val reply = operationReply(trustedOperation, runID = "RUN-1", rootEpoch = 7L, grantID = "GRANT-1")
        assertEquals("RUN-1", reply.getString("runID"))
        assertEquals(7L, reply.getLong("rootEpoch"))
        assertEquals("GRANT-1", reply.getString("grantID"))
        assertTrue(CoreWorkspaceGrant.operationReplyInScope(reply, trustedOperation))
        assertTrue(reply.getString("operationID") == trustedOperation)
        assertFalse(reply.has("toolCallID"))
        assertFalse(reply.has("jobID"))
    }
}
