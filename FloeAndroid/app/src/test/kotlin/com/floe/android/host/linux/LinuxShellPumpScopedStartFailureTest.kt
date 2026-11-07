// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LinuxShellPumpScopedStartFailureTest {
    private val id = "e7b8dc52-9600-4000-8000-000000000049"
    private fun receipt(state: String = "failed", request: String = id, released: String = "true") =
        """{"state":"$state","requestID":"$request","requestReleased":$released}"""

    @Test fun failedStartCanRetireWhileTheSiblingEngineIsActive() {
        assertTrue(LinuxShellPump.isReleasedFailedStartReceipt(
            receipt().dropLast(1) + ",\"active\":true}", id))
    }

    @Test fun pendingOrRetainedOwnershipDoesNotRetire() {
        for (state in listOf("unknown", "queued", "running", "completed")) {
            assertFalse(LinuxShellPump.isReleasedFailedStartReceipt(receipt(state), id))
        }
        assertFalse(LinuxShellPump.isReleasedFailedStartReceipt(receipt(released = "false"), id))
    }

    @Test fun foreignAndMalformedRetirementNeverReleasesThisGrant() {
        assertFalse(LinuxShellPump.isReleasedFailedStartReceipt(receipt(request = "other"), id))
        for (bit in listOf("\"true\"", "1", "null")) {
            assertFalse(LinuxShellPump.isReleasedFailedStartReceipt(receipt(released = bit), id))
        }
        assertFalse(LinuxShellPump.isReleasedFailedStartReceipt("""{"state":"failed","requestID":"$id"}""", id))
        assertFalse(LinuxShellPump.isReleasedFailedStartReceipt("invalid", id))
    }
}
