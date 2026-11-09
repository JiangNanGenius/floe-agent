// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * N07 installed-not-ready recovery projection regressions (2026-11-10,
 * job-80939eb53b804edf). Authored NOTRUN — source-authored only; no
 * compile/run claim here. Main runs the focused JVM filter after compile.
 *
 * The customer stage (photo, Sony-class device): setup phase INSTALLED with
 * the generic "terminal tasks temporarily unavailable" line and no action.
 * The repair surfaces the real closed stage and an authorized recheck; this
 * packet pins the COPY-ONLY projection [localRuntimeRecovery] so every
 * distinguishable not-ready class stays honest:
 *
 *  1. `ready` and the two exact run-less first-use shapes carry NONE (the
 *     existing state copy already names the real next step — never double
 *     guidance, never a recovery promise for a state that has one).
 *  2. A generic capability-probe failure (`lane:unbound`,
 *     `status:unreadable`, null/unknown) is its own class, distinct from a
 *     missing workspace fact, a component mismatch and an actual failed
 *     readiness attempt.
 *  3. Component-mismatch refusal tokens win over any recorded stage, so a
 *     stale/mismatched component is never misreported as a transient probe
 *     failure.
 *  4. The projection is TOTAL: malformed/foreign tokens never throw and
 *     never invent a cause.
 *  5. Cross-function consistency with [localRuntimeTaskState]: whenever the
 *     card state is UNVERIFIED the recovery class is never NONE, and the
 *     PREPARING_WORKSPACE shapes never carry recovery guidance.
 *
 * Fixtures use the REAL closed token grammar produced by
 * [LinuxRuntimeReadinessController.diagnosticStage]; no parallel vocabulary.
 */
class LocalRuntimeRecoveryTest {

    // MARK: - NONE (ready / run-less first-use shapes)

    @Test fun readyAndMappingPendingShapesCarryNoRecoveryClass() {
        assertEquals(LocalRuntimeRecovery.NONE, localRuntimeRecovery("ready"))
        assertEquals(LocalRuntimeRecovery.NONE,
            localRuntimeRecovery("missing:workspaceMappingSynced|refusal:|stage:"))
        assertEquals(LocalRuntimeRecovery.NONE,
            localRuntimeRecovery("missing:leaseAuthorityQualified|refusal:|stage:"))
    }

    // MARK: - PROBE (generic capability-probe failure)

    @Test fun probeUnreadableIsItsOwnClass() {
        assertEquals(LocalRuntimeRecovery.PROBE, localRuntimeRecovery(null))
        assertEquals(LocalRuntimeRecovery.PROBE, localRuntimeRecovery(""))
        assertEquals(LocalRuntimeRecovery.PROBE, localRuntimeRecovery("lane:unbound"))
        assertEquals(LocalRuntimeRecovery.PROBE, localRuntimeRecovery("status:unreadable"))
    }

    // MARK: - LINK (prerequisite link missing, no recorded attempt)

    @Test fun missingPrerequisiteCausesLink() {
        val causes = listOf(
            "missing:runtimeUidBoundaryVerified|refusal:|stage:",
            "missing:engineConnected|refusal:|stage:",
            "missing:mailboxEpochBound|refusal:|stage:",
            "missing:rootfsQualified|refusal:|stage:",
            "missing:singleWorkloadContractAcknowledged|refusal:|stage:",
            "peerUnanchored|refusal:|stage:",
            "epochMismatch|refusal:|stage:",
            "suspended|refusal:|stage:",
            "factsNotAllLive|refusal:|stage:",
            "unaccepted:workspaceMappingSynced|refusal:|stage:",
        )
        for (token in causes) {
            assertEquals("token=$token", LocalRuntimeRecovery.LINK, localRuntimeRecovery(token))
        }
    }

    // MARK: - COMPONENT (component mismatch beats any recorded stage)

