// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UiGuardConnectionFenceTest {
    @Test fun onlyTheSameLiveClientAndGenerationCanAcknowledgeSync() {
        val old = Any()
        val replacement = Any()
        assertTrue(UiGuardConnectionFence.isCurrent(old, 10, old, 10, true))
        assertFalse(UiGuardConnectionFence.isCurrent(old, 10, replacement, 11, true))
        assertFalse(UiGuardConnectionFence.isCurrent(old, 10, old, 11, true))
        assertFalse(UiGuardConnectionFence.isCurrent(old, 10, null, 11, false))
        assertFalse(UiGuardConnectionFence.isCurrent(old, 10, old, 10, false))
    }
}
