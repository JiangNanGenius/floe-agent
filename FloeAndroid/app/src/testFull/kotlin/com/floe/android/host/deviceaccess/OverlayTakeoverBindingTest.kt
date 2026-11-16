// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayTakeoverBindingTest {
    @Test fun takeoverRemainsBoundAcrossTouchButNotANewEpochOrRunGeneration() {
        val stamp = mapOf("task/run" to 4L)
        val binding = OverlayTakeoverBinding(epoch = 11L, ownerRevision = 7L, streamStamp = stamp)
        // Accessibility owner loss is intentionally not a grant or input to
        // this stop-only check: the original gesture must still be honored.
        assertTrue(binding.matches(11L, 7L, stamp, closed = false))
        assertFalse(binding.matches(null, 7L, stamp, closed = false))
        assertFalse(binding.matches(12L, 7L, stamp, closed = false))
        assertFalse(binding.matches(11L, 8L, stamp, closed = false))
        assertFalse(binding.matches(11L, 7L, mapOf("task/run" to 5L), closed = false))
        assertFalse(binding.matches(11L, 7L, stamp, closed = true))
    }
}
