// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import com.floe.android.rootsystem.UiActRequest
import com.floe.android.rootsystem.UiAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The explicit sensitiveText intent is an appended v4 Bundle field. It may
 * only travel with exactly one SET_TEXT payload; payloads on other actions,
 * an intent without a payload, and out-of-grant targets are refused before
 * the service sees a dispatch. The payload canary must never appear in a
 * diagnostic representation.
 */
class UiActWireDecodeTest {

    private val canary = "CANARY-9f3c-do-not-log"

    private fun decode(
        observationId: String? = "obs-1",
        nodeRef: String? = "n1",
        actionWire: String? = "setText",
        direction: String? = null,
        targetPackage: String? = null,
        sensitiveText: String? = canary,
        sensitiveTextIntent: Boolean = true,
        targets: Set<String> = setOf("com.example.target"),
    ): BinderProtocol.UiActDecode = BinderProtocol.decodeUiActFields(
        observationId = observationId,
        nodeRef = nodeRef,
        actionWire = actionWire,
        direction = direction,
        targetPackage = targetPackage,
        sensitiveText = sensitiveText,
        sensitiveTextIntent = sensitiveTextIntent,
        targets = targets,
    )

    private fun ok(decoded: BinderProtocol.UiActDecode): BinderProtocol.UiActFields {
        assertTrue("expected Ok but was $decoded", decoded is BinderProtocol.UiActDecode.Ok)
        return (decoded as BinderProtocol.UiActDecode.Ok).fields
    }

    private fun failureCode(decoded: BinderProtocol.UiActDecode): String {
        assertTrue(
            "expected Failure but was $decoded",
            decoded is BinderProtocol.UiActDecode.Failure,
        )
        return (decoded as BinderProtocol.UiActDecode.Failure).code
    }

    @Test fun explicitSensitiveIntentSurvivesTheWireDecode() {
        val fields = ok(decode())
        assertTrue(fields.sensitiveTextIntent)
        assertEquals(canary, fields.sensitiveText)
        assertEquals(UiAction.SET_TEXT, fields.action)
        assertFalse(fields.toString().contains(canary))
    }

    @Test fun ordinaryTextKeepsTheOrdinaryIntent() {
        val fields = ok(decode(sensitiveText = "hello world", sensitiveTextIntent = false))
        assertFalse(fields.sensitiveTextIntent)
        assertEquals("hello world", fields.sensitiveText)
    }

    @Test fun anEmptyExplicitClearIsAValidPayload() {
        val fields = ok(decode(sensitiveText = "", sensitiveTextIntent = true))
        assertTrue(fields.sensitiveTextIntent)
        assertEquals("", fields.sensitiveText)
    }

    @Test fun intentWithoutPayloadIsRefused() {
        assertEquals("ui_text", failureCode(decode(sensitiveText = null)))
    }

    @Test fun payloadOnANonSetTextActionIsRefused() {
        assertEquals(
            "ui_text",
            failureCode(decode(actionWire = "click")),
        )
    }

    @Test fun intentOnANonSetTextActionIsRefused() {
        assertEquals(
            "ui_text",
            failureCode(
                decode(
                    actionWire = "click",
                    sensitiveText = null,
                    sensitiveTextIntent = true,
                ),
            ),
        )
    }

    @Test fun outOfGrantTargetIsRefused() {
        assertEquals(
            "target_not_authorized",
            failureCode(decode(targetPackage = "com.example.other")),
        )
    }

    @Test fun closedVocabularyIsEnforced() {
        assertEquals("ui_action", failureCode(decode(actionWire = "rawTap")))
        assertEquals(
            "ui_direction",
            failureCode(decode(actionWire = "scroll", direction = "sideways")),
        )
    }

    @Test fun payloadAndIdentifierBoundsAreEnforced() {
        assertEquals(
            "ui_text",
            failureCode(decode(sensitiveText = "x".repeat(2_001))),
        )
        assertEquals(
            "ui_observation_invalid",
            failureCode(decode(observationId = "o".repeat(65))),
        )
        assertEquals(
            "ui_observation_invalid",
            failureCode(decode(nodeRef = "n".repeat(33))),
        )
    }

    @Test fun emptyObservationIdStaysTheLaunchStyleEmptyString() {
        val fields = ok(decode(observationId = null))
        assertEquals("", fields.observationId)
    }

    @Test fun requestToStringRedactsThePayload() {
        val request = UiActRequest(
            observationId = "obs-1",
            nodeRef = "n1",
            action = UiAction.SET_TEXT,
            sensitiveText = canary,
            sensitiveTextIntent = true,
        )
        assertFalse(request.toString().contains(canary))
        assertTrue(request.toString().contains("<redacted>"))
        assertTrue(request.toString().contains("sensitiveTextIntent=true"))
    }

    @Test fun intentDefaultsToFalseForExistingCallers() {
        val request = UiActRequest(
            observationId = "obs-1",
            nodeRef = "n1",
            action = UiAction.SET_TEXT,
            sensitiveText = "ordinary",
        )
        assertFalse(request.sensitiveTextIntent)
    }
}
