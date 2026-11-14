// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.runtimeipc.RuntimePeerProof
import com.floe.android.runtimeipc.RuntimeTransportFailure
import kotlinx.coroutines.CancellationException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * job-d4aeae04aa5a4f6c — bounded runtime-channel lifecycle regressions.
 *
 * Full 13 produced ~19,930 typed `shell.poll` refusals (one every ~300 ms for
 * 100 minutes) and a brand-new `RuntimeConnection` per retired poll / status
 * probe; every one of those opened a `bindService` and registered an unlinked
 * binder death recipient until ART aborted at 50,069 JNI global references.
 * These tests pin the replacement policy: one channel per lease, reopened only
 * for a REAL transport loss, never for a well-formed refusal, and never shared
 * or cross-closed between owners.
 */
class LinuxRuntimeChannelLeaseTest {

    private class FakeChannel(val id: String) : LinuxRuntimeChannel {
        override val identity: Any = Any()
        var connects = 0
        var exchanges = 0
        var closes = 0
        var connectFailure: Exception? = null
        var exchangeFailure: RuntimeException? = null
        var reply: JSONObject = JSONObject().put("ok", true).put("result", JSONObject())

        override fun connect(timeoutMillis: Long) {
            connects += 1
            connectFailure?.let { throw it }
        }

        override fun exchange(operation: String, payload: JSONObject, requestID: String): JSONObject {
            exchanges += 1
            exchangeFailure?.let { throw it }
            return JSONObject(reply.toString())
        }

        override fun currentPeerProof(): RuntimePeerProof? = null

        override fun close() {
            closes += 1
        }
    }

    private class Harness {
        val channels = mutableListOf<FakeChannel>()
        var connectFailure: Exception? = null
        var exchangeFailure: RuntimeException? = null
        val lease = LinuxRuntimeChannelLease("test", connectTimeoutMillis = 15_000L) {
            FakeChannel("channel-${channels.size}").also {
                it.connectFailure = connectFailure
                it.exchangeFailure = exchangeFailure
                channels += it
            }
        }
    }

    @Test
    fun manyPollsOpenExactlyOneBindingAndNeverRebind() {
        val harness = Harness()
        repeat(1_000) { index ->
            harness.lease.exchange("shell.poll", JSONObject().put("sessionID", "s-$index"))
        }
        assertEquals("one bind for the lease's actual lifetime", 1, harness.lease.opens)
        assertEquals(1_000, harness.lease.exchanges)
        assertEquals(1_000, harness.channels.single().exchanges)
        assertEquals("the live channel is never closed by polling", 0, harness.channels.single().closes)
    }

    @Test
    fun aRemoteRefusalReplyIsNotATransportFailure() {
        val channels = mutableListOf<FakeChannel>()
        val lease = LinuxRuntimeChannelLease("refusing") {
            FakeChannel("refusing").also {
                it.reply = JSONObject().put("ok", false).put("code", "runtime_not_ready")
                channels += it
            }
        }
        repeat(10) {
            val envelope = lease.exchange("shell.poll", JSONObject())
            assertFalse(envelope.getBoolean("ok"))
            assertEquals("runtime_not_ready", envelope.getString("code"))
        }
        assertEquals("a refusal crossed the wire: reuse the binder", 1, lease.opens)
        assertEquals(0, lease.transportFailures)
        assertEquals(0, channels.single().closes)
    }

    @Test
    fun aRealTransportFailureReopensExactlyOnceAndClosesTheRetiredChannel() {
        val harness = Harness()
        harness.lease.exchange("status")
        val first = harness.channels.single()
        first.exchangeFailure = RuntimeTransportFailure("binder died")
        try {
            harness.lease.exchange("status")
            fail("the transport failure must surface")
        } catch (_: RuntimeTransportFailure) { /* expected */ }
        assertEquals(1, harness.lease.transportFailures)
        assertEquals("retired channel closed exactly once", 1, first.closes)
        harness.lease.exchange("status")
        assertEquals(2, harness.lease.opens)
        assertEquals(1, harness.channels[1].exchanges)
        // A late close of the retired channel cannot disturb the replacement.
        first.close()
        harness.lease.exchange("status")
        assertEquals(2, harness.lease.opens)
        assertEquals(2, harness.channels[1].exchanges)
    }

