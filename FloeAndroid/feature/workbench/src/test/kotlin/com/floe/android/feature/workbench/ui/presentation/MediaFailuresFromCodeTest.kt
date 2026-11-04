// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.presentation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The playback path reports terminal platform refusals as bounded wire codes
 * on PlaybackState (its prepare is asynchronous, so nothing is thrown). These
 * codes must map to the same truthful failure surface as thrown exceptions so
 * the editor can show a real failure instead of a black, inert preview.
 */
class MediaFailuresFromCodeTest {
    @Test
    fun nullAndEmptyCodesStaySilent() {
        assertNull(MediaFailures.fromCode(null))
        assertNull(MediaFailures.fromCode(""))
    }

    @Test
    fun capabilityRefusalsMapToUnsupported() {
        assertEquals(
            MediaFailureKind.UNSUPPORTED,
            MediaFailures.fromCode("unsupportedSourceFormat")?.kind,
        )
        assertEquals(
            MediaFailureKind.UNSUPPORTED,
            MediaFailures.fromCode("rendererUnavailable")?.kind,
        )
        assertEquals(
            MediaFailureKind.UNSUPPORTED,
            MediaFailures.fromCode("unsupportedCodec")?.kind,
        )
        assertEquals(
            MediaFailureKind.UNSUPPORTED,
            MediaFailures.fromCode("renderUnsupported")?.kind,
        )
    }

    @Test
    fun sessionAndTicketCodesKeepTheirKinds() {
        assertEquals(
            MediaFailureKind.SESSION_LOST,
            MediaFailures.fromCode("staleSession")?.kind,
        )
        assertEquals(
            MediaFailureKind.EXPORT,
            MediaFailures.fromCode("renderTicketExpired")?.kind,
        )
    }

    @Test
    fun runtimeWaitingIsRetryable() {
        val failure = MediaFailures.fromCode("runtimeUnavailable")
        assertEquals(MediaFailureKind.RUNTIME_NOT_READY, failure?.kind)
        assertTrue(failure?.retryable == true)
    }

    @Test
    fun capabilityRefusalsAreNotRetryable() {
        assertFalse(MediaFailures.fromCode("unsupportedSourceFormat")?.retryable == true)
    }

    @Test
    fun unknownCodesStayUnknownButVisible() {
        val failure = MediaFailures.fromCode("someFutureCode")
        assertEquals(MediaFailureKind.UNKNOWN, failure?.kind)
        assertEquals("someFutureCode", failure?.code)
    }
}
