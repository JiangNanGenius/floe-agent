// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * N03 seam-contract regressions — AUTHORED, NOTRUN (pure JVM, synthetic
 * recording host only).
 *
 * [ConversationUiCallbacks.requestOpenConversationRun] ships with a
 * conservative default so fixtures and secondary surfaces that only
 * implement the task-only contract stay honest:
 *  * a null/blank run id delegates EXACTLY to requestOpenConversation (the
 *    honest task-only fallback — schedule history hides the action entirely
 *    when the record carries no conversation id);
 *  * a real run target is refused by the default (never faked): only the
 *    App host overrides it with the validated exact-run presentation.
 */
class ConversationOpenRunDefaultContractTest {

    @Test
    fun nullRunIdDelegatesExactlyToThePlainOpen() {
        val host = RecordingHost()
        assertTrue(host.requestOpenConversationRun(null, "conv-1", null))
        assertEquals(
            listOf<Any?>(null, "conv-1"),
            host.lastArgs("requestOpenConversation"),
        )
        assertEquals(1, host.count("requestOpenConversation"))
    }

    @Test
    fun blankRunIdDelegatesExactlyToThePlainOpen() {
        val host = RecordingHost()
        assertTrue(host.requestOpenConversationRun(null, "conv-1", "  "))
        assertEquals(
            listOf<Any?>(null, "conv-1"),
            host.lastArgs("requestOpenConversation"),
        )
    }

    @Test
    fun realRunTargetIsRefusedByTheHonestDefault() {
        val host = RecordingHost()
        // Even when the plain open would be accepted, the default must not
        // pretend it located a run: refusal, and NO navigation side effect.
        assertFalse(host.requestOpenConversationRun(null, "conv-1", "run-9"))
        assertEquals(0, host.count("requestOpenConversation"))
    }
}
