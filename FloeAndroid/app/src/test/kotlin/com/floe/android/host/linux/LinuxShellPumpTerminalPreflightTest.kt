// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G05-R3 authored-not-run boundary tests for the RUN-LESS terminal first-use
 * lane of [LinuxShellPump] (job-e2e7d046b63744cc): the closed request grammar,
 * the per-lane identity echo and the wire-contract stability. Pure parts only,
 * per the repo convention of keeping plain JVM unit tests Android-framework-free
 * (the same convention as [LinuxWorkspacePreflightClaimTest]); the claim
 * handling, grant minting, ingest/activation and JNI behaviour belong to Main's
 * grouped compile + device acceptance.
 *
 * The invariant that matters most here: this lane exists because NO model run
 * happened, so its identity is a trusted UI operation lease plus a
 * native-issued UI interaction UUID, and its reply must NEVER carry a `runID`
 * key — a UI identity may not be able to look like a model run.
 */
class LinuxShellPumpTerminalPreflightTest {

    // MEANINGFUL fixtures: the Swift `UUID.uuidString` / CoreWorkspaceGrant
    // echo grammar is UPPER-CASE and actually CONTAINS A-F hex letters. A
    // digit-only fixture passes both Java grammars and therefore misses the
    // historical lowercase-only bug.
    private val operationID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private val uiRunID = "A1B2C3D4-5E6F-4A7B-8C9D-0E1F2A3B4C5D"
    private val conversationID = "0F8FAD5B-D9CB-469F-A165-70867728950E"

    private fun request(
        epoch: Long = 7L,
        operation: String = operationID,
        ui: String = uiRunID,
        conversation: String = conversationID,
        extra: Map<String, Any> = emptyMap(),
        drop: Set<String> = emptySet(),
    ): JSONObject {
        val json = JSONObject()
        json.put("rootEpoch", epoch)
        json.put("operationID", operation)
        json.put("uiRunID", ui)
        json.put("conversationID", conversation)
        extra.forEach { (key, value) -> json.put(key, value) }
        drop.forEach { json.remove(it) }
        return json
    }

    @Test fun acceptsExactlyTheClosedFourKeyRequest() {
        val parsed = LinuxShellPump.terminalPreflightRequest(request(), 7L)
        assertEquals(
            LinuxShellPump.TerminalPreflightRequest(operationID, uiRunID, conversationID),
            parsed,
        )
        // Identities ride the ORIGINAL bytes (no case transform, no re-format).
        assertEquals(operationID, parsed?.operationID)
        assertEquals(uiRunID, parsed?.uiRunID)
        assertEquals(conversationID, parsed?.conversationID)
    }

    @Test fun refusesAnyShapeDriftBeforeAnyHostWork() {
        // An extra key — including a plausible-looking `environmentID` or a
        // command — is refused: this lane never guesses an environment and
        // never carries anything executable.
        assertNull(LinuxShellPump.terminalPreflightRequest(
            request(extra = mapOf("environmentID" to "env-1")), 7L))
        assertNull(LinuxShellPump.terminalPreflightRequest(
            request(extra = mapOf("command" to "pwd")), 7L))
        assertNull(LinuxShellPump.terminalPreflightRequest(
            request(extra = mapOf("runID" to uiRunID)), 7L))
        // A missing key is refused too (the closed set is exact).
        for (key in LinuxShellPump.TERMINAL_PREFLIGHT_KEYS) {
            assertNull("dropping $key must refuse",
                LinuxShellPump.terminalPreflightRequest(request(drop = setOf(key)), 7L))
        }
        // Generation binding: only the pump's OWN accepted epoch, never 0.
        assertNull(LinuxShellPump.terminalPreflightRequest(request(epoch = 8L), 7L))
        assertNull(LinuxShellPump.terminalPreflightRequest(request(epoch = 0L), 0L))
        assertNull(LinuxShellPump.terminalPreflightRequest(request(), 0L))
        // Identity grammar: lowercase, short, empty and free text all refuse.
        assertNull(LinuxShellPump.terminalPreflightRequest(request(operation = operationID.lowercase()), 7L))
        assertNull(LinuxShellPump.terminalPreflightRequest(request(ui = "3F2504E0-4F89-11d3-9A0C-0305E82C3301"), 7L))
        assertNull(LinuxShellPump.terminalPreflightRequest(request(conversation = "run-42"), 7L))
        assertNull(LinuxShellPump.terminalPreflightRequest(request(conversation = ""), 7L))
        assertNull(LinuxShellPump.terminalPreflightRequest(
            request(operation = "3F2504E0-4F89-11D3-9A0C-0305E82C330"), 7L))
    }

    @Test fun closedKeySetIsExactlyTheRunLessGrammar() {
        assertEquals(setOf("operationID", "uiRunID", "conversationID", "rootEpoch"),
            LinuxShellPump.TERMINAL_PREFLIGHT_KEYS)
        assertFalse(LinuxShellPump.TERMINAL_PREFLIGHT_KEYS.contains("environmentID"))
        assertFalse(LinuxShellPump.TERMINAL_PREFLIGHT_KEYS.contains("runID"))
        assertFalse(LinuxShellPump.TERMINAL_PREFLIGHT_KEYS.contains("command"))
    }

