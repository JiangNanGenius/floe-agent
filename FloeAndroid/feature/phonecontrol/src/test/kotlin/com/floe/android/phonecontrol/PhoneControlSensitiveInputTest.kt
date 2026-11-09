// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Sensitive-text input boundary: a user-provided credential arriving via the
 * explicit `sensitiveText` wire parameter may be FILLED into an editable
 * protected field of an already-authorized user app, while every window,
 * navigation-only, screenshot and echo-silence guard stays exactly as before.
 * Password fields expose only safe identity/position/editability, never a
 * value. All payloads are synthetic canaries, never real credentials.
 */
class PhoneControlSensitiveInputTest {

    private fun protectedRecord(
        password: Boolean = true,
        redacted: Boolean = false,
        editable: Boolean = true,
    ) = PhoneControlNodeRecord(
        ref = "n0",
        path = listOf(0),
        className = "android.widget.EditText",
        packageName = "com.example.app",
        viewId = "com.example.app:id/password",
        bounds = PhoneControlBounds(0, 0, 100, 50),
        password = password,
        redacted = redacted,
        clickable = false,
        editable = editable,
        scrollable = false,
    )

    @Test
    fun ordinaryTextStillRefusesEveryProtectedField() {
        assertEquals(
            PhoneControlDenial.SENSITIVE_FIELD,
            PhoneControlPolicy.fieldActionDenial(protectedRecord(password = true)),
        )
        assertEquals(
            PhoneControlDenial.SENSITIVE_FIELD,
            PhoneControlPolicy.fieldActionDenial(
                protectedRecord(password = false, redacted = true),
            ),
        )
        // The sensitive route never reaches swipe.
        assertEquals(
            PhoneControlDenial.SENSITIVE_FIELD,
            PhoneControlPolicy.fieldActionDenial(protectedRecord(password = true), false),
        )
    }

    @Test
    fun sensitiveRouteOpensOnlyTheFieldGate() {
        assertNull(
            PhoneControlPolicy.fieldActionDenial(
                protectedRecord(password = true),
                sensitiveInput = true,
            ),
        )
        assertNull(
            PhoneControlPolicy.fieldActionDenial(
                protectedRecord(password = false, redacted = true),
                sensitiveInput = true,
            ),
        )
        // A non-editable record is still refused by the session's editable
        // checks before this gate is consulted; this gate never weakens them.
        assertEquals(
            PhoneControlDenial.SENSITIVE_FIELD,
            PhoneControlPolicy.fieldActionDenial(
                protectedRecord(password = true),
                sensitiveInput = false,
            ),
        )
    }

    @Test
    fun sensitiveInputCannotCrossWindowLockOrSystemProtections() {
        // Known App passwords never enable lockscreen bypass.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.nodeActionDenial(
                "com.example.app", "com.example.app.LoginActivity", 1,
                hasPassword = true, keyguardLocked = true,
            ),
        )
        // System credential/lock screens stay protected even unlocked.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.nodeActionDenial(
                "com.android.settings", "com.android.settings.ConfirmLockPassword", 1,
                hasPassword = false, keyguardLocked = false,
            ),
        )
        // System password dialogs stay protected.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.nodeActionDenial(
                "android", "android.app.AlertDialog", 3,
                hasPassword = true, keyguardLocked = false,
            ),
        )
        // A user-app login screen is NOT a protected window: the field gate
        // above is the only remaining check, and the sensitive route is the
        // explicit way to satisfy it.
        assertNull(
            PhoneControlPolicy.nodeActionDenial(
                "com.example.bank", "com.example.bank.LoginActivity", 1,
                hasPassword = true, keyguardLocked = false,
            ),
        )
        // And the Floe family stays fully protected.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.nodeActionDenial(
                "com.floe.agent.full", "com.floe.agent.MainActivity", 1,
                hasPassword = false, keyguardLocked = false,
            ),
        )
    }

    @Test
    fun navigationOnlyObservationNeverCarriesSensitiveInput() {
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.navigationOnlyActionDenial(
                navigationOnly = true,
                allowGlobalNavigation = true,
                action = PhoneControlAction.SetText("n0", CANARY, sensitive = true),
            ),
        )
    }

    @Test
    fun screenshotGateStaysSeparateFromTextInput() {
        // Filling a password field does not make the page screenshotable.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.screenshotDenial(
                allowScreenshot = true,
                keyguardLocked = false,
                protectedWindow = false,
                hasPassword = true,
            ),
        )
    }

    @Test
    fun credentialNeverSurvivesToStringReceiptsOrProjections() {
        val action = PhoneControlAction.SetText("n1", CANARY, sensitive = true)
        assertFalse(action.toString().contains(CANARY))
        assertTrue(action.toString().contains("sensitive=true"))
        val filled = postFillObservation()
        val result = PhoneControlActionResult(
            action = action.wireName,
            dispatch = PhoneControlDispatch.ACCEPTED,
            gestureCompleted = null,
            observation = filled,
            screenChanged = false,
            note = "framework accepted the action; re-observation is the effect check",
        )
        val json = PhoneControlJson.actionResult(result)
        assertFalse(json.contains(CANARY))
        val digest = PhoneControlObservationText.summary(filled)
        assertFalse(digest.contains(CANARY))
    }

    @Test
    fun protectedFieldsExposeOnlySafeIdentityPositionAndEditability() {
        val nodes = listOf(
            testNode(
                ref = "n0", className = "android.widget.EditText",
                viewId = "com.example.app:id/password",
                editable = true, password = true, redacted = true,
            ),
            testNode(
                ref = "n1", className = "android.widget.EditText",
                viewId = "com.example.app:id/password2",
                editable = true, password = true, redacted = true, visible = false,
            ),
            testNode(
                ref = "n2", className = "android.widget.EditText",
                editable = true,
            ),
        )
        val text = PhoneControlObservationText.summary(testObservation(nodes))
        // Safe metadata: protected + editable is discoverable for the
        // sensitiveText route...
        assertTrue(text.contains("n0|EditText|pe|[protected]"))
        // ...but a hidden protected field never advertises editability.
        assertTrue(text.contains("n1|EditText|hp|[protected]"))
        assertFalse(text.contains("n1|EditText|hpe|"))
        // Ordinary inputs keep their exact old projection.
        assertTrue(text.contains("n2|EditText|e|[empty input]"))
        assertTrue(text.contains("p=protected input"))
        assertTrue(text.contains("sensitiveText"))
    }

    @Test
    fun sensitiveSetTextKeepsTheSharedLengthCeiling() {
        // The client and session cap both keys at MAX_SET_TEXT_CHARS.
        val tooLong = "x".repeat(PhoneControlLimits.MAX_SET_TEXT_CHARS + 1)
        val action = PhoneControlAction.SetText("n0", tooLong, sensitive = true)
        assertTrue(action.text.length > PhoneControlLimits.MAX_SET_TEXT_CHARS)
        assertFalse(action.toString().contains("xxxx"))
    }

    private fun postFillObservation(): PhoneControlObservation =
        testObservation(
            nodes = listOf(
                testNode(
                    ref = "n0", className = "android.widget.EditText",
                    viewId = "com.example.app:id/password",
                    editable = true, password = true, redacted = true,
                ),
            ),
            sensitiveWindow = true,
        )

    private companion object {
        /** Synthetic canary only — never a real credential. */
        const val CANARY = "canary-9f2c-never-echoed"
    }
}
