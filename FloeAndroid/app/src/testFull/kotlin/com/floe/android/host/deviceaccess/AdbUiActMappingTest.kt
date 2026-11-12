// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlAction
import com.floe.android.phonecontrol.PhoneControlFailure
import com.floe.android.phonecontrol.PhoneControlScrollDirection
import com.floe.android.phonecontrol.PhoneControlSwipeDirection
import com.floe.android.rootsystem.UiAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The real App-side adapter must preserve the existing action.sensitive
 * distinction into the typed request. Ordinary text stays unmarked; an
 * explicit sensitiveText payload is marked exactly once and never appears in
 * a diagnostic representation. No new secret alias is introduced.
 */
class AdbUiActMappingTest {

    @Test fun failedInvokedMutationsRequireReadbackInsteadOfBeingCalledRejected() {
        assertEquals(PhoneControlFailure.TIMEOUT, AdbUiActMapping.failureReason("timeout"))
        assertEquals(PhoneControlFailure.INTERNAL_ERROR, AdbUiActMapping.failureReason("transport_failure"))
        assertEquals(PhoneControlFailure.INTERNAL_ERROR, AdbUiActMapping.failureReason("ui_failed"))
    }

    private val canary = "CANARY-adb-mapping"

    @Test fun explicitSensitiveTextIsCarriedAsAnIntent() {
        val request = AdbUiActMapping.request(
            observationId = "adbui-observation",
            nodeRef = "n7",
            action = PhoneControlAction.SetText("n7", canary, sensitive = true),
        )
        assertEquals(UiAction.SET_TEXT, request.action)
        assertEquals("n7", request.nodeRef)
        assertEquals(canary, request.sensitiveText)
        assertTrue(request.sensitiveTextIntent)
        assertFalse(request.toString().contains(canary))
    }

    @Test fun ordinaryTextIsNeverMarkedSensitive() {
        val request = AdbUiActMapping.request(
            observationId = "adbui-observation",
            nodeRef = "n7",
            action = PhoneControlAction.SetText("n7", "hello", sensitive = false),
        )
        assertEquals("hello", request.sensitiveText)
        assertFalse(request.sensitiveTextIntent)
    }

    @Test fun nonTextActionsCarryNoPayloadOrIntent() {
        val click = AdbUiActMapping.request(
            observationId = "adbui-observation",
            nodeRef = "n2",
            action = PhoneControlAction.Click("n2"),
        )
        assertEquals(UiAction.CLICK, click.action)
        assertNull(click.sensitiveText)
        assertFalse(click.sensitiveTextIntent)

        val back = AdbUiActMapping.request(
            observationId = "adbui-observation",
            nodeRef = null,
            action = PhoneControlAction.Back,
        )
        assertEquals(UiAction.BACK, back.action)
        assertNull(back.sensitiveText)
        assertFalse(back.sensitiveTextIntent)
    }

    @Test fun scrollAndSwipeDirectionsKeepTheirRealNames() {
        assertEquals(
            "forward",
            AdbUiActMapping.request(
                "obs",
                "n1",
                PhoneControlAction.Scroll("n1", PhoneControlScrollDirection.FORWARD),
            ).direction,
        )
        assertEquals(
            "backward",
            AdbUiActMapping.request(
                "obs",
                "n1",
                PhoneControlAction.Scroll("n1", PhoneControlScrollDirection.BACKWARD),
            ).direction,
        )
        assertEquals(
            "left",
            AdbUiActMapping.request(
                "obs",
                "n1",
                PhoneControlAction.Swipe("n1", PhoneControlSwipeDirection.LEFT),
            ).direction,
        )
    }

    @Test fun launchKeepsTheExplicitTargetPackage() {
        val request = AdbUiActMapping.request(
            observationId = "",
            nodeRef = null,
            action = PhoneControlAction.Launch("com.example.target"),
        )
        assertEquals(UiAction.LAUNCH, request.action)
        assertEquals("com.example.target", request.targetPackage)
        assertFalse(request.sensitiveTextIntent)
    }

    @Test fun diagnosticNoteIsStaticAndCarriesNoInput() {
        val note = AdbUiActMapping.note("input_partial", "release=confirmed")
        assertEquals("input_partial release=confirmed", note)
        assertFalse(note.orEmpty().contains(canary))
        assertNull(AdbUiActMapping.note(null, null))
    }

    @Test fun thePhoneActionToStringAlsoRedactsTheValue() {
        val action = PhoneControlAction.SetText("n4", canary, sensitive = true)
        assertFalse(action.toString().contains(canary))
        assertTrue(action.toString().contains("sensitive=true"))
    }
}
