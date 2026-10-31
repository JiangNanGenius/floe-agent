// SPDX-License-Identifier: MPL-2.0
// Proposed JVM regression source. Authored only in this private lane; Main
// runs it in the batched JVM set. No compile/run claim here.
package com.floe.android

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Terminal/drawer keyboard ownership (Samsung G07.3B device evidence,
 * 2026-10-31): leaving the terminal could keep the IME above the compact
 * drawer bottom, and system Back navigated/closes the inspector BEFORE the
 * keyboard was dismissed.
 *
 * The fix is an event-time policy, never a blanket hide on recomposition:
 * while the IME is visible the first Back is ONLY the keyboard dismissal;
 * the surface's own back action runs on the next Back when the IME is gone.
 */
class ImeBackPolicyTest {

    @Test
    fun visibleImeSwallowsTheFirstBackAsKeyboardDismissal() {
        assertEquals(ImeBackDisposition.DISMISS_IME, imeBackDisposition(imeVisible = true))
    }

    @Test
    fun hiddenImeRunsTheSurfaceBackAction() {
        assertEquals(ImeBackDisposition.INVOKE_BACK, imeBackDisposition(imeVisible = false))
    }
}
