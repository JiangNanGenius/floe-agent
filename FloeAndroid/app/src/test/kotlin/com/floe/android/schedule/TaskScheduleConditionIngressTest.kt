// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostCommandValidator
import com.floe.android.host.HostRevision
import com.floe.android.host.HostScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Exercises the actual host ingress that rejected the Samsung condition event. */
class TaskScheduleConditionIngressTest {
    private fun request() = HostCommandRequest(
        command = "schedule.systemEvent",
        scope = HostScope.ApplicationConfiguration("schedule"),
        stateful = true,
        correlationID = "condition-regression",
        revision = HostRevision("schedule.11111111-1111-4111-8111-111111111111", "revision"),
    )

    @Test fun conditionEventReachesTheRegisteredScheduleHandler() {
        assertNull(HostCommandValidator.validate(request()))
    }

    @Test fun conditionEventStillRequiresTheScheduleRevision() {
        assertEquals("revisionRequired", HostCommandValidator.validate(request().copy(revision = null)))
        assertEquals("statefulMismatch", HostCommandValidator.validate(request().copy(stateful = false)))
        assertEquals("createIntentNotAllowed", HostCommandValidator.validate(request().copy(createIntent = true)))
    }

    @Test fun conditionEventCannotUseAnotherConfigurationOrTaskRole() {
        assertEquals("unknownCommandInScope", HostCommandValidator.validate(
            request().copy(scope = HostScope.ApplicationConfiguration("projects"))))
        assertEquals("unknownCommandInScope", HostCommandValidator.validate(
            request().copy(scope = HostScope.ConversationLifecycle("11111111-1111-4111-8111-111111111111"))))
    }
}
