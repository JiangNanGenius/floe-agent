// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Pure contract tests: stable operation id validation, the honest
 * notification gate classification matrix (blocked notifications are
 * never silently treated as ready) and deterministic copy selection
 * (empty set yields NO key — foreground is never manufactured from
 * nothing).
 */
class RunForegroundContractsTest {

    @Test
    fun operationIdMustBeACanonicalStableUuid() {
        val value = UUID.randomUUID()
        assertEquals(value.toString(), OperationIds.normalize(value.toString()))
        assertEquals(value.toString(), OperationIds.normalize(value.toString().uppercase()))
        assertEquals(value.toString(), OperationIds.normalize("  ${value.toString()}  "))
        for (bad in listOf("", "task-1", "run", UUID.randomUUID().toString().replace("-", ""),
            "{${UUID.randomUUID()}}", UUID.randomUUID().toString().dropLast(1))) {
            assertThrows(IllegalArgumentException::class.java) { OperationIds.normalize(bad) }
        }
    }

    @Test
    fun notificationGateClassificationIsHonest() {
        // API 33+ without POST_NOTIFICATIONS: blocked, regardless of all else.
        assertEquals(NotificationGate.Block.POST_NOTIFICATIONS_REQUIRED,
            NotificationGate.classify(33, postNotificationsGranted = false,
                notificationsEnabled = true, channelExists = true, channelBlocked = false))
        // Below 33 the permission does not gate; disabled notifications do.
        assertEquals(NotificationGate.Block.NONE,
            NotificationGate.classify(30, postNotificationsGranted = false,
                notificationsEnabled = true, channelExists = false, channelBlocked = false))
        assertEquals(NotificationGate.Block.NOTIFICATIONS_DISABLED,
            NotificationGate.classify(28, postNotificationsGranted = true,
                notificationsEnabled = false, channelExists = true, channelBlocked = false))
        assertEquals(NotificationGate.Block.CHANNEL_BLOCKED,
            NotificationGate.classify(34, postNotificationsGranted = true,
                notificationsEnabled = true, channelExists = true, channelBlocked = true))
        assertEquals(NotificationGate.Block.NONE,
            NotificationGate.classify(34, postNotificationsGranted = true,
                notificationsEnabled = true, channelExists = true, channelBlocked = false))
    }

    @Test
    fun copySelectionIsDeterministicAndEmptyMeansNoNotification() {
        assertNull(NotificationCopy.keyFor(emptySet()))
        assertEquals(NotificationCopy.Key.AGENT_RUN,
            NotificationCopy.keyFor(setOf(OperationKind.AGENT_RUN)))
        assertEquals(NotificationCopy.Key.ENVIRONMENT_INSTALL,
            NotificationCopy.keyFor(setOf(OperationKind.ENVIRONMENT_INSTALL)))
        assertEquals(NotificationCopy.Key.LOCAL_EXECUTION,
            NotificationCopy.keyFor(setOf(OperationKind.LOCAL_EXECUTION)))
        assertEquals(NotificationCopy.Key.DURABLE_JOB,
            NotificationCopy.keyFor(setOf(OperationKind.DURABLE_JOB)))
        assertEquals(NotificationCopy.Key.MULTIPLE,
            NotificationCopy.keyFor(setOf(OperationKind.AGENT_RUN, OperationKind.LOCAL_EXECUTION)))
    }

    @Test
    fun typedFailuresCarryTheirReasonAndSubtype() {
        val blocked = RunForegroundFailure.NotificationsBlocked("channel-blocked")
        assertEquals("foreground_notifications_blocked:channel-blocked", blocked.message)
        val denied = RunForegroundFailure.StartDenied("system-refused-foreground-start")
        assertEquals("foreground_start_denied:system-refused-foreground-start", denied.message)
        val conflict = RunForegroundFailure.OwnerConflict(
            UUID.randomUUID().toString(), OperationKind.AGENT_RUN, OperationKind.DURABLE_JOB)
        assertEquals(OperationKind.AGENT_RUN, conflict.existingKind)
        assertEquals(OperationKind.DURABLE_JOB, conflict.requestedKind)
    }
}
