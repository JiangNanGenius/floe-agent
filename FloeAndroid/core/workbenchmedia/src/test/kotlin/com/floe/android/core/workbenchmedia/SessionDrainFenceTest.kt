// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.SessionDrainFence
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionDrainFenceTest {
    @Test
    fun drainFenceIsOneWayAndRejectsNewAcceptance() {
        val fence = SessionDrainFence()
        assertFalse(fence.isFenced())
        assertTrue(fence.fence())
        assertTrue(fence.isFenced())
        assertFalse(fence.fence())
        var refused = false
        try {
            fence.ensureAccepting()
        } catch (_: MediaRefusal) {
            refused = true
        }
        assertTrue(refused)
    }
}
