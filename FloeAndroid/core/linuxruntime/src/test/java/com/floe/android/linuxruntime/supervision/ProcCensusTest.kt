// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Own-UID census: classification and the rule that an unreadable, ambiguous or
 * failed inventory is never an empty (clean) result.
 */
class ProcCensusTest {

    private fun census(
        reader: ProcReader,
        signals: SignalBoundary,
        boundary: RuntimeUidBoundary = acceptedBoundary(),
    ) = ProcCensus(boundary, reader, signals)

    @Test
    fun ownLiveForeignAndZombieAreSeparated() {
        val reader = FakeProcReader()
        reader.put(FakeProcEntry(5001, uid = RUNTIME_UID))
        reader.put(FakeProcEntry(5002, uid = RUNTIME_UID, state = 'Z', ppid = SERVICE_PID))
        reader.put(FakeProcEntry(5003, uid = CORE_UID))
        reader.put(FakeProcEntry(5004, uid = 10999))
        val snapshot = census(reader, FakeSignals(reader)).snapshot()

        assertEquals(listOf(5001), snapshot.ownLive.map { it.pid })
        assertEquals(listOf(5002), snapshot.ownZombies.map { it.pid })
        assertTrue(snapshot.ambiguous.isEmpty())
        assertEquals(2, snapshot.foreignCount)
        assertFalse(snapshot.isCleanlyQuiescent)
        // Only the supervisor can reap its own children; that is recorded, not ignored.
        assertEquals(listOf(5002), snapshot.unreapedOwnChildren.map { it.pid })
    }

    @Test
    fun selfProcessAndItsThreadsAreNeverOwnWork() {
        val reader = FakeProcReader()
        reader.put(FakeProcEntry(SERVICE_PID, uid = RUNTIME_UID)) // the supervisor itself
        reader.put(FakeProcEntry(6001, uid = RUNTIME_UID, tgid = SERVICE_PID)) // one of its threads
        val signals = FakeSignals(reader)
        val snapshot = census(reader, signals).snapshot()

        assertTrue(snapshot.ownLive.isEmpty())
        assertEquals(listOf(6001), snapshot.serviceThreads)
        assertTrue(snapshot.isCleanlyQuiescent)
        assertTrue(signals.kills.isEmpty())
    }

    @Test
    fun birthTimeIsParsedAfterCommaFieldsWithParentheses() {
        val reader = FakeProcReader()
        // A comm that really can contain spaces and parentheses on Linux.
        reader.put(FakeProcEntry(7001, uid = RUNTIME_UID, name = "weird (name) here", startTicks = 424242))
        val entry = reader.entries.getValue(7001)

        val parsed = requireNotNull(ProcParsing.parseStat(entry.stat()))
        assertEquals(424242L, parsed.startTimeTicks)
        assertEquals('S', parsed.state)

        val snapshot = census(reader, FakeSignals(reader)).snapshot()
        assertEquals(424242L, snapshot.ownLive.single().birth.startTimeTicks)
        assertEquals("7001:424242", snapshot.ownLive.single().birth.identity)
    }

    @Test
    fun unreadableStatusWithSignalableProbeIsAmbiguousNotAbsent() {
        val reader = FakeProcReader()
        reader.put(FakeProcEntry(8001, uid = RUNTIME_UID, statusUnreadable = true))
        val signals = FakeSignals(reader)
        signals.probeOverrides = mapOf(8001 to ProbeOutcome.Alive)

        val snapshot = census(reader, signals).snapshot()
        assertTrue(snapshot.ownLive.isEmpty())
        assertEquals(1, snapshot.ambiguous.size)
        assertEquals("status-unreadable-but-signalable", snapshot.ambiguous.single().reason)
        assertFalse("an ambiguous candidate is never a clean result", snapshot.isCleanlyQuiescent)
    }

    @Test
    fun unreadableStatusWithPermissionDenialIsCountedForeign() {
        val reader = FakeProcReader()
        reader.put(FakeProcEntry(8002, uid = CORE_UID, statusUnreadable = true))
        val signals = FakeSignals(reader)
        signals.probeOverrides = mapOf(8002 to ProbeOutcome.MayNotSignal)

        val snapshot = census(reader, signals).snapshot()
        assertEquals(1, snapshot.unreadableForeignCount)
        assertTrue(snapshot.ambiguous.isEmpty())
        assertTrue(snapshot.isCleanlyQuiescent)
    }

    @Test
    fun permissionDenialWithOwnOrHiddenOwnerCannotProveQuiescence() {
        for (owner in listOf<Int?>(RUNTIME_UID, 0, null)) {
            val reader = FakeProcReader()
            reader.put(FakeProcEntry(8002, uid = RUNTIME_UID, statusUnreadable = true))
            reader.directoryOwner = { owner }
            val signals = FakeSignals(reader)
            signals.probeOverrides = mapOf(8002 to ProbeOutcome.MayNotSignal)
            val snapshot = census(reader, signals).snapshot()
            assertEquals(0, snapshot.unreadableForeignCount)
            assertEquals(1, snapshot.ambiguous.size)
            assertFalse(snapshot.isCleanlyQuiescent)
        }
    }

    @Test
    fun failedListingIsAFailureStateNotEmptyInventory() {
        val reader = FakeProcReader().apply { listFailure = "proc-listing-EACCES" }
        val snapshot = census(reader, FakeSignals(reader)).snapshot()
        assertEquals("proc-listing-EACCES", snapshot.inventoryFailure)
        assertEquals(0, snapshot.scannedCount)
        assertFalse(snapshot.isCleanlyQuiescent)
    }

    @Test
    fun throwingListingIsReportedNotSwallowed() {
        val reader = FakeProcReader().apply { throwOnList = IllegalStateException("boom") }
        val snapshot = census(reader, FakeSignals(reader)).snapshot()
        assertEquals("proc-listing-IllegalStateException", snapshot.inventoryFailure)
        assertFalse(snapshot.isCleanlyQuiescent)
    }

    @Test
    fun ownUidWithoutReadableBirthTimeIsAmbiguous() {
        val reader = FakeProcReader()
        reader.put(FakeProcEntry(9001, uid = RUNTIME_UID, birthUnreadable = true))
        val snapshot = census(reader, FakeSignals(reader)).snapshot()
        assertEquals(listOf("birth-time-unreadable"), snapshot.ambiguous.map { it.reason })
        assertTrue(snapshot.ownLive.isEmpty())
        assertNull(snapshot.inventoryFailure)
        assertFalse(snapshot.isCleanlyQuiescent)
    }

    @Test
    fun unparsableStatusIsAmbiguous() {
        val reader = object : ProcReader {
            override fun procPids(): ProcListOutcome = ProcListOutcome.Available(listOf(9100))
            override fun statusLines(pid: Int): List<String>? = listOf("garbage line without structure")
            override fun statFields(pid: Int): String? = "9100 (x) S 1 1 1 0 0"
        }
        val snapshot = census(reader, FakeSignals(FakeProcReader())).snapshot()
        assertEquals(listOf("status-unparsable"), snapshot.ambiguous.map { it.reason })
    }
}
