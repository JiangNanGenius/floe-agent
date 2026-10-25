// SPDX-License-Identifier: MPL-2.0
// Proposed JVM regression source — integrate into
// app/src/test/kotlin/com/floe/android/ and run in Main's batched JVM set.
// NOT executed in this private lane.
package com.floe.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the guidance classifier of the terminal pane's honest-unavailability
 * surface. The classifier only SELECTS copy: it qualifies nothing, gates
 * nothing and reads nothing itself. The tokens below are the EXACT closed
 * diagnostic shapes (device-observed and grammar-fixed by the readiness
 * controller's diagnostic composition):
 *  - ready
 *  - lane:unbound / status:unreadable
 *  - <cause>|refusal:<closed>|stage:<closed>
 */
class TerminalWorkspaceMappingPendingTest {

    @Test
    fun exactObservedMappingPendingShapesArePending() {
        // The single-device observed token (workspace fact named first):
        assertTrue(terminalWorkspaceMappingPending(
            "missing:workspaceMappingSynced|refusal:|stage:"))
        // The same pending shape when the lease fact is named first:
        assertTrue(terminalWorkspaceMappingPending(
            "missing:leaseAuthorityQualified|refusal:|stage:"))
    }

    @Test
    fun readyIsNotPending() {
        // With the lane ready the pane must not tell the user to send a
        // message: any residual refusal then belongs to the setup guidance.
        assertFalse(terminalWorkspaceMappingPending("ready"))
    }

    @Test
    fun attemptedFailuresAreNeverPending() {
        // A non-empty refusal or stage token proves an ingest/preflight
        // attempt happened and failed this generation: sending a message is
        // NOT the named recovery for a failed attempt.
        assertFalse(terminalWorkspaceMappingPending(
            "missing:workspaceMappingSynced|refusal:redacted|stage:"))
        assertFalse(terminalWorkspaceMappingPending(
            "missing:workspaceMappingSynced|refusal:|stage:redacted"))
        assertFalse(terminalWorkspaceMappingPending(
            "missing:leaseAuthorityQualified|refusal:redacted|stage:redacted"))
    }

    @Test
    fun setupAndLaneShapesAreNotPending() {
        // Prerequisite-absent and lane-unbound shapes keep pointing at the
        // runtime setup surface, not at a chat message.
        assertFalse(terminalWorkspaceMappingPending("lane:unbound"))
        assertFalse(terminalWorkspaceMappingPending("status:unreadable"))
        assertFalse(terminalWorkspaceMappingPending(
            "missing:engineConnected|refusal:|stage:"))
        assertFalse(terminalWorkspaceMappingPending(
            "missing:rootfsQualified|refusal:|stage:"))
        assertFalse(terminalWorkspaceMappingPending(
            "epochMismatch|refusal:|stage:"))
        assertFalse(terminalWorkspaceMappingPending(
            "peerUnanchored|refusal:|stage:"))
        assertFalse(terminalWorkspaceMappingPending(
            "suspended|refusal:|stage:"))
        assertFalse(terminalWorkspaceMappingPending(
            "unaccepted:workspaceMappingSynced|refusal:|stage:"))
        assertFalse(terminalWorkspaceMappingPending(
            "factsNotAllLive|refusal:|stage:"))
    }

    @Test
    fun nullEmptyAndUnknownTextAreNotPending() {
        // A failed or absent diagnostic read keeps the existing guidance —
        // never a new claim.
        assertFalse(terminalWorkspaceMappingPending(null))
        assertFalse(terminalWorkspaceMappingPending(""))
        assertFalse(terminalWorkspaceMappingPending("missing:workspaceMappingSynced"))
        assertFalse(terminalWorkspaceMappingPending(
            "missing:workspaceMappingSynced|refusal:|stage:|extra"))
        assertFalse(terminalWorkspaceMappingPending(
            "missing:workspaceMappingSynced|refusal:|stage "))
        assertFalse(terminalWorkspaceMappingPending(
            "missing:workspaceMappingSyncedX|refusal:|stage:"))
    }
}
