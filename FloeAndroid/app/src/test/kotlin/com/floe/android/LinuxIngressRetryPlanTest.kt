// SPDX-License-Identifier: MPL-2.0
// TARGET PATH: FloeAndroid/app/src/test/kotlin/com/floe/android/LinuxIngressRetryPlanTest.kt
// Authored NOTRUN in the private N05-sony-installed-next staging subtree
// (job-148e0d17acf14cd6). The pure decision is testable off-Android; the
// thin wiring in FloeApplication.retryLinuxTaskExecutionIngress reuses only
// the EXISTING lane primitives (startLinuxLanes / LinuxRuntimeReadiness-
// Controller.start / onInstallVerified) and stays instrumented-side /
// Main-reviewed, exactly like the bootstrap call sites it replays.
package com.floe.android

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * N05-sony-installed-next: the installed card's recheck copy promises a
 * fresh measure, but the pre-patch recheck was a PROVEN no-op exactly when
 * `linuxShell.boundNativeEpoch <= 0` while the bootstrap pump retry budget
 * (12x5s) was already spent (FloeApplication.kt:992-997 at main 32bb669d4)
 * — the mailbox-unbound / lane-unbound / generation-mismatch shapes.
 *
 * The plan must stay conservative:
 *  - steady bound generation => INGRESS_ONLY: the ORIGINAL call sequence,
 *    byte-for-byte (a recheck never re-binds what is already bound);
 *  - no live native root at all => INGRESS_ONLY: a stopped or never-started
 *    Root is NEVER revived by a UI tap (bootstrap doctrine preserved);
 *  - a live generation the lanes do not match => REPLAY_LANE_BIND: one
 *    bounded replay of the existing lane-bind primitive set.
 */
class LinuxIngressRetryPlanTest {

    @Test fun steadyGenerationIsTheOriginalIngressOnlySequence() {
        assertEquals(LinuxIngressRetryPlan.INGRESS_ONLY,
            linuxIngressRetryPlan(shellEpoch = 9L, readinessEpoch = 9L, nativeEpoch = 9L))
    }

    @Test fun mailboxUnboundLiveRootIsTheProvenNoOpShapeRepaired() {
        // Shell never bound; readiness lane never (or no longer) bound.
        // Pre-patch: `if (epoch <= 0) false` — false WITHOUT any measurement
        // while the card said the recheck re-measures.
        assertEquals(LinuxIngressRetryPlan.REPLAY_LANE_BIND,
            linuxIngressRetryPlan(shellEpoch = 0L, readinessEpoch = 0L, nativeEpoch = 9L))
        // Shell bound but only the readiness lane missing for the SAME live
        // generation: pre-patch onInstallVerified found no target and the
        // bootstrap early-return kept it dead.
        assertEquals(LinuxIngressRetryPlan.REPLAY_LANE_BIND,
            linuxIngressRetryPlan(shellEpoch = 9L, readinessEpoch = 0L, nativeEpoch = 9L))
    }

    @Test fun generationMismatchIsBoundedRebindNotRequalification() {
        // A newer accepted root generation the lanes do not hold yet.
        assertEquals(LinuxIngressRetryPlan.REPLAY_LANE_BIND,
            linuxIngressRetryPlan(shellEpoch = 9L, readinessEpoch = 9L, nativeEpoch = 11L))
        assertEquals(LinuxIngressRetryPlan.REPLAY_LANE_BIND,
            linuxIngressRetryPlan(shellEpoch = 11L, readinessEpoch = 9L, nativeEpoch = 11L))
    }

    @Test fun withoutLiveNativeRootTheOriginalFalseShortcutStaysUntouched() {
        // No accepted native generation: the recheck must bind nothing and
        // re-ingress nothing, exactly like the pre-patch form. A stopped
        // Root is never revived by a UI tap.
        assertEquals(LinuxIngressRetryPlan.INGRESS_ONLY,
            linuxIngressRetryPlan(shellEpoch = 0L, readinessEpoch = 0L, nativeEpoch = 0L))
        assertEquals(LinuxIngressRetryPlan.INGRESS_ONLY,
            linuxIngressRetryPlan(shellEpoch = 9L, readinessEpoch = 9L, nativeEpoch = 0L))
        assertEquals(LinuxIngressRetryPlan.INGRESS_ONLY,
            linuxIngressRetryPlan(shellEpoch = 0L, readinessEpoch = 9L, nativeEpoch = -1L))
    }

    @Test fun planIsTotalOverBoundedEpochs() {
        for (shell in longArrayOf(-1L, 0L, 1L, 9L, Long.MAX_VALUE)) {
            for (readiness in longArrayOf(-1L, 0L, 9L)) {
                for (native in longArrayOf(-1L, 0L, 9L, 11L)) {
                    val plan = linuxIngressRetryPlan(shell, readiness, native)
                    assertEquals(true, plan == LinuxIngressRetryPlan.INGRESS_ONLY ||
                        plan == LinuxIngressRetryPlan.REPLAY_LANE_BIND)
                }
            }
        }
        assertEquals(2, LinuxIngressRetryPlan.values().size)
    }
}
