// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v4 is a real append-only revision: released 108 already carried VERSION=3,
 * so the typed UI transactions must never slide an existing position.
 */
class BinderProtocolUiWireTest {

    @Test fun releasedWireThreeIsAnOlderKnownWire() {
        assertEquals(4, BinderProtocol.VERSION)
        assertTrue(
            com.floe.android.rootsystem.policy.BackendOwnershipPolicy.isKnownLegacyWire(
                3, BinderProtocol.VERSION,
            ),
        )
    }

    @Test fun firstNineteenLegacyTransactionsKeepExactOrder() {
        assertEquals(19, BinderProtocol.wire2LegacyMethods.size)
        assertEquals("cancel", BinderProtocol.wire2LegacyMethods[17])
        assertEquals("stopOwnedService", BinderProtocol.wire2LegacyMethods[18])
    }

    @Test fun uiTransactionsAppendAfterTheReleasedV3Block() {
        assertEquals(
            listOf("uiStatus", "uiObserve", "uiAct", "uiScreenshot", "uiCancel"),
            BinderProtocol.wire7AppendedMethods,
        )
        assertEquals(
            BinderProtocol.wire3AppendedMethods +
                BinderProtocol.wire4AppendedMethods +
                BinderProtocol.wire5AppendedMethods +
                BinderProtocol.wire6AppendedMethods +
                BinderProtocol.wire7AppendedMethods,
            BinderProtocol.appendedMethods,
        )
        assertEquals("writeSettings", BinderProtocol.appendedMethods.dropLast(5).last())
        val all = BinderProtocol.wire2LegacyMethods + BinderProtocol.appendedMethods
        assertEquals(all.size, all.toSet().size)
    }

    @Test fun uiOperationsAreClosedAndNotManagementGated() {
        assertEquals(
            setOf(
                SystemOperation.UI_OBSERVE,
                SystemOperation.UI_ACT,
                SystemOperation.UI_SCREENSHOT,
                SystemOperation.UI_CANCEL,
            ),
            SystemOperation.UI_OPERATIONS,
        )
        assertTrue(SystemOperation.UI_OPERATIONS.none { SystemOperation.isPackageManagement(it) })
    }
}
