// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import com.floe.android.runlifecycle.OperationKind
import com.floe.android.runlifecycle.RunForegroundFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Return-recovery and start-restriction policy: a typed REAL OS background
 * start restriction routes to its own actionable notice (never the generic
 * one, and an unknown refusal is never upgraded to a restriction claim);
 * the foreground-resume work key is distinct, stable and deduped so a prompt
 * attempt never cancels or replaces the ordinary backing-off admission; and
 * the visible row state for that notice is actionable attention, never a
 * scheduled/active claim.
 */
class TaskScheduleReturnRecoveryTest {

    @Test
    fun aTypedStartDeniedRoutesToItsOwnActionableNotice() {
        assertEquals(
            NOTICE_BACKGROUND_START_RESTRICTED,
            foregroundStartNotice(
                RunForegroundFailure.StartDenied("system-refused-foreground-start")),
        )
        assertEquals("background_start_restricted",
            foregroundStartNotice(RunForegroundFailure.StartDenied("start-foreground-refused")))
    }

    @Test
    fun otherRefusalsAndUnknownFailuresKeepTheGenericNotice() {
        assertEquals(
            NOTICE_FOREGROUND_UNAVAILABLE,
            foregroundStartNotice(
                RunForegroundFailure.NotificationsBlocked("channel-blocked")),
        )
        assertEquals(
            NOTICE_FOREGROUND_UNAVAILABLE,
            foregroundStartNotice(RunForegroundFailure.Unavailable("start-delivery-failed")),
        )
        assertEquals(
            NOTICE_FOREGROUND_UNAVAILABLE,
            foregroundStartNotice(
                RunForegroundFailure.OwnerConflict(
                    "9b1e2c6d-1111-2222-3333-444455556666",
                    OperationKind.LOCAL_EXECUTION,
                    OperationKind.AGENT_RUN,
                )),
        )
        assertEquals(NOTICE_FOREGROUND_UNAVAILABLE, foregroundStartNotice(null))
    }

    @Test
    fun theReturnRecoveryKeyIsStableDistinctAndNeverTheOrdinaryDispatchKey() {
        val id = "11111111-1111-1111-1111-111111111111"
        // Stable per id: repeat resumes dedupe through KEEP on one name.
        assertEquals(returnRecoveryWorkName(id), returnRecoveryWorkName(id))
        // Distinct per id.
        assertNotEquals(
            returnRecoveryWorkName(id),
            returnRecoveryWorkName("22222222-2222-2222-2222-222222222222"),
        )
        // Distinct from the ordinary dispatch key: a prompt recovery attempt
        // never cancels or replaces the backing-off in-flight admission.
        assertNotEquals(
            "floe.schedule.dispatch.$id.${TaskScheduleDispatchWorker.TRIGGER_PENDING}",
            returnRecoveryWorkName(id),
        )
        assertTrue(
            returnRecoveryWorkName(id)
                .endsWith(".${TaskScheduleDispatchWorker.TRIGGER_PENDING}.return"),
        )
    }

    @Test
    fun theRestrictedNoticeIsVisibleActionableAttentionNeverScheduled() {
        val summary = TaskScheduleSummary(
            id = "11111111-1111-1111-1111-111111111111",
            title = "Network report",
            promptPreview = "Summarize",
            cadence = TaskScheduleCadence.NETWORK_CONNECTED,
            enabled = true,
            scheduledAtMillis = 1_000,
            weekday = null,
            intervalSeconds = null,
            anchorTimezone = "Australia/Sydney",
            nextFireAtMillis = null,
            lastStartedAtMillis = null,
            modelID = null,
            modelName = null,
            environmentID = null,
            environmentName = null,
            workspaceID = null,
            workspaceName = null,
            policy = TaskSchedulePolicyBinding(),
            upstreamRunID = null,
            revision = "rev",
            lastOccurrence = null,
            needsAttention = false,
        )
        assertEquals(
            TaskSchedulePresentationStatus.NEEDS_ATTENTION,
            TaskSchedulePresentation.status(
                summary,
                exactAlarmAllowed = true,
                flexibleChosen = false,
                transportNotice = NOTICE_BACKGROUND_START_RESTRICTED,
            ),
        )
    }
}
