// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.core.officeengine.precision.OfficePrecisionAction
import com.floe.android.core.officeengine.precision.OfficePrecisionAttestation
import com.floe.android.core.officeengine.precision.OfficePrecisionFailure
import com.floe.android.core.officeengine.precision.OfficePrecisionRequest
import com.floe.android.core.officeengine.precision.OfficePrecisionResult
import com.floe.android.core.officeengine.precision.OfficePrecisionState
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure classification for the production precision adapter (Main production
 * review 2026-10-27, AUTHORED NOTRUN): only the client-local
 * `engine-command-binding-unavailable` refusal proves NOTHING was sent and
 * may be retried during the bounded pre-dispatch bind wait. A
 * `binder-transport-failed` shape (postPrecisionCommand attempted, reply
 * lost), a `poll-interrupted` shape, any other transport detail, or a null
 * client frame outcome are AMBIGUOUS_RETAINED: the adapter must re-read the
 * real terminal for the SAME op identity and, without proof, relay an honest
 * UNKNOWN — never a clean rejected/nothing-sent claim and never an automatic
 * re-dispatch. Normal terminal results (including the client-side
 * UNKNOWN+TIMEOUT deadline shape) are SETTLED relays.
 *
 * office-background-repair118 (the actual C17 DOCX/PPTX first failures): the
 * ENGINE's own pre-dispatch transport refusals (details `edit-preparation:*`,
 * `mount-ended-*`, ...) share the REJECTED+TRANSPORT shape but are classified
 * by the producer's OWN dispatch proof
 * ([OfficePrecisionResult.attestation] ==
 * [OfficePrecisionAttestation.REFUSED_BEFORE_DISPATCH], written only when no
 * effect wire was dispatched). Those are SETTLED - relaying them as a
 * post-send UNKNOWN fabricated a possible effect the engine had proven
 * absent. A refusal attested AFTER an effect wire, or carrying any non-proof
 * lineage, stays AMBIGUOUS_RETAINED.
 */
class OfficeAiPrecisionTransportTest {

    private fun request() = OfficePrecisionRequest(
        opId = "ap-1", sessionToken = "sess", generation = 7L,
        action = OfficePrecisionAction.SET_CELL_CONTENT, text = "00123",
    )

    private fun result(
        state: OfficePrecisionState,
        failure: OfficePrecisionFailure?,
        detail: String?,
        attestation: String = "test",
    ): OfficePrecisionResult = OfficePrecisionResult(
        opId = "ap-1", sessionToken = "sess", generation = 7L,
        action = OfficePrecisionAction.SET_CELL_CONTENT, state = state, failure = failure,
        detail = detail, answer = null, attestation = attestation,
        submittedAtElapsedMs = 0L, completedAtElapsedMs = 1L,
    )

    @Test
    fun onlyThePreDispatchBindRefusalIsRetryable() {
        assertEquals(
            PrecisionTransportDisposition.PRE_DISPATCH_RETRYABLE,
            classifyPrecisionResult(result(
                OfficePrecisionState.REJECTED, OfficePrecisionFailure.TRANSPORT,
                "engine-command-binding-unavailable",
            )),
        )
    }

    @Test
    fun postAttemptAndUnknownDetailAmbiguityIsRetainedNeverRetried() {
        for (detail in listOf("binder-transport-failed", "poll-interrupted", "something-else", null)) {
            assertEquals(
                "detail=$detail",
                PrecisionTransportDisposition.AMBIGUOUS_RETAINED,
                classifyPrecisionResult(result(
                    OfficePrecisionState.REJECTED, OfficePrecisionFailure.TRANSPORT, detail,
                )),
            )
        }
        assertEquals(
            PrecisionTransportDisposition.AMBIGUOUS_RETAINED,
            classifyPrecisionResult(null),
        )
    }

    @Test
    fun engineProvenPreDispatchRefusalIsSettledNotAmbiguous() {
        // The exact C17 first-failure shapes: the engine refused BEFORE any
        // plan wire and said so in its own attestation. These must settle as
        // the engine's own REJECTED result — never laundered into an
        // ambiguous post-send UNKNOWN that fabricated a possible effect.
        for (detail in listOf(
            "edit-preparation:page-edit-hook-unavailable", // DOCX applyText
            "edit-preparation:page-health-verification-failed", // PPTX selectSlide
            "mount-ended-before-dispatch",
        )) {
            assertEquals(
                "detail=$detail",
                PrecisionTransportDisposition.SETTLED,
                classifyPrecisionResult(result(
                    OfficePrecisionState.REJECTED, OfficePrecisionFailure.TRANSPORT,
                    detail, attestation = OfficePrecisionAttestation.REFUSED_BEFORE_DISPATCH,
                )),
            )
        }
    }

    @Test
    fun postDispatchRefusalLineageStaysAmbiguousAndRetained() {
        // A refusal attested AFTER an effect-bearing wire was really posted is
        // maybe-effect: re-read + honest UNKNOWN, NEVER settled and NEVER
        // auto-replayed. The engine-detail catch-all must not widen it.
        assertEquals(
            PrecisionTransportDisposition.AMBIGUOUS_RETAINED,
            classifyPrecisionResult(result(
                OfficePrecisionState.REJECTED, OfficePrecisionFailure.TRANSPORT,
                "mount-ended-before-step",
                attestation = OfficePrecisionAttestation.REFUSED_AFTER_EFFECT_DISPATCH,
            )),
        )
    }

    @Test
    fun engineDetailWithoutDispatchProofStaysAmbiguous() {
        // The pre-dispatch attestation is the ONLY settled transport shape: an
        // engine detail carrying a NON-proof lineage stays ambiguous/retained.
        assertEquals(
            PrecisionTransportDisposition.AMBIGUOUS_RETAINED,
            classifyPrecisionResult(result(
                OfficePrecisionState.REJECTED, OfficePrecisionFailure.TRANSPORT,
                "edit-preparation:page-edit-hook-unavailable", attestation = "engine-other",
            )),
        )
    }

    @Test
    fun realTerminalsAreRelayedNotReclassified() {
        assertEquals(
            PrecisionTransportDisposition.SETTLED,
            classifyPrecisionResult(result(OfficePrecisionState.MUTATION_VERIFIED, null, null)),
        )
        assertEquals(
            PrecisionTransportDisposition.SETTLED,
            classifyPrecisionResult(result(OfficePrecisionState.UNKNOWN, OfficePrecisionFailure.TIMEOUT,
                "client-deadline-exceeded-engine-may-still-settle")),
        )
        assertEquals(
            PrecisionTransportDisposition.SETTLED,
            classifyPrecisionResult(result(OfficePrecisionState.REJECTED, OfficePrecisionFailure.SESSION_MISMATCH,
                null)),
        )
    }
}
