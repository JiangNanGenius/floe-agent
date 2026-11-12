// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The explicit sensitiveText intent is the only way into a protected field;
 * ordinary unmarked text stays refused there. A live protection change is
 * stale before dispatch, and a value is never read back.
 */
class UiSensitiveInputPolicyTest {

    private fun denial(
        hasText: Boolean = true,
        sensitiveIntent: Boolean = false,
        storedPassword: Boolean = false,
        storedRedacted: Boolean = false,
        livePassword: Boolean = false,
        liveRedacted: Boolean = false,
        liveEditable: Boolean = true,
        advertisesSetText: Boolean = false,
    ): String? = UiSensitiveInputPolicy.denial(
        hasText = hasText,
        sensitiveIntent = sensitiveIntent,
        storedPassword = storedPassword,
        storedRedacted = storedRedacted,
        livePassword = livePassword,
        liveRedacted = liveRedacted,
        liveEditable = liveEditable,
        advertisesSetText = advertisesSetText,
    )

    @Test fun ordinaryTextCannotEnterAPasswordField() {
        assertEquals(
            "sensitive_field",
            denial(storedPassword = true, storedRedacted = true,
                livePassword = true, liveRedacted = true),
        )
    }

    @Test fun explicitSensitiveIntentCanFillAnUnchangedPasswordField() {
        assertNull(
            denial(sensitiveIntent = true, storedPassword = true,
                storedRedacted = true, livePassword = true, liveRedacted = true),
        )
    }

    @Test fun ordinaryTextStillWorksOnAnOrdinaryEditableField() {
        assertNull(denial())
    }

    @Test fun sensitiveIntentOnAnOrdinaryFieldStaysAValidExplicitDispatch() {
        assertNull(denial(sensitiveIntent = true))
    }

    @Test fun missingPayloadIsRefused() {
        assertEquals("text_required", denial(hasText = false, sensitiveIntent = true))
    }

    @Test fun aLiveProtectionChangeIsStaleEvenWithSensitiveIntent() {
        assertEquals(
            "sensitive_field_changed",
            denial(sensitiveIntent = true, livePassword = true, liveRedacted = true),
        )
        assertEquals(
            "sensitive_field_changed",
            denial(storedPassword = true, storedRedacted = true),
        )
    }

    @Test fun aSensitiveViewIdFieldAlsoNeedsTheExplicitIntent() {
        assertEquals(
            "sensitive_field",
            denial(storedRedacted = true, liveRedacted = true),
        )
        assertNull(denial(sensitiveIntent = true, storedRedacted = true,
            liveRedacted = true))
    }

    @Test fun nonEditableNodeWithoutSetTextActionIsRefused() {
        assertEquals(
            "not_editable",
            denial(liveEditable = false, advertisesSetText = false),
        )
        assertNull(denial(liveEditable = false, advertisesSetText = true))
    }
}
