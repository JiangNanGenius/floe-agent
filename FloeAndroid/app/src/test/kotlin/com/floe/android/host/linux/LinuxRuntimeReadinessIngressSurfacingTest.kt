// SPDX-License-Identifier: MPL-2.0
// TARGET PATH: FloeAndroid/app/src/test/kotlin/com/floe/android/host/linux/LinuxRuntimeReadinessIngressSurfacingTest.kt
// Authored NOTRUN in the private N05-sony-installed-next staging subtree
// (job-148e0d17acf14cd6). Main compiles/runs the focused JVM filter after
// applying CHANGES.patch; nothing here was executed by this lane.
package com.floe.android.host.linux

import com.floe.android.terminalWorkspaceMappingPending
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * N05-sony-installed-next regressions: the typed ingress refusal surfacing
 * through Core's deliberate `invalidated:<kind|all>` reason DISCARD.
 *
 * Proven production shape (main 32bb669d4): every controller-side ingress
 * refusal (component gate `componentVersionStale`, peer handshake,
 * `rootfsUnverified`, `transport_lost`, …) is passed to
 * LinuxRuntimeReadinessNative.invalidate(field = NULL, reason), and Core's
 * invalidate overwrites the stored reason with "invalidated:all". The
 * installed card therefore could never name the startup cause, the shipped
 * COMPONENT copy was unreachable through `refusal:`, and the generic
 * ATTEMPT_FAILED guidance pointed at a recheck that (pre-patch) measured
 * nothing for unbound lanes.
 *
 * These fixtures use ONLY the real closed grammar from
 * LinuxRuntimeReadinessController.diagnosticStage; no parallel vocabulary.
 */
class LinuxRuntimeReadinessIngressSurfacingTest {

    private val epoch = 7L
    private val five = listOf(
        "runtimeUidBoundaryVerified", "engineConnected", "mailboxEpochBound",
        "rootfsQualified", "singleWorkloadContractAcknowledged",
    )

    private fun snapshot(fields: List<String>, liveEpoch: Long = epoch, anchored: Boolean = true) =
        ReadinessSnapshot(
            liveEpoch = liveEpoch, peerAnchored = anchored, suspendedEpoch = 0,
            fields = ReadinessSnapshot.ALL_SEVEN.associateWith { it in fields },
            accepted = ReadinessSnapshot.ALL_SEVEN
                .mapNotNull { ReadinessSnapshot.kindFor(it) }
                .associateWith { liveEpoch to true },
        )

    private fun stage(snap: ReadinessSnapshot, lastRefusal: String?, lastStage: String? = null,
                      typed: String? = null) =
        LinuxRuntimeReadinessController.diagnosticStage(snap, lastRefusal, epoch, lastStage, typed)

    // MARK: - masked invalidation + a recorded typed refusal

    @Test fun maskedInvalidationSurfacesTheTypedComponentGateRefusal() {
        val token = stage(snapshot(five), lastRefusal = "invalidated:all",
            typed = "componentVersionStale")
        assertEquals("missing:workspaceMappingSynced|refusal:componentVersionStale|stage:", token)
        // The shipped COMPONENT copy finally becomes reachable from the REAL
        // producer path, not only from synthetic fixtures.
        assertEquals(LocalRuntimeRecovery.COMPONENT, localRuntimeRecovery(token))
    }

    @Test fun maskedInvalidationSurfacesNewPeerHandshakeAndLossTokens() {
        for (typed in listOf("connectTimeout", "connectRefused", "engine_binder_lost",
                "root_stopped", "install_changed", "epoch_replace", "ingress_failed",
                "peerUnmeasurable", "rootfsUnverified")) {
            val token = stage(snapshot(five), lastRefusal = "invalidated:all", typed = typed)
            assertEquals("typed=$typed", "missing:workspaceMappingSynced|refusal:$typed|stage:", token)
            assertEquals("typed must pass the closed membership unchanged", typed,
                LinuxRuntimeReadinessController.closedStageToken(typed))
        }
    }

    // MARK: - precedence and membership fences

    @Test fun directCoreRefusalKeepsPrecedenceOverTheControllerRecord() {
        // mailboxClosed/admissionSuspended are named BY Core at ingest; the
        // controller record must never overwrite a direct refusal.
        assertEquals("missing:workspaceMappingSynced|refusal:mailboxClosed|stage:",
            stage(snapshot(five), lastRefusal = "mailboxClosed", typed = "componentVersionStale"))
        assertEquals("missing:workspaceMappingSynced|refusal:admissionSuspended|stage:",
            stage(snapshot(five), lastRefusal = "admissionSuspended", typed = "ingress_failed"))
    }

