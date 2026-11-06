package com.floe.android.host.update

import org.junit.Assert.*
import org.junit.Test

class UpdateInstallCallbackPolicyTest {
    private val signer = setOf("a".repeat(64))
    private val record = PendingInstall("0.1.0-alpha.30", 49, "b".repeat(64), "app.apk", 101,
        "com.floe.agent.full", signer,
        RuntimeInstallProof("com.floe.agent.runtime.full", 49, signer, "c".repeat(64)), listOf(102, 103))

    @Test fun childPermissionCallbacksBelongToTheRecordedParentTransaction() {
        assertEquals(101, UpdateInstallCallbackPolicy.owner(record, 101, 102, true))
        assertEquals(101, UpdateInstallCallbackPolicy.owner(record, 101, 103, true))
        assertEquals(101, UpdateInstallCallbackPolicy.owner(record, 101, 101, true))
    }

    @Test fun childTerminalSuccessCannotSettleTheWholeTransaction() {
        assertNull(UpdateInstallCallbackPolicy.owner(record, 101, 102, false))
        assertNull(UpdateInstallCallbackPolicy.owner(record, 101, 103, false))
        assertEquals(101, UpdateInstallCallbackPolicy.owner(record, 101, 101, false))
    }

    @Test fun staleUnownedAndMissingCallbacksCannotOpenAConfirmation() {
        assertNull(UpdateInstallCallbackPolicy.owner(record, 100, 102, true))
        assertNull(UpdateInstallCallbackPolicy.owner(record, 101, 999, true))
        assertNull(UpdateInstallCallbackPolicy.owner(record, 101, -1, true))
        assertNull(UpdateInstallCallbackPolicy.owner(null, 101, 102, true))
    }

    @Test fun legacySinglePackageCallbacksKeepTheirExactSessionBinding() {
        val legacy = record.copy(runtime = null, childSessionIDs = emptyList())
        assertEquals(101, UpdateInstallCallbackPolicy.owner(legacy, 101, 101, true))
        assertEquals(101, UpdateInstallCallbackPolicy.owner(legacy, 101, 101, false))
        assertNull(UpdateInstallCallbackPolicy.owner(legacy, 101, 102, true))
    }
}