    @Test fun operationNameIsADistinctStablePrivateHostLane() {
        // Both sides of the ORIGINAL mailbox share this exact string; it is a
        // private host lane, not a model route and not the run lane.
        assertEquals("host.terminalWorkspacePreflight", LinuxShellPump.TERMINAL_PREFLIGHT_OPERATION)
        assertNotEquals("host.workspacePreflight", LinuxShellPump.TERMINAL_PREFLIGHT_OPERATION)
    }

    @Test fun terminalIdentityEchoNeverCarriesARunId() {
        val terminal = LinuxShellPump.PreflightIdentity.TerminalOperation(
            operationID, uiRunID, conversationID)
        val echoed = terminal.echo(JSONObject().put("status", "ready").put("rootEpoch", 7L))
        assertEquals(operationID, echoed.getString("operationID"))
        assertEquals(uiRunID, echoed.getString("uiRunID"))
        assertEquals(conversationID, echoed.getString("conversationID"))
        assertEquals(7L, echoed.getLong("rootEpoch"))
        // The invariant: a UI identity can never be mistaken for a model run.
        assertFalse(echoed.has("runID"))
        assertEquals(uiRunID, terminal.dispatchRunID)
    }

    @Test fun ownershipReadIsValidatedButNotBoundToTheLiveEpoch() {
        // The read asks about the ENTRY's epoch, which may be an older, fenced
        // generation: that is exactly what makes a retained claim observable
        // until its real IO ends. Shape/grammar drift still refuses.
        val parsed = LinuxShellPump.preflightOwnershipRequest(request(epoch = 3L))
        assertEquals(
            LinuxShellPump.PreflightOwnershipQuery(operationID, uiRunID, conversationID, 3L),
            parsed,
        )
        assertEquals(3L, parsed?.queryEpoch)
        assertNull(LinuxShellPump.preflightOwnershipRequest(request(epoch = 0L)))
        assertNull(LinuxShellPump.preflightOwnershipRequest(request(epoch = -1L)))
        assertNull(LinuxShellPump.preflightOwnershipRequest(
            request(extra = mapOf("ownershipReleased" to true))))
        assertNull(LinuxShellPump.preflightOwnershipRequest(request(drop = setOf("operationID"))))
        assertNull(LinuxShellPump.preflightOwnershipRequest(request(ui = uiRunID.lowercase())))
        // A distinct, stable private read operation on the SAME mailbox.
        assertEquals("host.terminalPreflightOwnership", LinuxShellPump.PREFLIGHT_OWNERSHIP_OPERATION)
        assertNotEquals(LinuxShellPump.TERMINAL_PREFLIGHT_OPERATION,
            LinuxShellPump.PREFLIGHT_OWNERSHIP_OPERATION)
        assertNotEquals("host.workspacePreflight", LinuxShellPump.PREFLIGHT_OWNERSHIP_OPERATION)
    }

    @Test fun pureOwnershipObservationSurvivesExecutionAdmissionStopWithExactEcho() {
        val query = LinuxShellPump.PreflightOwnershipQuery(
            operationID, uiRunID, conversationID, 3L)
        // There is deliberately NO admissionClosed/shouldStop input: stop()
        // closes execution, not this pure proof channel its drain still needs.
        val owned = LinuxShellPump.preflightOwnershipReply(query, query, acceptedEpoch = 9L)
        assertEquals("owned", owned.getString("status"))
        assertEquals(3L, owned.getLong("queryEpoch"))
        assertEquals(operationID, owned.getString("operationID"))
        assertEquals(uiRunID, owned.getString("uiRunID"))
        assertEquals(conversationID, owned.getString("conversationID"))
        assertEquals(9L, owned.getLong("rootEpoch"))
        val released = LinuxShellPump.preflightOwnershipReply(query, null, acceptedEpoch = 9L)
        assertEquals("released", released.getString("status"))
        // Released is identity-correlated too; Core still requires sticky host
        // completion or this entry's prior owned observation before discharge.
        assertEquals(3L, released.getLong("queryEpoch"))
        assertEquals(operationID, released.getString("operationID"))
        assertEquals(uiRunID, released.getString("uiRunID"))
        assertEquals(conversationID, released.getString("conversationID"))
        assertFalse(released.has("runID"))
        assertFalse(released.has("command"))
    }

    @Test fun runIdentityEchoIsUnchangedForTheOriginalLane() {
        val run = LinuxShellPump.PreflightIdentity.Run(uiRunID, conversationID)
        val echoed = run.echo(JSONObject().put("status", "ready").put("rootEpoch", 7L))
        assertEquals(uiRunID, echoed.getString("runID"))
        assertEquals(conversationID, echoed.getString("conversationID"))
        assertEquals(7L, echoed.getLong("rootEpoch"))
        // The run lane keeps its historical key set exactly: no operation key
        // leaks into it, so its Core-side parser is untouched.
        assertFalse(echoed.has("operationID"))
        assertFalse(echoed.has("uiRunID"))
        assertEquals(uiRunID, run.dispatchRunID)
        assertEquals(conversationID, run.conversationID)
        assertTrue(run is LinuxShellPump.PreflightIdentity)
    }
}
