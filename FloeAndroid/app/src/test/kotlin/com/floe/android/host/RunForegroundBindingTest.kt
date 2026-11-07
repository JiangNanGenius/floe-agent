// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.runlifecycle.OperationKind
import com.floe.android.runlifecycle.RunForegroundFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Typed start-restriction handling: the provisional acquisition keeps its
 * typed refusal for scheduler notice routing, the legacy Boolean view stays
 * compatible, and the host notice bucket distinguishes a REAL OS background
 * start restriction from generic unavailability, owner conflicts and
 * notification blocks. Pure JVM: no Android framework, no controller.
 */
class RunForegroundBindingTest {

    @Test
    fun admittedResultMapsToTheLegacyBooleanTrue() {
        assertTrue(AgentLaunchProvisionalResult.Admitted.admitted())
    }

    @Test
    fun anyRefusalMapsToTheLegacyBooleanFalse() {
        assertFalse(
            AgentLaunchProvisionalResult.Refused(
                RunForegroundFailure.StartDenied("system-refused"),
            ).admitted(),
        )
        assertFalse(
            AgentLaunchProvisionalResult.Refused(
                RunForegroundFailure.NotificationsBlocked("channel-blocked"),
            ).admitted(),
        )
    }

    @Test
    fun theTypedRefusalPreservesTheExactFailureInstance() {
        // The scheduler routes its actionable notice from THIS instance; a
        // global last-trace readback would race and is never used instead.
        val failure = RunForegroundFailure.StartDenied("system-refused-foreground-start")
        val refused = AgentLaunchProvisionalResult.Refused(failure)
        assertSame(failure, refused.failure)
        assertEquals("foreground_start_denied:system-refused-foreground-start",
            refused.failure.message)
    }

    @Test
    fun aRealStartDeniedIsItsOwnNoticeBucket() {
        assertEquals(
            RuntimeHost.BackgroundAvailability.BACKGROUND_START_RESTRICTED,
            backgroundAvailabilityOf(RunForegroundFailure.StartDenied("start-foreground-refused")),
        )
    }

    @Test
    fun notificationBlocksStayTheirOwnDistinctBucket() {
        assertEquals(
            RuntimeHost.BackgroundAvailability.NOTIFICATIONS_BLOCKED,
            backgroundAvailabilityOf(
                RunForegroundFailure.NotificationsBlocked("app-notifications-disabled")),
        )
    }

    @Test
    fun genericUnavailabilityAndOwnerConflictsStaySystemUnavailable() {
        assertEquals(
            RuntimeHost.BackgroundAvailability.SYSTEM_UNAVAILABLE,
            backgroundAvailabilityOf(RunForegroundFailure.Unavailable("start-delivery-failed")),
        )
        assertEquals(
            RuntimeHost.BackgroundAvailability.SYSTEM_UNAVAILABLE,
            backgroundAvailabilityOf(
                RunForegroundFailure.OwnerConflict(
                    "9b1e2c6d-1111-2222-3333-444455556666",
                    OperationKind.LOCAL_EXECUTION,
                    OperationKind.AGENT_RUN,
                )),
        )
    }
}
