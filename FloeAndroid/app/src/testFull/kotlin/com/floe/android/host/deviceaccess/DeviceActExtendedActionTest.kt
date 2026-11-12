// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlAction
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The generic focus/commit actions added to device.act keep the existing
 * observationId contract and ref grammar. This wrapper must not weaken or
 * duplicate the original parser: every original action still delegates, and
 * malformed shapes still classify as invalid arguments before any observation
 * decision.
 */
class DeviceActExtendedActionTest {

    private fun request(raw: String): PhoneActionArguments.Request =
        DeviceActArguments.request(JSONObject(raw))

    @Test
    fun focusAndCommitDispatchWithTheExactObservation() {
        val focus = request(
            """{"action":"focus","nodeRef":"n6","observationId":"observation-id-1"}""",
        ) as PhoneActionArguments.Request.Dispatch
        assertEquals("observation-id-1", focus.observationId)
        assertEquals(PhoneControlAction.Focus("n6"), focus.action)

        val commit = request(
            """{"action":"commit","nodeRef":"n6","observationId":"observation-id-2"}""",
        ) as PhoneActionArguments.Request.Dispatch
        assertEquals("observation-id-2", commit.observationId)
        assertEquals(PhoneControlAction.Commit("n6"), commit.action)
    }

    @Test
    fun focusAndCommitRequireAFreshObservationLikeEveryNonLaunchAction() {
        assertTrue(
            request("""{"action":"focus","nodeRef":"n6"}""") is
                PhoneActionArguments.Request.MissingObservation,
        )
        assertTrue(
            request("""{"action":"commit","nodeRef":"n6"}""") is
                PhoneActionArguments.Request.MissingObservation,
        )
        assertEquals(
            PhoneActionArguments.OBSERVATION_REQUIRED_CODE,
            "device_observation_required",
        )
        // Historical persisted receipts keep their exact closed spelling.
        assertEquals(
            PhoneActionArguments.LEGACY_OBSERVATION_REQUIRED_CODE,
            "phone_observation_required",
        )
    }

    @Test
    fun malformedFocusOrCommitRefIsInvalidArguments() {
        listOf(
            """{"action":"focus"}""",
            """{"action":"commit","nodeRef":""}""",
            """{"action":"focus","nodeRef":"n 6","observationId":"o1"}""",
            """{"action":"commit","nodeRef":"${"n".repeat(17)}","observationId":"o1"}""",
            """{"action":"focus","nodeRef":6,"observationId":"o1"}""",
        ).forEach { raw ->
            assertTrue(raw, request(raw) is PhoneActionArguments.Request.InvalidArguments)
        }
    }

    @Test
    fun originalActionsStillUseTheOriginalParser() {
        val click = request(
            """{"action":"click","nodeRef":"n6","observationId":"o1"}""",
        ) as PhoneActionArguments.Request.Dispatch
        assertEquals(PhoneControlAction.Click("n6"), click.action)

        val sensitive = request(
            """{"action":"setText","nodeRef":"n6","sensitiveText":"canary","observationId":"o1"}""",
        ) as PhoneActionArguments.Request.Dispatch
        assertTrue((sensitive.action as PhoneControlAction.SetText).sensitive)

        // Both text keys remain mutually exclusive through the delegated parser.
        assertTrue(
            request(
                """{"action":"setText","nodeRef":"n6","text":"a","sensitiveText":"b","observationId":"o1"}""",
            ) is PhoneActionArguments.Request.InvalidArguments,
        )
    }
}
