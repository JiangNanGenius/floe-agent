// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.core.officeengine.precision.OfficePrecisionAction
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
    ): OfficePrecisionResult = OfficePrecisionResult(
        opId = "ap-1", sessionToken = "sess", generation = 7L,
        action = OfficePrecisionAction.SET_CELL_CONTENT, state = state, failure = failure,
        detail = detail, answer = null, attestation = "test",
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
