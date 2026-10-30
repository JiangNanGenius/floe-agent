// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G03-R3 authored-not-run regressions for the LIVE readiness decision core
 * (ReadinessSnapshot + controller pure helpers). Boundary fixtures call the
 * REAL production decision functions — no parallel duplicated algorithm and
 * no Android/JNI needed. Covers Main's required cases: first-real-run
 * prereq gate, fast-unavailable when the five facts are absent, lease +
 * mapping NOT being preconditions, stale epoch / lost anchor / suspension
 * invalidation shapes, and the never-auto-restore rule. Production JSON
 * parsing and device ingress behaviour belong to Main's grouped compile
 * plus the device gates.
 */
class LinuxRuntimeReadinessControllerTest {

    private fun snapshot(
        liveEpoch: Long = EPOCH,
        anchored: Boolean = true,
        suspended: Long = 0,
        fields: Set<String>,
        accepted: Map<String, Pair<Long, Boolean>> =
            fields.mapNotNull { ReadinessSnapshot.kindFor(it) }
                .associateWith { liveEpoch to true },
    ) = ReadinessSnapshot(
        liveEpoch = liveEpoch, peerAnchored = anchored, suspendedEpoch = suspended,
        fields = ReadinessSnapshot.ALL_SEVEN.associateWith { it in fields },
        accepted = accepted,
    )

    private val five = setOf(
        "runtimeUidBoundaryVerified", "engineConnected", "mailboxEpochBound",
        "rootfsQualified", "singleWorkloadContractAcknowledged",
    )
    private val seven = five + setOf("workspaceMappingSynced", "leaseAuthorityQualified")

    @Test fun firstOrdinaryRunGateNeedsOnlyTheFivePrerequisites() {
        // Mapping + lease are NOT preconditions (that would reintroduce the
        // circular boot loop); with the five live facts the preflight may
        // dispatch for the FIRST real ordinary run.
        assertTrue(ReadinessSnapshot.prerequisitesLiveAt(snapshot(fields = five), EPOCH))
    }