    @Test fun foreignTypedValueCanNeverPass() {
        val token = stage(snapshot(five), lastRefusal = "invalidated:all",
            typed = "invalidated:/data/user/0/com.floe.agent")
        assertEquals("missing:workspaceMappingSynced|refusal:invalidated:all|stage:", token)
    }

    @Test fun unrecordedAndEmptyShapesStayByteIdentical() {
        // No typed record: exactly the pre-patch outputs.
        assertEquals("missing:workspaceMappingSynced|refusal:invalidated:all|stage:",
            stage(snapshot(five), lastRefusal = "invalidated:all"))
        assertEquals("missing:workspaceMappingSynced|refusal:|stage:",
            stage(snapshot(five), lastRefusal = null))
        assertEquals("missing:workspaceMappingSynced|refusal:|stage:",
            stage(snapshot(five), lastRefusal = "", typed = null))
        // The pinned run-less mapping-pending shapes never gain a refusal.
        assertEquals(true, terminalWorkspaceMappingPending(stage(snapshot(five), lastRefusal = null)))
    }

    @Test fun kindMaskedInvalidationIsAlsoSubstituted() {
        // invalidate(<kind>) records `invalidated:<kind>` — still a discard
        // of the typed cause, so the controller record surfaces there too.
        val token = stage(snapshot(five), lastRefusal = "invalidated:rootfsInstalled",
            typed = "rootfs_drift")
        assertEquals("missing:workspaceMappingSynced|refusal:rootfs_drift|stage:", token)
    }

    // MARK: - card projection (copy-only) for the stage segment

    @Test fun componentCodeRecordedInStageIsComponentClass() {
        for (token in listOf("componentUnavailable", "componentVersionStale",
                "componentIdentityMismatch")) {
            assertEquals("stage=$token", LocalRuntimeRecovery.COMPONENT,
                localRuntimeRecovery("missing:runtimeUidBoundaryVerified|refusal:invalidated:all|stage:$token"))
        }
    }

    @Test fun nonComponentStageRecordKeepsAttemptFailedClass() {
        assertEquals(LocalRuntimeRecovery.ATTEMPT_FAILED, localRuntimeRecovery(
            "missing:runtimeUidBoundaryVerified|refusal:invalidated:all|stage:prerequisites_unverified"))
        // Existing pinned shapes keep their classes exactly.
        assertEquals(LocalRuntimeRecovery.ATTEMPT_FAILED, localRuntimeRecovery(
            "missing:workspaceMappingSynced|refusal:invalidated:all|stage:mapping_unsynced"))
    }

    @Test fun surfacedComponentTokenNeverReadsAsTaskStatePreparingOrReady() {
        val token = stage(snapshot(five), lastRefusal = "invalidated:all",
            typed = "componentVersionStale")
        assertEquals(LocalRuntimeTaskState.UNVERIFIED, localRuntimeTaskState(false, token))
        assertEquals(false, terminalWorkspaceMappingPending(token))
    }

    @Test fun runtimeOwnTimerAndFutureTimeoutBothRemainTimeouts() {
        for (cause in listOf(IllegalStateException("Runtime connection timed out"),
                java.util.concurrent.TimeoutException())) {
            assertEquals("connectTimeout", LinuxRuntimeReadinessController.connectionFailureStage(
                java.util.concurrent.ExecutionException(cause)))
        }
        for (cause in listOf(IllegalStateException("Runtime component unavailable"),
                SecurityException("Peer verification refused"))) {
            assertEquals("connectRefused", LinuxRuntimeReadinessController.connectionFailureStage(
                java.util.concurrent.ExecutionException(cause)))
        }
    }

    @Test fun wrappedCancellationKeepsTheOriginalCancellation() {
        val cancelled = kotlinx.coroutines.CancellationException("cancelled")
        try {
            LinuxRuntimeReadinessController.connectionFailureStage(
                java.util.concurrent.ExecutionException(cancelled))
            org.junit.Assert.fail("Cancellation must propagate")
        } catch (actual: kotlinx.coroutines.CancellationException) {
            org.junit.Assert.assertSame(cancelled, actual)
        }
    }
}
