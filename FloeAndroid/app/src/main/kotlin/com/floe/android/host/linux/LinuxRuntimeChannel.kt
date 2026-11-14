// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.runtimeipc.RuntimePeerProof
import com.floe.android.runtimeipc.RuntimeTransportFailure
import org.json.JSONObject
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * One authenticated runtime channel (a `RuntimeConnection`) behind the pump's
 * narrow transport needs. `identity` is used for late-callback fencing: a
 * failure/teardown from a retired channel may never clear its replacement.
 */
internal interface LinuxRuntimeChannel : Closeable {
    val identity: Any
    fun connect(timeoutMillis: Long)
    fun exchange(operation: String, payload: JSONObject, requestID: String = UUID.randomUUID().toString()): JSONObject
    fun currentPeerProof(): RuntimePeerProof?
}

/** The production channel: exactly the existing [RuntimeConnection] contract. */
internal class RuntimeIpcChannel(private val connection: RuntimeConnection) : LinuxRuntimeChannel {
    override val identity: Any get() = connection

    override fun connect(timeoutMillis: Long) {
        connection.connect().get(timeoutMillis, TimeUnit.MILLISECONDS)
    }

    override fun exchange(operation: String, payload: JSONObject, requestID: String): JSONObject =
        connection.exchange(operation, payload, requestID)

    override fun currentPeerProof(): RuntimePeerProof? = connection.currentPeerProof()

    override fun close() = connection.close()
}

/**
 * A connection reused for its ACTUAL lifetime (job-d4aeae04aa5a4f6c).
 *
 * The Full 13 repair evidence shows the pump used to create a brand-new
 * `RuntimeConnection` for every retired terminal poll and every status/
 * capability probe, and to drop the session connection on ANY exception —
 * including a well-formed `ok=false` operation refusal that crossed the wire.
 * Each of those opened one `bindService` and one unlinked `linkToDeath`
 * recipient, which is precisely the ART global-reference overflow (50,069
 * lambdas) plus 436 outstanding service-dispatcher entries in the crash dump.
 *
 * This lease therefore:
 *  * opens at most one channel per lease and reuses it for every call;
 *  * drops and reopens it ONLY for a real [RuntimeTransportFailure];
 *  * treats an `ok=false` refusal as a normal reply (same channel);
 *  * keeps the binding when a cold idle service merely exceeded the waiter
 *    timeout (no rebind storm, the start can still complete);
 *  * never lets a late failure from a retired channel clear a newer one.
 */
internal class LinuxRuntimeChannelLease(
    private val label: String,
    private val connectTimeoutMillis: Long = 15_000L,
    private val open: () -> LinuxRuntimeChannel,
) : Closeable {
    private val lock = Any()
    private var channel: LinuxRuntimeChannel? = null
    private var closed = false

    /** Bounded-lifecycle counters (diagnostics/regressions only). */
    var opens = 0
        private set
    var exchanges = 0
        private set
    var transportFailures = 0
        private set

    fun exchange(
        operation: String,
        payload: JSONObject = JSONObject(),
        requestID: String = UUID.randomUUID().toString(),
    ): JSONObject {
        val current = acquire()
        try {
            current.connect(connectTimeoutMillis)
        } catch (failure: Exception) {
            // A cold/idle service that has not answered the bind yet is NOT a
            // dead channel: keep it (and its registered binding) so the next
            // call waits for the SAME start instead of binding again.
            if (!RuntimeConnection.isConnectWaitTimeout(failure)) retire(current)
            throw failure
        }
        try {
            val reply = current.exchange(operation, payload, requestID)
            exchanges += 1
            return reply
        } catch (failure: RuntimeTransportFailure) {
            transportFailures += 1
            retire(current)
            throw failure
        }
    }

    /**
     * Identity-fenced retirement: only the CURRENT channel is closed/cleared.
     * A late failure or teardown from a channel that was already replaced can
     * therefore never clear (or close) its successor. Internal so the
     * late-callback regression can prove that fence directly.
     */
    internal fun retire(retired: LinuxRuntimeChannel) {
        val owned = synchronized(lock) {
            if (channel !== retired) false else { channel = null; true }
        }
        if (owned) runCatching { retired.close() }
    }

    private fun acquire(): LinuxRuntimeChannel = synchronized(lock) {
        check(!closed) { "$label runtime channel is closed" }
        channel?.let { return it }
        val fresh = open()
        opens += 1
        channel = fresh
        fresh
    }

    /** The CURRENT authenticated peer facts, or null for a closed/no channel.
     *  Trusted-host receipt stamping only (the channel re-runs the same peer
     *  admission); a retired channel is never measured. */
    fun currentPeerProof(): RuntimePeerProof? {
        val current = synchronized(lock) { if (closed) null else channel }
        return current?.currentPeerProof()
    }

    override fun close() {
        val retired = synchronized(lock) {
            if (closed) return
            closed = true
            val current = channel
            channel = null
            current
        }
        retired?.let { runCatching { it.close() } }
    }
}
