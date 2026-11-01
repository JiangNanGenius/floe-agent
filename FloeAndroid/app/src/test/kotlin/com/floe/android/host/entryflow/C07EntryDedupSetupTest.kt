// SPDX-License-Identifier: MPL-2.0
//
// C07 duplicate-intake, setup-guide navigation and fingerprint regressions.
// Pure JVM: the SharedPreferences-backed stores are not touched; these pin the
// pure policy the stores delegate to.
// AUTHORED, NOT RUN by this lane.
package com.floe.android.host.entryflow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class C07EntryDedupSetupTest {
    private val now = 1_000_000L
    private val fingerprint = "a".repeat(64)
    private val intake = "11111111-1111-1111-1111-111111111111"

    @Test
    fun liveAdmittedIntakeBlocksRotationRedelivery() {
        val record = record(C07EntryJournalStatus.ADMITTED)
        assertTrue(C07EntryDedup.blocks(record, fingerprint, intake, now))
        assertFalse(C07EntryDedup.blocks(record, fingerprint, null, now))
        assertFalse(C07EntryDedup.blocks(record, "b".repeat(64), intake, now))
    }

    @Test
    fun settledIntakeBlocksRestartRedeliveryOnlyInsideWindow() {
        for (status in listOf(
            C07EntryJournalStatus.COMPLETED,
            C07EntryJournalStatus.DISCARDED,
            C07EntryJournalStatus.FAILED,
        )) {
            val record = record(status)
            assertTrue(C07EntryDedup.blocks(record, fingerprint, null, now))
            assertFalse(C07EntryDedup.blocks(record, fingerprint, null, record.expiresAt))
            assertFalse(C07EntryDedup.blocks(record, fingerprint, null, record.expiresAt + 1))
        }
        assertFalse(C07EntryDedup.blocks(null, fingerprint, intake, now))
    }

    @Test
    fun setupGuideIsSkippableAndNotForcedEveryLaunch() {
        val first = C07SetupMachine.offerOnce(C07SetupState(), now)
        assertEquals(C07SetupState(seen = true, updatedAt = now), first.first)
        assertTrue(first.second)

        val second = C07SetupMachine.offerOnce(first.first, now + 1)
        assertFalse(second.second)

        val skipped = C07SetupMachine.skip(first.first, now + 2)
        assertTrue(skipped.seen)
        assertTrue(skipped.skipped)
        assertFalse(skipped.finished)
        assertFalse(C07SetupMachine.offerOnce(skipped, now + 3).second)
    }

    @Test
    fun setupGuideNavigationPreservesOnlyItsOwnPosition() {
        var state = C07SetupState()
        state = C07SetupMachine.next(state, now)
        assertEquals(C07SetupStep.MODELS, state.step)
        state = C07SetupMachine.next(state, now)
        assertEquals(C07SetupStep.VOICE, state.step)
        state = C07SetupMachine.previous(state, now)
        assertEquals(C07SetupStep.MODELS, state.step)
        state = C07SetupMachine.finish(state, now)
        assertTrue(state.finished)
        assertTrue(state.seen)
        assertEquals(C07SetupStep.MODELS, state.step)
    }

    @Test
    fun setupStateHasNoProviderOrVoicePayload() {
        val state = C07SetupState(
            step = C07SetupStep.VOICE,
            seen = true,
            finished = false,
            skipped = true,
            updatedAt = now,
        )
        val text = state.toString()
        assertTrue(text.contains("step=VOICE"))
        assertFalse(text.contains("provider="))
        assertFalse(text.contains("voiceID="))
        assertFalse(text.contains("credential"))
    }

    @Test
    fun notificationReplayGuardSuppressesColdWarmRedeliveryOnlyInsideWindow() {
        val guard = C07EntryReplayGuard(windowMillis = 30_000L, limit = 2)
        assertTrue(guard.admit("question:task:request", now))
        assertFalse(guard.admit("question:task:request", now + 1_000L))
        assertTrue(guard.admit("question:task:request", now + 30_000L))
        assertTrue(guard.admit("schedule:task", now + 30_001L))
        // Bounded map: the oldest key may be evicted after the limit.
        assertTrue(guard.admit("link:new", now + 30_002L))
        assertTrue(guard.admit("question:task:request", now + 60_000L))
    }

    @Test
    fun fingerprintIsStableAndContentSensitive() {
        val a = item("content://synthetic/a", "A.pdf", 10, 0)
        val b = item("content://synthetic/b", "B.pdf", 20, 1)
        val first = C07EntryFingerprint.of("SEND", "Subject", listOf(a, b))
        val again = C07EntryFingerprint.of("SEND", "Subject", listOf(a, b))
        assertEquals(first, again)
        assertEquals(64, first.length)

        assertNotEquals(first, C07EntryFingerprint.of("SEND", "Other", listOf(a, b)))
        assertNotEquals(first, C07EntryFingerprint.of("SEND", "Subject", listOf(b, a)))
        assertNotEquals(
            first,
            C07EntryFingerprint.of(
                "SEND",
                "Subject",
                listOf(item("content://synthetic/a", "A.pdf", 11, 0), b),
            ),
        )
    }

    private fun record(status: C07EntryJournalStatus): C07JournalRecord =
        C07JournalRecord(
            fingerprint = fingerprint,
            intakeID = intake,
            status = status,
            updatedAt = now,
            expiresAt = now + 60_000L,
        )

    private fun item(
        uri: String,
        name: String,
        bytes: Long,
        index: Int,
    ): C07EntryCapturedItem = C07EntryCapturedItem(
        index = index,
        kind = C07EntryItemKind.FILE,
        uriString = uri,
        mimeType = "application/pdf",
        displayName = name,
        declaredBytes = bytes,
        text = null,
    )
}
