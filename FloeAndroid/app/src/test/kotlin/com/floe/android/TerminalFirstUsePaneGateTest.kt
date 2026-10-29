// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.host.TerminalHostAvailability
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * G05-R3 authored-not-run tests for the terminal pane's control-enablement
 * seam (job-e2e7d046b63744cc). The pane's decision is a pure function of four
 * real reads, so the regression pins the ACTUAL production gate instead of a
 * Compose tree:
 *  * a live session is only ever ATTACHED (never restarted by a re-shown pane);
 *  * a qualified lane STARTS exactly as before;
 *  * the run-less first entry is offered ONLY on the exact mapping-pending
 *    stage shape — every prerequisite live, only this task's own receipt-backed
 *    workspace facts missing, no failed attempt this generation;
 *  * an unqualified engine, an unbound lane or a failed attempt keeps the
 *    honest setup guidance and dispatches nothing (no fake pane, no hidden
 *    retry loop, and no requirement that the user send a message or configure
 *    a provider first).
 */
class TerminalFirstUsePaneGateTest {

    private fun gate(
        ready: Boolean,
        needsStart: Boolean,
        liveSession: Boolean,
        mappingPending: Boolean,
    ) = terminalFirstUseGate(ready, needsStart, liveSession, mappingPending)

    @Test fun liveSessionIsAttachedNeverRestarted() {
        assertEquals(TerminalFirstUseGate.ATTACH_LIVE,
            gate(ready = true, needsStart = false, liveSession = true, mappingPending = false))
        // Even an unqualified cached gate cannot restart or re-prepare over a
        // session that is actually live.
        assertEquals(TerminalFirstUseGate.ATTACH_LIVE,
            gate(ready = false, needsStart = false, liveSession = true, mappingPending = true))
    }

    @Test fun qualifiedLaneStartsExactlyAsBefore() {
        assertEquals(TerminalFirstUseGate.START,
            gate(ready = true, needsStart = true, liveSession = false, mappingPending = false))
        // A ready lane never takes the run-less preparation branch, so no
        // redundant import is dispatched for a warm task.
        assertEquals(TerminalFirstUseGate.START,
            gate(ready = true, needsStart = true, liveSession = false, mappingPending = true))
    }

    @Test fun runLessFirstEntryIsOfferedOnlyOnTheExactMappingPendingShape() {
        assertEquals(TerminalFirstUseGate.PREPARE_FIRST_USE,
            gate(ready = false, needsStart = true, liveSession = false, mappingPending = true))
    }

    @Test fun everyOtherUnqualifiedShapeKeepsHonestGuidance() {
        // Not qualified and not the mapping-pending shape: the runtime setup
        // guidance stays, and nothing is dispatched.
        assertEquals(TerminalFirstUseGate.EXPLAIN,
            gate(ready = false, needsStart = true, liveSession = false, mappingPending = false))
        // A settled (exited/stopped/fault/closed-but-not-needing-start) pane
        // never auto-relaunches: the explicit Reset control owns that.
        assertEquals(TerminalFirstUseGate.EXPLAIN,
            gate(ready = false, needsStart = false, liveSession = false, mappingPending = true))
        assertEquals(TerminalFirstUseGate.EXPLAIN,
            gate(ready = true, needsStart = false, liveSession = false, mappingPending = false))
    }

    @Test fun onlyTheObservedStageShapeCountsAsMappingPending() {
        // The two honest shapes: one receipt-backed fact missing, no refusal
        // and no recorded attempt this generation.
        assertEquals(TerminalFirstUseGate.PREPARE_FIRST_USE, terminalFirstUseGate(
            ready = false, needsStart = true, liveSession = false,
            mappingPending = terminalWorkspaceMappingPending(
                "missing:workspaceMappingSynced|refusal:|stage:")))
        assertEquals(TerminalFirstUseGate.PREPARE_FIRST_USE, terminalFirstUseGate(
            ready = false, needsStart = true, liveSession = false,
            mappingPending = terminalWorkspaceMappingPending(
                "missing:leaseAuthorityQualified|refusal:|stage:")))
        // Anything else — ready, a real refusal, a recorded failed attempt, a
        // prerequisite shape, an unbound lane or unknown text — keeps EXPLAIN.
        for (diagnostic in listOf(
            "ready",
            "missing:workspaceMappingSynced|refusal:epochNotLive|stage:",
            "missing:workspaceMappingSynced|refusal:|stage:preflight_failed",
            "missing:rootfsQualified|refusal:|stage:",
            "lane:unbound",
            "status:unreadable",
            null,
        )) {
            assertEquals("diagnostic=$diagnostic must not offer the run-less entry",
                TerminalFirstUseGate.EXPLAIN, terminalFirstUseGate(
                    ready = false, needsStart = true, liveSession = false,
                    mappingPending = terminalWorkspaceMappingPending(diagnostic)))
        }
    }

    @Test fun availabilitySnapshotNeverEnablesTheRunLessEntryByItself() {
        // A bound-but-unqualified cached snapshot is the shape that used to pin
        // the pane forever; the gate still refuses to dispatch on it, because
        // the stage authority (not the snapshot) decides the run-less entry.
        val boundUnqualified = TerminalHostAvailability(
            bound = true, qualified = false, workspaceAttached = false, capabilitiesKnown = true)
        assertEquals(TerminalFirstUseGate.EXPLAIN, terminalFirstUseGate(
            ready = boundUnqualified.qualified && boundUnqualified.workspaceAttached,
            needsStart = true, liveSession = false, mappingPending = false))
        val cold = TerminalHostAvailability(false, false, false, false)
        assertEquals(TerminalFirstUseGate.EXPLAIN, terminalFirstUseGate(
            ready = cold.qualified && cold.workspaceAttached,
            needsStart = true, liveSession = false, mappingPending = false))
    }
}
