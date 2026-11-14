// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The floating control projects only a bounded, inert operation status. It
 * must never become a text sink for typed input, node content, credentials or
 * model arguments, and an accepted launch must not be presented as a rendered
 * viewer.
 */
class DeviceArtifact113OverlayStatusTest {

    @Test
    fun settledScreenWorkHidesBubbleUntilTheNextRealOperation() {
        fun visible(state: PhoneAutomationOperationState?) =
            PhoneAutomationStatusText.showsOverlay(false, false, state)
        assertFalse(visible(null))
        assertTrue(visible(PhoneAutomationOperationState.RUNNING))
        for (settled in listOf(PhoneAutomationOperationState.DONE,
            PhoneAutomationOperationState.FAILED, PhoneAutomationOperationState.UNKNOWN,
            PhoneAutomationOperationState.CANCELLED)) {
            repeat(3) { assertFalse(visible(settled)) }
        }
        assertTrue(visible(PhoneAutomationOperationState.RUNNING))
    }

    @Test
    fun explicitPauseAndUserWaitRetainTheResumeControl() {
        assertTrue(PhoneAutomationStatusText.showsOverlay(true, false, null))
        assertTrue(PhoneAutomationStatusText.showsOverlay(false, true, null))
        assertTrue(PhoneAutomationStatusText.showsOverlay(
            false, false, PhoneAutomationOperationState.WAITING))
    }

    @Test
    fun statusIsSingleLineBoundedAndFreeOfControlCharacters() {
        val value = "Tap\u0000\nfile\r\nname-${"x".repeat(80)}"
        val bounded = PhoneAutomationStatusText.bounded(value, 16)
        assertEquals("Tapfilename-xxxx", bounded)
        assertEquals(16, bounded.length)
        assertEquals("", PhoneAutomationStatusText.bounded("\n\r\t", 12))
        assertEquals("", PhoneAutomationStatusText.bounded("anything", 0))
    }

    @Test
    fun operationKeepsOnlyABoundedLabelAndFixedState() {
        val running = PhoneAutomationStatusText.operation(
            "Reading screen ${"y".repeat(80)}",
            PhoneAutomationOperationState.RUNNING,
            "viewer window not observed ${"z".repeat(80)}",
        )
        assertEquals(PhoneAutomationStatusText.MAX_LABEL, running.label.length)
        assertEquals(PhoneAutomationOperationState.RUNNING, running.state)
        assertEquals(PhoneAutomationStatusText.MAX_NOTE, running.note?.length)
        // The model carries only the bounded label, fixed state and bounded
        // note; no typed value, node text or credential field exists.
    }

    @Test
    fun emptyOrControlOnlyNoteIsDropped() {
        assertNull(PhoneAutomationStatusText.operation(
            "Open", PhoneAutomationOperationState.DONE, "\n\r\u0000").note)
        assertNull(PhoneAutomationStatusText.operation(
            "Open", PhoneAutomationOperationState.DONE, null).note)
    }

    @Test
    fun failedAndUnknownRemainDistinctForTheOverlay() {
        assertEquals(PhoneAutomationOperationState.FAILED,
            PhoneAutomationStatusText.operation(
                "Tap", PhoneAutomationOperationState.FAILED).state)
        assertEquals(PhoneAutomationOperationState.UNKNOWN,
            PhoneAutomationStatusText.operation(
                "Open", PhoneAutomationOperationState.UNKNOWN).state)
        assertEquals(PhoneAutomationOperationState.CANCELLED,
            PhoneAutomationStatusText.operation(
                "Tap", PhoneAutomationOperationState.CANCELLED).state)
        assertEquals(PhoneAutomationOperationState.WAITING,
            PhoneAutomationStatusText.operation(
                "Tap", PhoneAutomationOperationState.WAITING).state)
    }
}
