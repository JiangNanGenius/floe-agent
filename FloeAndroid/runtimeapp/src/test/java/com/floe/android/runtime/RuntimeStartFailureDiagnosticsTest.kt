// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.workspacebridge.WorkspaceBridgeException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RuntimeStartFailureDiagnosticsTest {
    @Test fun knownOwnershipAndTransferFailuresHaveActionableCodes() {
        assertEquals("workspace_owner_unavailable",
            RuntimeKernel.startFailureCode(IllegalArgumentException("workspaceOwnerUnavailable")))
        assertEquals("journalCollision", RuntimeKernel.startFailureCode(WorkspaceBridgeException("journalCollision")))
        assertEquals("inputBaselineAdoptionFailed",
            RuntimeKernel.startFailureCode(WorkspaceBridgeException("inputBaselineAdoptionFailed")))
        assertEquals("workspace_input_owner_unavailable",
            RuntimeKernel.startFailureCode(IllegalStateException("inputOwnerUnavailable")))
    }

    @Test fun arbitraryExceptionAndBridgeContentNeverEnterDiagnostics() {
        assertNull(RuntimeKernel.startFailureCode(IllegalStateException("/private/user-document")))
        assertEquals("workspace_transfer_failed",
            RuntimeKernel.startFailureCode(WorkspaceBridgeException("/private/user-document")))
    }
}
