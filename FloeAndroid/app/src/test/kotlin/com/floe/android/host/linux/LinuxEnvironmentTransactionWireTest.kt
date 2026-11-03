// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LinuxEnvironmentTransactionWireTest {
    private fun valid(outcome: String = "rolledBack") = JSONObject()
        .put("id", UUID.randomUUID().toString()).put("outcome", outcome).put("snapshotBytes", 1024L)
    @Test fun realReceiptKeepsItsExactIdentityAndClosedOutcome() {
        for (outcome in listOf("committed", "rolledBack")) {
            val value = valid(outcome)
            val receipt = sanitizeEnvironmentTransactionReceipt(value)!!
            assertEquals(value.getString("id"), receipt.getString("id"))
            assertEquals(outcome, receipt.getString("outcome"))
            assertEquals(1024L, receipt.getLong("snapshotBytes"))
        }
    }
    @Test fun arbitraryPathsUnknownOutcomesAndAdditionalDataAreNotProof() {
        assertNull(sanitizeEnvironmentTransactionReceipt(valid().put("id", "/files/snapshot")))
        assertNull(sanitizeEnvironmentTransactionReceipt(valid().put("outcome", "success")))
        assertNull(sanitizeEnvironmentTransactionReceipt(valid().put("path", "/arbitrary")))
    }
    @Test fun booleansStringsFractionsAndUnboundedCountsAreRejected() {
        for (bad in listOf<Any>(true, "1024", 1.25, -1L, 4L * 1024 * 1024 * 1024 + 1)) {
            assertNull(sanitizeEnvironmentTransactionReceipt(valid().put("snapshotBytes", bad)))
        }
    }
    @Test fun absentReceiptRemainsUnknownRatherThanInventingAnEmptyRollback() {
        assertNull(sanitizeEnvironmentTransactionReceipt(null))
        assertNull(sanitizeEnvironmentTransactionReceipt(JSONObject()))
    }
}