    @Test fun absentFiveFactsFastUnavailable() {
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(snapshot(fields = emptySet()), EPOCH))
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(snapshot(fields = five - "rootfsQualified"), EPOCH))
        // Extra non-live junk never passes.
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(
            snapshot(fields = five, accepted = emptyMap()), EPOCH))
    }

    @Test fun activationRequiresAllSevenThroughTheSamePredicate() {
        assertTrue(ReadinessSnapshot.allSevenLiveAt(snapshot(fields = seven), EPOCH))
        assertFalse(ReadinessSnapshot.allSevenLiveAt(snapshot(fields = five), EPOCH))
    }

    @Test fun staleEpochForeignAnchorAndSuspensionRefuse() {
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(snapshot(fields = five), EPOCH + 1))
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(snapshot(liveEpoch = 0, fields = five), EPOCH))
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(snapshot(anchored = false, fields = five), EPOCH))
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(snapshot(suspended = EPOCH, fields = five), EPOCH))
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(snapshot(fields = five), 0))
        assertFalse(ReadinessSnapshot.allSevenLiveAt(snapshot(suspended = EPOCH, fields = seven), EPOCH))
    }

    @Test fun acceptedRecordMustMatchTheRequestedEpochAndLiveness() {
        // A derived flag alone is never enough: every required field needs
        // its CURRENT-generation accepted proof record, live at THIS epoch.
        val staleEpoch = five.mapNotNull(ReadinessSnapshot::kindFor)
            .associateWith { (EPOCH - 1) to true }
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(
            snapshot(fields = five, accepted = staleEpoch), EPOCH))
        val notLive = five.mapNotNull(ReadinessSnapshot::kindFor)
            .associateWith { EPOCH to false }
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(
            snapshot(fields = five, accepted = notLive), EPOCH))
        // An accepted entry for a DIFFERENT kind (e.g. an old-generation
        // lease refusal residue) must not deadlock the five-fact gate.
        val staleWithForeign = staleEpoch + ("leaseAuthorityQualified" to (EPOCH - 9 to false))
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(
            snapshot(fields = five, accepted = staleWithForeign), EPOCH))
        val liveFive = five.mapNotNull(ReadinessSnapshot::kindFor)
            .associateWith { EPOCH to true }
        val foreign = liveFive + ("leaseAuthorityQualified" to (EPOCH - 9 to false))
        assertTrue(ReadinessSnapshot.prerequisitesLiveAt(
            snapshot(fields = five, accepted = foreign), EPOCH))
    }

    @Test fun factsNeverAutoRestoreAfterInvalidate() {
        // invalidate("*) drops every record; the resulting all-false shape
        // refuses BOTH gates. Qualification returns only via a fresh FULL
        // re-ingest (a later test of the ingest path needs the device).
        val cleared = snapshot(fields = emptySet(), accepted = emptyMap())
        assertFalse(ReadinessSnapshot.prerequisitesLiveAt(cleared, EPOCH))
        assertFalse(ReadinessSnapshot.allSevenLiveAt(cleared, EPOCH))
    }

    @Test fun fieldAndKindNamesMatchTheFrozenAbi() {
        assertEquals("runtimeUidBoundary", ReadinessSnapshot.kindFor("runtimeUidBoundaryVerified"))
        assertEquals("mailboxEpoch", ReadinessSnapshot.kindFor("mailboxEpochBound"))
        assertEquals("rootfsInstalled", ReadinessSnapshot.kindFor("rootfsQualified"))
        assertEquals("singleWorkloadAcknowledged",
            ReadinessSnapshot.kindFor("singleWorkloadContractAcknowledged"))
        assertEquals("workspaceMappingSynced", ReadinessSnapshot.kindFor("workspaceMappingSynced"))
        assertEquals("leaseAuthorityQualified", ReadinessSnapshot.kindFor("leaseAuthorityQualified"))
        assertEquals(5, ReadinessSnapshot.PREREQUISITES.size)
        assertEquals(7, ReadinessSnapshot.ALL_SEVEN.size)
    }

    @Test fun workloadContractStringMatchesTheKernelAttestation() {
        assertEquals("floe-single-workload-v1", LinuxRuntimeReadinessController.WORKLOAD_CONTRACT)
    }

    @Test fun staleComponentBuildIsRefusedBeforeAnyPeerAnchor() {
        // G03-R3 App-upgrade gate (actual Samsung 19->component21 incident):
        // a fresh App build with the PREVIOUS embedded component still
        // installed must NOT be anchored as the fresh root's peer. The
        // decision is the SAME trusted PackageManager exact-version check the
        // setup surface uses; here the pure mapping is pinned across all
        // closed states. No model/peer payload or label can change it.
        // The actual installed-build comparison: App 22 + still-installed
        // child 21 is stale; child 22 is the only matching state.
        assertEquals(RuntimeComponentMatch.State.VERSION_STALE,
            RuntimeComponentMatch.versionState(ownVersionCode = 22, peerVersionCode = 21))
        assertEquals(RuntimeComponentMatch.State.MATCHING,
            RuntimeComponentMatch.versionState(ownVersionCode = 22, peerVersionCode = 22))
        assertEquals("componentVersionStale",
            RuntimeComponentMatch.refusalFor(RuntimeComponentMatch.versionState(22, 21)))
        assertNull(RuntimeComponentMatch.refusalFor(RuntimeComponentMatch.versionState(22, 22)))
        assertEquals("componentVersionStale",
            RuntimeComponentMatch.refusalFor(RuntimeComponentMatch.State.VERSION_STALE))
        assertEquals("componentUnavailable",
            RuntimeComponentMatch.refusalFor(RuntimeComponentMatch.State.MISSING))
        assertEquals("componentIdentityMismatch",
            RuntimeComponentMatch.refusalFor(RuntimeComponentMatch.State.IDENTITY_MISMATCH))
        // Only the EXACT expected build may proceed to anchor/qualify.
        assertNull(RuntimeComponentMatch.refusalFor(RuntimeComponentMatch.State.MATCHING))
        // The refusal tokens stay visible in the bounded diagnostics instead
        // of collapsing to `redacted`.
        assertEquals("componentVersionStale",
            LinuxRuntimeReadinessController.closedStageToken("componentVersionStale"))
        assertEquals("componentIdentityMismatch",
            LinuxRuntimeReadinessController.closedStageToken("componentIdentityMismatch"))
    }

    @Test fun verifiedInstallLifecycleTransitionsDriveFreshIngressOnly() {
        // Real transitions from the EXISTING setup authority drive the
        // lifecycle; the FIRST observation and unchanged phases never act
        // (no silent re-anchor, no idle re-ingress). Leaving installed means
        // the rootfs/component actually changed: ALL facts must fall NOW.
        assertEquals(LinuxRuntimeReadinessController.LifecycleChange.NONE,
            LinuxRuntimeReadinessController.lifecycleChange(null, "installed"))
        assertEquals(LinuxRuntimeReadinessController.LifecycleChange.REINGRESS,
            LinuxRuntimeReadinessController.lifecycleChange("installing", "installed"))
        assertEquals(LinuxRuntimeReadinessController.LifecycleChange.REINGRESS,
            LinuxRuntimeReadinessController.lifecycleChange("unknown", "installed"))
        assertEquals(LinuxRuntimeReadinessController.LifecycleChange.INVALIDATE,
            LinuxRuntimeReadinessController.lifecycleChange("installed", "installing"))
        assertEquals(LinuxRuntimeReadinessController.LifecycleChange.INVALIDATE,
            LinuxRuntimeReadinessController.lifecycleChange("installed", "component_required"))
        assertEquals(LinuxRuntimeReadinessController.LifecycleChange.NONE,
            LinuxRuntimeReadinessController.lifecycleChange("installed", "installed"))
        assertEquals(LinuxRuntimeReadinessController.LifecycleChange.NONE,
            LinuxRuntimeReadinessController.lifecycleChange("failed", "install_required"))
        // Re-ingress is BOUNDED and owned (no unbounded background poller).
        assertTrue(LinuxRuntimeReadinessController.REINGRESS_ATTEMPTS in 1..48)
        assertTrue(LinuxRuntimeReadinessController.REINGRESS_BACKOFF_MILLIS >= 1_000L)
    }

    @Test fun preflightTokenAndGrammarBoundariesArePureAndBounded() {
        // Core identity grammar is the Swift uuidString UPPER-CASE form
        // (digit-only fixtures miss the v1 lowercase-only bug).
        val run = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        assertTrue(LinuxShellPump.isCanonicalUUID(run))
        assertFalse(LinuxShellPump.isCanonicalUUID(run.lowercase()))
        assertFalse(LinuxShellPump.isCanonicalUUID("nope"))
        assertEquals("busy", LinuxShellPump.boundedToken("busy"))
        // Free text (spaces) never survives as a reply reason.
        assertEquals("preflight_failed", LinuxShellPump.boundedToken("no such process"))
        assertTrue(LinuxShellPump.boundedToken("x".repeat(32)).length == 32)
        assertEquals("preflight_failed", LinuxShellPump.boundedToken("x".repeat(33)))
    }

    private companion object {
        const val EPOCH = 77L
    }
}