    @Test
    fun aConnectWaiterTimeoutKeepsTheRegisteredBinding() {
        val harness = Harness()
        harness.connectFailure = IllegalStateException(RuntimeConnection.CONNECT_TIMEOUT_MESSAGE)
        try {
            harness.lease.exchange("status")
            fail("the waiter timeout must surface")
        } catch (_: IllegalStateException) { /* expected */ }
        harness.channels.single().connectFailure = null
        harness.lease.exchange("status")
        assertEquals("a cold idle service must not be unbound and re-bound", 1, harness.lease.opens)
        assertEquals("the still-registered binding was kept", 0, harness.channels.single().closes)
    }

    @Test
    fun aRefusedHandshakeDropsTheChannel() {
        val harness = Harness()
        harness.connectFailure = IllegalStateException("Runtime component unavailable")
        try {
            harness.lease.exchange("status")
            fail("a refused handshake must surface")
        } catch (_: IllegalStateException) { /* expected */ }
        assertEquals("the dead candidate is unlinked/unbound", 1, harness.channels.single().closes)
        harness.connectFailure = null
        harness.lease.exchange("status")
        assertEquals(2, harness.lease.opens)
    }

    @Test
    fun closingOneSessionChannelNeverTouchesAnotherOwner() {
        val first = Harness()
        val second = Harness()
        first.lease.exchange("shell.poll", JSONObject())
        second.lease.exchange("shell.poll", JSONObject())
        val firstChannel = first.channels.single()
        val secondChannel = second.channels.single()
        assertNotEquals(firstChannel.identity, secondChannel.identity)
        first.lease.close()
        assertEquals(1, firstChannel.closes)
        assertEquals("another owner's session survives the close", 0, secondChannel.closes)
        second.lease.exchange("shell.poll", JSONObject())
        assertEquals("both real requests reached the surviving session", 2, second.channels.single().exchanges)
    }

    @Test
    fun closeIsIdempotentAndFailsClosed() {
        val harness = Harness()
        harness.lease.exchange("status")
        harness.lease.close()
        harness.lease.close()
        assertEquals(1, harness.channels.single().closes)
        try {
            harness.lease.exchange("status")
            fail("a closed lease must not reopen a channel")
        } catch (_: IllegalStateException) { /* expected */ }
        assertEquals(1, harness.lease.opens)
    }

    @Test
    fun aRecordedTerminalPageCarriesOnlyRecordedTerminalTruth() {
        val payload = JSONObject().put("sessionID", "engine-session").put("cursor", 4_096L).put("maxBytes", 16_384)
        val proof = JSONObject()
            .put("state", "released")
            .put("sessionID", "engine-session")
            .put("epoch", 7L)
            .put("cancelled", false)
            .put("exitCode", 0)
            .put("workspaceStatus", "synced")
            .put("workspaceKey", "0123456789abcdef0123456789abcdef")
            .put("workspaceOwner", true)
        val page = LinuxShellPump.recordedTerminalPage(payload, proof)
        assertEquals("engine-session", page.getString("sessionID"))
        assertEquals("terminated", page.getString("state"))
        assertTrue("a recorded real terminal stays released", page.getBoolean("leaseReleased"))
        assertEquals(4_096L, page.getLong("cursor"))
        assertEquals("", page.getString("outputBase64"))
        assertFalse(page.getBoolean("more"))
        assertEquals(0, page.getInt("exitCode"))
        assertEquals("synced", page.getString("workspaceStatus"))
        assertEquals("0123456789abcdef0123456789abcdef", page.getString("workspaceKey"))
        assertFalse("the internal epoch never rides the poll page", page.has("epoch"))
        // No new bytes and no invented skip: the page is an empty re-projection
        // of the already-delivered terminal.
        assertEquals(0L, page.getLong("gapBytes"))
        assertEquals(0L, page.getLong("droppedBytes"))
    }

    @Test
    fun anIdleStatusCannotBeProjectedAsATerminalRelease() {
        try {
            LinuxShellPump.recordedTerminalPage(
                JSONObject().put("sessionID", "engine-session"),
                JSONObject().put("state", "quiescent"),
            )
            fail("idle status is not a recorded release")
        } catch (_: IllegalArgumentException) { /* expected */ }
    }

