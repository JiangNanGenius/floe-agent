// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RuntimeAuthorityRefusalTest {
    @Test fun metadataRetainsTheActualAuthorityFailureCode() {
        assertEquals("authority_replyTooLarge", RuntimeAuthorityRefusal.metadataCode(
            "environment.list", RuntimeAuthorityRefusal("replyTooLarge")))
    }

    @Test fun unrelatedOperationsAndExceptionsDoNotGainMetadataDiagnostics() {
        assertNull(RuntimeAuthorityRefusal.metadataCode("environment.start", RuntimeAuthorityRefusal("ownerMismatch")))
        assertNull(RuntimeAuthorityRefusal.metadataCode("environment.list", IllegalStateException("private details")))
    }

    @Test fun malformedCodesCannotCarryPathsOrUnboundedMessages() {
        for (code in listOf("", "/data/private", "has space", "x".repeat(49), "路径", "replyTooLarge\n")) {
            val failure = RuntimeAuthorityRefusal(code)
            assertEquals("refused", failure.code)
            assertEquals("Environment authority refused the request.", failure.message)
        }
    }
}
