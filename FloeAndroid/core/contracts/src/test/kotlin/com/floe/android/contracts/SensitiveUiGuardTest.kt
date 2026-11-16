// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch

class SensitiveUiGuardTest {
    private val ticket = SensitiveUiGuardTicket(
        taskId = "task", runId = "run", epoch = 1, grantId = "grant",
        observationId = "observation", nodeRef = "n1", packageName = "org.example",
        windowId = 1, displayId = 0, path = listOf(0, 2),
        className = "android.widget.EditText", viewId = null,
    )

    @Test fun reconnectRequiresAnExplicitSnapshot() {
        assertFalse(SensitiveUiGuardPolicy.canReadSensitiveFields(false, emptyList()))
        assertFalse(SensitiveUiGuardPolicy.canCapture(false, emptyList()))
        assertTrue(SensitiveUiGuardPolicy.canReadSensitiveFields(true, emptyList()))
        assertTrue(SensitiveUiGuardPolicy.canCapture(true, emptyList()))
        assertFalse(SensitiveUiGuardPolicy.validSession("new-service", "old-service"))
        assertFalse(SensitiveUiGuardPolicy.validSession("new-service", null))
        assertTrue(SensitiveUiGuardPolicy.validSession("new-service", "new-service"))
    }

    @Test fun activeTicketDisablesCaptureAndSensitiveReads() {
        assertTrue(SensitiveUiGuardPolicy.valid(listOf(ticket)))
        assertFalse(SensitiveUiGuardPolicy.canReadSensitiveFields(true, listOf(ticket)))
        assertFalse(SensitiveUiGuardPolicy.canCapture(true, listOf(ticket)))
    }

    @Test fun malformedAndUnboundedSnapshotsAreRejected() {
        assertFalse(SensitiveUiGuardPolicy.valid(listOf(ticket.copy(epoch = 0))))
        assertFalse(SensitiveUiGuardPolicy.valid(listOf(ticket.copy(path = listOf(-1)))))
        assertFalse(SensitiveUiGuardPolicy.valid(listOf(ticket, ticket)))
        assertFalse(SensitiveUiGuardPolicy.valid(
            (0..SensitiveUiGuardPolicy.MAX_TICKETS).map { ticket.copy(nodeRef = "n$it") },
        ))
    }

    @Test fun protectedObservationReadsOnlyPreexistingNonEditableButtons() {
        fun canRead(editable: Boolean, clickable: Boolean, setText: Boolean, known: Boolean) =
            SensitiveUiGuardPolicy.canReadNodeText(true, false, editable, clickable, setText, known)
        assertFalse(canRead(true, true, false, true))
        assertFalse(canRead(false, true, true, true))
        assertFalse(canRead(false, true, false, false))
        assertFalse(canRead(false, false, false, true))
        assertTrue(canRead(false, true, false, true))
        assertFalse(SensitiveUiGuardPolicy.canReadNodeText(true, true, false, true, false, true))
        assertTrue(SensitiveUiGuardPolicy.canReadNodeText(true, false, false, false, false, true,
            safeButtonChild = true))
        assertFalse(SensitiveUiGuardPolicy.canReadNodeText(true, false, true, false, false, true,
            safeButtonChild = true))
        assertFalse(SensitiveUiGuardPolicy.canReadNodeText(true, true, false, false, false, true,
            safeButtonChild = true))
        assertFalse(SensitiveUiGuardPolicy.canReadNodeText(true, false, false, false, true, true,
            safeButtonChild = true))
        assertFalse(SensitiveUiGuardPolicy.canReadNodeText(true, false, false, false, false, false,
            safeButtonChild = true))
    }

    @Test fun reorderedEmptySnapshotCannotClearNewerProtectedState() {
        val empty = SensitiveUiGuardSnapshot("install-epoch", 1, emptyList())
        val active = SensitiveUiGuardSnapshot("install-epoch", 2, listOf(ticket))
        assertNull(SensitiveUiGuardPolicy.syncDenial(null, empty))
        assertNull(SensitiveUiGuardPolicy.syncDenial(empty, active))
        assertEquals("ui_guard_stale", SensitiveUiGuardPolicy.syncDenial(active, empty))
        assertEquals("ui_guard_conflict", SensitiveUiGuardPolicy.syncDenial(
            active, active.copy(tickets = emptyList()),
        ))
        assertEquals("ui_guard_epoch", SensitiveUiGuardPolicy.syncDenial(
            active, active.copy(epoch = "other-install", revision = 3),
        ))
        assertNull(SensitiveUiGuardPolicy.syncDenial(active, active))
        assertNull(SensitiveUiGuardPolicy.syncDenial(active, active.copy(revision = 3, tickets = emptyList())))
    }

    @Test fun concurrentOlderClearAndNewerProtectionConvergeOnNewerRevision() {
        repeat(40) {
            val gate = Any()
            var current: SensitiveUiGuardSnapshot? = null
            val start = CountDownLatch(1)
            val snapshots = listOf(
                SensitiveUiGuardSnapshot("install-epoch", 1, emptyList()),
                SensitiveUiGuardSnapshot("install-epoch", 2, listOf(ticket)),
            )
            val threads = snapshots.map { snapshot ->
                Thread {
                    start.await()
                    synchronized(gate) {
                        if (SensitiveUiGuardPolicy.syncDenial(current, snapshot) == null) {
                            current = snapshot
                        }
                    }
                }.apply { start() }
            }
            start.countDown()
            threads.forEach { it.join() }
            assertEquals(snapshots[1], current)
        }
    }

    @Test fun localHmacUsesCompleteDistinctFieldsAndRejectsInvalidText() {
        val first = SensitiveUiLabelKey.fromBytes(ByteArray(32) { 1 })!!
        val other = SensitiveUiLabelKey.fromBytes(ByteArray(32) { 2 })!!
        val digest = SensitiveUiLabelFingerprint.hmac(first, "Sign in", null)!!
        assertEquals(64, digest.length)
        assertEquals("28bc6ccd59687efd43c6e3ee97e2b9d2d1bfd048b549d923e7c2a25163ad7735", digest)
        assertEquals(digest, SensitiveUiLabelFingerprint.hmac(first, "Sign in", null))
        assertFalse(digest == SensitiveUiLabelFingerprint.hmac(first, "Sign in", ""))
        assertFalse(digest == SensitiveUiLabelFingerprint.hmac(other, "Sign in", null))
        assertNull(SensitiveUiLabelFingerprint.hmac(first, "x".repeat(2001), null))
        assertNull(SensitiveUiLabelFingerprint.hmac(first, "\uD800", null))
        assertFalse(first.toString().contains("1, 1"))
    }

    @Test fun guardedSnapshotCannotAcquireNewBaselinesOrRotateKeys() {
        val first = SensitiveUiLabelKey.fromBytes(ByteArray(32) { 1 })!!
        val other = SensitiveUiLabelKey.fromBytes(ByteArray(32) { 2 })!!
        val identity = SensitiveUiLabelIdentity("org.example", 1, 0, listOf(0), "Button", null)
        val entry = SensitiveUiLabelBaseline(identity, null,
            SensitiveUiLabelFingerprint.hmac(first, "OK", null)!!)
        val current = SensitiveUiGuardSnapshot("epoch", 1, listOf(ticket), first)
        assertEquals("ui_guard_baseline_changed", SensitiveUiGuardPolicy.syncDenial(current,
            current.copy(revision = 2, labelBaselines = listOf(entry))))
        assertEquals("ui_guard_baseline_changed", SensitiveUiGuardPolicy.syncDenial(current,
            current.copy(revision = 2, labelKey = other)))
    }
}