    @Test
    fun aRecordedReleaseCannotBeUsedForAnotherSession() {
        try {
            LinuxShellPump.recordedTerminalPage(
                JSONObject().put("sessionID", "other-session"),
                JSONObject().put("state", "released").put("sessionID", "engine-session"),
            )
            fail("terminal proof must belong to the requested session")
        } catch (_: IllegalArgumentException) { /* expected */ }
    }

    @Test
    fun thePollRefusalVocabularyIsClosed() {
        assertTrue("runtime_not_ready" in LinuxShellPump.FINAL_POLL_REFUSALS)
        assertTrue("runtime_not_started" in LinuxShellPump.FINAL_POLL_REFUSALS)
        assertFalse("a transport failure is never a terminal refusal", "runtime_unavailable" in LinuxShellPump.FINAL_POLL_REFUSALS)
        assertTrue("shell.poll" in LinuxShellPump.POLLED_OPERATIONS)
        assertTrue("stdio.poll" in LinuxShellPump.POLLED_OPERATIONS)
        assertFalse("status" in LinuxShellPump.POLLED_OPERATIONS)
        assertTrue("environment_transaction_busy" in LinuxShellPump.ADMISSION_REFUSAL_CODES)
        assertTrue("environment_transaction_requires_idle" in LinuxShellPump.ADMISSION_REFUSAL_CODES)
        assertTrue("runtime_not_ready" in LinuxShellPump.ADMISSION_REFUSAL_CODES)
        assertTrue(LinuxShellPump.REFUSAL_TOKEN.matches("runtime_not_ready"))
        assertFalse(LinuxShellPump.REFUSAL_TOKEN.matches("Runtime not ready"))
        assertFalse(LinuxShellPump.REFUSAL_TOKEN.matches("runtime_unavailable\nsecond line"))
    }

    @Test
    fun aLateRetirementOfAReplacedChannelCannotClearTheSuccessor() {
        val harness = Harness()
        harness.lease.exchange("status")
        val retired = harness.channels.single()
        retired.exchangeFailure = RuntimeTransportFailure("binder died")
        try { harness.lease.exchange("status") } catch (_: RuntimeTransportFailure) { /* expected */ }
        harness.lease.exchange("status")
        assertEquals(2, harness.lease.opens)
        val live = harness.channels[1]
        // A duplicate/late retirement of the OLD channel must be a no-op.
        harness.lease.retire(retired)
        assertEquals("the replacement is untouched", 0, live.closes)
        harness.lease.exchange("status")
        assertEquals(2, harness.lease.opens)
        assertEquals(2, live.exchanges)
    }

    @Test
    fun controlFailureCodesStayTypedAndBounded() {
        assertEquals(
            "runtime_not_ready",
            LinuxShellPump.controlFailureCode(LinuxShellPump.AdmissionRefused("runtime_not_ready")),
        )
        assertEquals(
            "environment_transaction_busy",
            LinuxShellPump.controlFailureCode(LinuxShellPump.AdmissionRefused("environment_transaction_busy")),
        )
        assertEquals(
            "runtime_unavailable",
            LinuxShellPump.controlFailureCode(LinuxShellPump.AdmissionRefused("Bad Code")),
        )
        assertEquals(
            "runtime_unavailable",
            LinuxShellPump.controlFailureCode(RuntimeTransportFailure("binder died")),
        )
        assertEquals(
            "runtime_unavailable",
            LinuxShellPump.controlFailureCode(IllegalStateException("local decode failure")),
        )
        assertEquals(
            "cancelled",
            LinuxShellPump.controlFailureCode(CancellationException("stopped")),
        )
    }

    @Test
    fun watchBackoffIsMonotonicAndBounded() {
        assertEquals(LinuxShellPump.WATCH_POLL_INTERVAL_MILLIS, LinuxShellPump.watchBackoffMillis(0))
        var previous = LinuxShellPump.watchBackoffMillis(1)
        for (failure in 2..60) {
            val current = LinuxShellPump.watchBackoffMillis(failure)
            assertTrue("backoff never shrinks", current >= previous)
            assertTrue("backoff stays bounded", current <= LinuxShellPump.WATCH_FAILURE_BACKOFF_MAX_MILLIS)
            previous = current
        }
        assertEquals(
            LinuxShellPump.WATCH_POLL_INTERVAL_MILLIS,
            LinuxShellPump.reconcileBackoffMillis(0),
        )
        assertEquals(LinuxShellPump.watchBackoffMillis(4), LinuxShellPump.reconcileBackoffMillis(4))
    }
}
