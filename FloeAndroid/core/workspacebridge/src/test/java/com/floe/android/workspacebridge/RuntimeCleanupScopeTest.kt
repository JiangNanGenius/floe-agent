// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * G03-R3 (job-7e9db10b801940c2): the frozen Core cleanup control grammar
 * must parse EXACTLY or not at all (a malformed scope can never reach the
 * deletion engine), and the typed results must echo the claimed scope and
 * bound reason shape.
 */
class RuntimeCleanupScopeTest {
    private val conversation = "0F66A2F0-6CFA-4B6E-9E5F-3E9D2B5C7A11"
    private val project = "5AA3F1C2-1D2E-4A6B-8C9D-0E1F2A3B4C5D"
    private val key = "0123456789abcdef0123456789abcdef"

    private fun validControl(): JSONObject = JSONObject()
        .put("requestID", "a".repeat(32))
        .put("operation", "runtimeWorkspaceCopies.clear")
        .put("deletionSet", "targetProjectScope")
        .put("conversationID", conversation)
        .put("projectID", project)
        .put("targetEpoch", 7)
        .put("workspaceRelativePath", "PrivateTasks/$conversation")
        .put("provenTotal", 1)
        .put("evidenceSessionKeys", org.json.JSONArray().put(key))
        .put("evidenceTruncated", false)

    @Test fun validControlParsesWithExactCaseScope() {
        val scope = RuntimeCleanupScope.parse(validControl())
        assertNotNull(scope)
        scope!!
        // exact canonical owner UUID case preserved, never reformatted
        assertEquals(conversation, scope.conversationID)
        assertEquals(project, scope.projectID)
        assertEquals(7L, scope.targetEpoch)
        assertEquals(listOf(key), scope.evidenceSessionKeys)
        assertFalse(scope.evidenceTruncated)
    }

    @Test fun extraOrMissingKeysRefuse() {
        val extra = validControl().put("extraPath", "/data/data/other")
        assertNull(RuntimeCleanupScope.parse(extra))
        assertNull(RuntimeCleanupScope.parse(validControl().apply { remove("requestID") }))
        assertNull(RuntimeCleanupScope.parse(validControl().apply { remove("provenTotal") }))
    }

    @Test fun scopeIdentityMismatchesRefuse() {
        // wrong operation / deletion set
        assertNull(RuntimeCleanupScope.parse(validControl().put("operation", "shell.cancel")))
        assertNull(RuntimeCleanupScope.parse(validControl().put("deletionSet", "prefixMatch")))
        // path prefix or different conversation shape
        assertNull(RuntimeCleanupScope.parse(validControl().put("workspaceRelativePath", "PrivateTasks")))
        assertNull(RuntimeCleanupScope.parse(validControl()
            .put("workspaceRelativePath", "PrivateTasks/11111111-1111-1111-1111-111111111111")))
        // requestID namespace: Core 32-hex only, never a wire UUID
        assertNull(RuntimeCleanupScope.parse(validControl()
            .put("requestID", "0f66a2f0-6cfa-4b6e-9e5f-3e9d2b5c7a11")))
        assertNull(RuntimeCleanupScope.parse(validControl().put("requestID", "A".repeat(32))))
        // zero epoch is never a scope identity
        assertNull(RuntimeCleanupScope.parse(validControl().put("targetEpoch", 0)))
        assertNull(RuntimeCleanupScope.parse(validControl().put("targetEpoch", true)))
        assertNull(RuntimeCleanupScope.parse(validControl().put("targetEpoch", 1.5)))
        assertNull(RuntimeCleanupScope.parse(validControl().put("provenTotal", -1)))
    }

    @Test fun evidenceKeysAreBoundedDiagnosticsOnly() {
        val array = org.json.JSONArray()
        for (index in 0 until 17) array.put(("%032x".format(index)))
        assertNull(RuntimeCleanupScope.parse(validControl().put("evidenceSessionKeys", array)))
        // 16 keys is the bounded diagnostic ceiling and parses; truncation
        // is a BOOLEAN, never a coercible flag
        val sixteen = org.json.JSONArray()
        for (index in 0 until 16) sixteen.put("%032x".format(index))
        val parsed = RuntimeCleanupScope.parse(validControl()
            .put("evidenceSessionKeys", sixteen).put("provenTotal", 40).put("evidenceTruncated", true))
        assertNotNull(parsed)
        assertEquals(16, parsed!!.evidenceSessionKeys.size)
        assertTrue(parsed.evidenceTruncated)
        // non-hex / mixed-case keys are refused (frozen 32-lowerhex grammar)
        val bad = org.json.JSONArray().put("0123456789ABCDEF0123456789abcdef")
        assertNull(RuntimeCleanupScope.parse(validControl().put("evidenceSessionKeys", bad)))
        assertNull(RuntimeCleanupScope.parse(validControl().put("evidenceTruncated", "false")))
    }

    @Test fun resultsEchoScopeAndBoundReason() {
        val scope = RuntimeCleanupScope.parse(validControl())!!
        val cleared = RuntimeCleanupResults.cleared(scope, 10123, 41, 4096, "b".repeat(64))
        assertTrue(RuntimeCleanupResults.matchesScope(cleared, scope))
        assertEquals("cleared", cleared.getString("outcome"))
        assertEquals(10123, cleared.getInt("executorUid"))
        assertEquals(41L, cleared.getLong("pathsRemoved"))
        val refusal = RuntimeCleanupResults.refused(scope, "x".repeat(200))
        assertTrue(RuntimeCleanupResults.matchesScope(refusal, scope))
        assertEquals("refused", refusal.getString("outcome"))
        assertTrue(refusal.getString("reason").length <= 64)
        // scope-less refusal carries empty echo fields; the host scope
        // validation rejects it, so a mismatched receipt can never settle.
        val echoless = RuntimeCleanupResults.refused(null, "peerChanged")
        assertFalse(RuntimeCleanupResults.matchesScope(echoless, scope))
    }
}
