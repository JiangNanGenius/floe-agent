// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlBackend
import com.floe.android.phonecontrol.PhoneControlDispatch
import com.floe.android.phonecontrol.PhoneControlStructuredRouting
import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AdbUiBackendContractTest {

    @Test fun aUiSessionCannotCarryAnotherPrivilegeFamily() {
        val ui = setOf(
            SystemOperation.UI_OBSERVE,
            SystemOperation.UI_ACT,
            SystemOperation.UI_SCREENSHOT,
            SystemOperation.UI_CANCEL,
        )
        assertEquals(ui, SystemOperation.UI_OPERATIONS)
        assertTrue(ui.none { SystemOperation.isPackageManagement(it) })
        assertTrue(ui.none { it == SystemOperation.FILE_READ || it == SystemOperation.FILE_WRITE })
    }

    @Test fun adbObservationIdsCarryTheOpaquePrefixAndNoAsReuse() {
        assertEquals(
            PhoneControlBackend.ADB_UI_AUTOMATION,
            PhoneControlBackend.fromObservationId("adbui-8a81"),
        )
        assertEquals(
            PhoneControlBackend.ACCESSIBILITY,
            PhoneControlBackend.fromObservationId("3f50a0b0-observation"),
        )
        assertEquals(null, PhoneControlBackend.fromObservationId(""))
    }

    @Test fun acceptedAndUnknownDispatchBlockReplayUntilObserved() {
        assertTrue(PhoneControlStructuredRouting.requiresReadback(PhoneControlDispatch.ACCEPTED))
        assertTrue(PhoneControlStructuredRouting.requiresReadback(PhoneControlDispatch.UNKNOWN))
        assertFalse(PhoneControlStructuredRouting.requiresReadback(PhoneControlDispatch.NOT_DISPATCHED))
    }
}