    @Test fun componentRefusalTokensAreComponentClass() {
        for (refusal in listOf("componentUnavailable", "componentVersionStale",
                "componentIdentityMismatch")) {
            assertEquals("refusal=$refusal", LocalRuntimeRecovery.COMPONENT,
                localRuntimeRecovery("missing:runtimeUidBoundaryVerified|refusal:$refusal|stage:"))
            // A recorded stage never downgrades a component mismatch.
            assertEquals("refusal=$refusal", LocalRuntimeRecovery.COMPONENT,
                localRuntimeRecovery("missing:runtimeUidBoundaryVerified|refusal:$refusal|stage:epochNotBound"))
        }
    }

    // MARK: - ATTEMPT_FAILED (a real readiness attempt recorded something)

    @Test fun recordedAttemptFailureIsAttemptFailedClass() {
        val tokens = listOf(
            "missing:workspaceMappingSynced|refusal:ingress_failed|stage:",
            "missing:workspaceMappingSynced|refusal:invalidated:all|stage:mapping_unsynced",
            "missing:leaseAuthorityQualified|refusal:|stage:preflight_evidence",
            "epochMismatch|refusal:peer_generation_drift|stage:",
            "missing:engineConnected|refusal:engine_identity_lost|stage:transport_lost",
        )
        for (token in tokens) {
            assertEquals("token=$token", LocalRuntimeRecovery.ATTEMPT_FAILED,
                localRuntimeRecovery(token))
        }
    }

    // MARK: - total behaviour (never throws, never invents)

    @Test fun malformedTokensAreTotalAndClassifiedByCause() {
        // Unknown cause, empty grammar segments: classified by cause alone.
        assertEquals(LocalRuntimeRecovery.LINK, localRuntimeRecovery("something_new|refusal:|stage:"))
        // No grammar at all: the whole string is the cause.
        assertEquals(LocalRuntimeRecovery.LINK, localRuntimeRecovery("garbage"))
        // Precedence: a probe-shaped cause wins over a recorded refusal (the
        // reading itself is uncertain) — except component refusals, which are
        // checked first. This synthetic compound is not producible by the
        // real authority; it pins the documented precedence only.
        assertEquals(LocalRuntimeRecovery.PROBE,
            localRuntimeRecovery("lane:unbound|refusal:peerUnmeasurable|stage:"))
    }

    // MARK: - cross-function consistency with the card state

    @Test fun unverifiedNeverCarriesNoneAndPreparingNeverCarriesGuidance() {
        val unverifiedTokens = listOf(
            null, "", "lane:unbound", "status:unreadable",
            "missing:runtimeUidBoundaryVerified|refusal:|stage:",
            "missing:rootfsQualified|refusal:componentVersionStale|stage:",
            "missing:workspaceMappingSynced|refusal:ingress_failed|stage:",
            "missing:leaseAuthorityQualified|refusal:|stage:preflight_evidence",
        )
        for (token in unverifiedTokens) {
            assertEquals("token=$token", LocalRuntimeTaskState.UNVERIFIED,
                localRuntimeTaskState(false, token))
            assertNotEquals("token=$token", LocalRuntimeRecovery.NONE,
                localRuntimeRecovery(token))
        }
        val preparingTokens = listOf(
            "missing:workspaceMappingSynced|refusal:|stage:",
            "missing:leaseAuthorityQualified|refusal:|stage:",
        )
        for (token in preparingTokens) {
            assertEquals("token=$token", LocalRuntimeTaskState.PREPARING_WORKSPACE,
                localRuntimeTaskState(false, token))
            assertEquals("token=$token", LocalRuntimeRecovery.NONE, localRuntimeRecovery(token))
        }
        assertEquals(LocalRuntimeTaskState.READY, localRuntimeTaskState(true, null))
        assertEquals(LocalRuntimeRecovery.NONE, localRuntimeRecovery("ready"))
        // Sanity: the recovery enum stays a closed five-value set.
        assertTrue(LocalRuntimeRecovery.values().size == 5)
    }
}
