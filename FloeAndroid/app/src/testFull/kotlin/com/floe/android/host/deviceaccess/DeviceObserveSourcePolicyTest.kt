// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The closed parser behind the optional `device.observe.source` field. It is
 * an existing-backend selector, not a grant: auto keeps the useful AS
 * preference, adb requests the already-authorized ADB tier for a NEW
 * observation, and a retained observation id can never switch sources.
 */
class DeviceObserveSourcePolicyTest {

    @Test fun absentOrAutoKeepsTheDefaultPreference() {
        assertEquals(
            DeviceObserveSourcePolicy.Decision.New(DeviceObserveSource.AUTO),
            DeviceObserveSourcePolicy.decide(null, hasObservationId = false),
        )
        assertEquals(
            DeviceObserveSourcePolicy.Decision.New(DeviceObserveSource.AUTO),
            DeviceObserveSourcePolicy.decide("auto", hasObservationId = false),
        )
    }

    @Test fun adbIsAnExplicitNewObservationSource() {
        assertEquals(
            DeviceObserveSourcePolicy.Decision.New(DeviceObserveSource.ADB),
            DeviceObserveSourcePolicy.decide("adb", hasObservationId = false),
        )
    }

    @Test fun paginationStaysPinnedAndCannotSwitchSource() {
        assertEquals(
            DeviceObserveSourcePolicy.Decision.Paging,
            DeviceObserveSourcePolicy.decide("auto", hasObservationId = true),
        )
        assertEquals(
            DeviceObserveSourcePolicy.Decision.Paging,
            DeviceObserveSourcePolicy.decide(null, hasObservationId = true),
        )
        assertEquals(
            DeviceObserveSourcePolicy.Decision.Invalid,
            DeviceObserveSourcePolicy.decide("adb", hasObservationId = true),
        )
    }

    @Test fun unknownAndNonStringValuesAreRejected() {
        for (raw in listOf("accessibility", "phone", "raw", "ADB", "", 7, true, JSONObject.NULL)) {
            assertTrue(
                raw.toString(),
                DeviceObserveSourcePolicy.decide(raw, hasObservationId = false) is
                    DeviceObserveSourcePolicy.Decision.Invalid,
            )
        }
    }
}
