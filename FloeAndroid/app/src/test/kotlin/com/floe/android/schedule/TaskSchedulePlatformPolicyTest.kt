// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure platform-policy tests: exact time is the default, a missing grant
 * waits visibly, and only an explicit flexible choice switches mechanisms.
 * These do not touch Android framework classes, WorkManager or a device.
 */
class TaskSchedulePlatformPolicyTest {

    @Test
    fun exactAlarmIsTheDefaultWhenPermissionIsGranted() {
        val decision = TaskScheduleWakePolicy.decide(
            enabled = true,
            nextFireAtMillis = 5_000_000,
            exactAlarmAllowed = true,
            flexibleChosen = false,
            nowMillis = 1_000_000,
        )
        assertEquals(
            TaskScheduleWakeDecision.Arm(TaskScheduleWakeMode.EXACT, 5_000_000),
            decision,
        )
    }

    @Test
    fun aPastDueFireTimeIsAdjustedToNowButStaysExact() {
        val decision = TaskScheduleWakePolicy.decide(
            enabled = true,
            nextFireAtMillis = 10,
            exactAlarmAllowed = true,
            flexibleChosen = false,
            nowMillis = 900,
        )
        assertEquals(
            TaskScheduleWakeDecision.Arm(TaskScheduleWakeMode.EXACT, 900),
            decision,
        )
    }

    @Test
    fun deniedExactPermissionWithoutChoiceWaitsInsteadOfDowngrading() {
        val decision = TaskScheduleWakePolicy.decide(
            enabled = true,
            nextFireAtMillis = 5_000,
            exactAlarmAllowed = false,
            flexibleChosen = false,
            nowMillis = 1_000,
        )
        assertEquals(TaskScheduleWakeDecision.WaitingPermission, decision)
    }

    @Test
    fun explicitFlexibleChoiceUsesWorkManagerTiming() {
        val decision = TaskScheduleWakePolicy.decide(
            enabled = true,
            nextFireAtMillis = 5_000,
            exactAlarmAllowed = false,
            flexibleChosen = true,
            nowMillis = 1_000,
        )
        assertEquals(
            TaskScheduleWakeDecision.Arm(TaskScheduleWakeMode.FLEXIBLE, 5_000),
            decision,
        )
    }

    @Test
    fun exactPermissionStillWinsWhenTheUserAlsoChoseFlexible() {
        val decision = TaskScheduleWakePolicy.decide(
            enabled = true,
            nextFireAtMillis = 5_000,
            exactAlarmAllowed = true,
            flexibleChosen = true,
            nowMillis = 1_000,
        )
        assertEquals(
            TaskScheduleWakeDecision.Arm(TaskScheduleWakeMode.EXACT, 5_000),
            decision,
        )
    }

    @Test
    fun pausedOrEventOnlySchedulesCancelClockWakes() {
        assertEquals(
            TaskScheduleWakeDecision.Cancel,
            TaskScheduleWakePolicy.decide(
                enabled = false,
                nextFireAtMillis = 5_000,
                exactAlarmAllowed = true,
                flexibleChosen = false,
            ),
        )
        assertEquals(
            TaskScheduleWakeDecision.Cancel,
            TaskScheduleWakePolicy.decide(
                enabled = true,
                nextFireAtMillis = null,
                exactAlarmAllowed = true,
                flexibleChosen = false,
            ),
        )
    }

    // ---------------------------------------------------------- presentation

    private fun summary(
        enabled: Boolean = true,
        cadence: TaskScheduleCadence = TaskScheduleCadence.DAILY,
        attention: Boolean = false,
    ) = TaskScheduleSummary(
        id = "11111111-1111-1111-1111-111111111111",
        title = "Daily report",
        promptPreview = "Summarize",
        cadence = cadence,
        enabled = enabled,
        scheduledAtMillis = 1_000,
        weekday = null,
        intervalSeconds = null,
        anchorTimezone = "Australia/Sydney",
        nextFireAtMillis = 2_000,
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
        needsAttention = attention,
    )

    @Test
    fun pausedIsReportedBeforeAnyTransportState() {
        assertEquals(
            TaskSchedulePresentationStatus.PAUSED,
            TaskSchedulePresentation.status(
                summary(enabled = false, attention = true),
                exactAlarmAllowed = false,
                flexibleChosen = false,
                transportNotice = "notifications_blocked",
            ),
        )
    }

    @Test
    fun missingExactPermissionIsVisibleAndNeverReportedActive() {
        assertEquals(
            TaskSchedulePresentationStatus.WAITING_PERMISSION,
            TaskSchedulePresentation.status(
                summary(), exactAlarmAllowed = false,
                flexibleChosen = false, transportNotice = null,
            ),
        )
    }

    @Test
    fun flexibleChoiceAndTransportProblemsAreDistinct() {
        assertEquals(
            TaskSchedulePresentationStatus.FLEXIBLE,
            TaskSchedulePresentation.status(
                summary(), exactAlarmAllowed = false,
                flexibleChosen = true, transportNotice = null,
            ),
        )
        assertEquals(
            TaskSchedulePresentationStatus.NEEDS_ATTENTION,
            TaskSchedulePresentation.status(
                summary(), exactAlarmAllowed = true,
                flexibleChosen = false, transportNotice = "notifications_blocked",
            ),
        )
    }

    @Test
    fun aDeniedBackgroundForegroundStartIsVisibleAndNeverReportedScheduled() {
        // The dispatcher refused to promote the worker to the existing
        // agent foreground before any claim. The row must show the
        // actionable attention state (the occurrence stays pending).
        assertEquals(
            TaskSchedulePresentationStatus.NEEDS_ATTENTION,
            TaskSchedulePresentation.status(
                summary(), exactAlarmAllowed = true,
                flexibleChosen = false, transportNotice = "foreground_unavailable",
            ),
        )
    }

    @Test
    fun expeditedWorkIsUsedOnlyWhereItDoesNotNeedWorkManagerForegroundService() {
        // API 28-30 expedited jobs are FGS-backed and require
        // getForegroundInfo; API 31+ uses an expedited JobScheduler job.
        assertEquals(false, scheduleDispatchUsesExpedited(28))
        assertEquals(false, scheduleDispatchUsesExpedited(30))
        assertEquals(true, scheduleDispatchUsesExpedited(31))
        assertEquals(true, scheduleDispatchUsesExpedited(37))
    }

    @Test
    fun afterSuccessIsEventDrivenNotClockDriven() {
        assertEquals(
            TaskSchedulePresentationStatus.EVENT_DRIVEN,
            TaskSchedulePresentation.status(
                summary(cadence = TaskScheduleCadence.AFTER_SUCCESS),
                exactAlarmAllowed = true, flexibleChosen = false,
                transportNotice = null,
            ),
        )
    }

    @Test
    fun exactPermissionAndCleanBindingsProduceActive() {
        assertEquals(
            TaskSchedulePresentationStatus.ACTIVE,
            TaskSchedulePresentation.status(
                summary(), exactAlarmAllowed = true,
                flexibleChosen = false, transportNotice = null,
            ),
            )
    }
}
