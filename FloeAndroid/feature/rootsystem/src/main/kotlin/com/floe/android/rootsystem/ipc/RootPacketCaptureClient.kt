// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import android.os.IBinder
import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.PacketCaptureChunk
import com.floe.android.rootsystem.PacketCaptureInfo
import com.floe.android.rootsystem.RootResult
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.SystemOperation
import java.io.Closeable
import java.util.UUID

/**
 * Narrow App-host client for the Full-only root packet-capture operation.
 *
 * It is deliberately not a generic shell or Shizuku entry point: the server
 * exposes one typed PACKET_CAPTURE operation, the helper id is closed, and the
 * request carries only numeric bounds. The client registers a short-lived
 * grant scoped to that operation, performs start/read/stop, and revokes the
 * grant on every terminal path.
 *
 * If the root server process is killed, its replacement has no in-memory
 * grant or session. The client therefore rebinds once to the newly published
 * service and registers a fresh grant for the same capture id on a
 * `service_died` read/stop. The replacement server answers only from its
 * durable, root-protected capture journal and only after the recorded helper
 * process is proven dead; a recovered capture is reported with
 * `daemonLost`/done so the existing drain ledger settles as a failure instead
 * of retrying `capture_unknown` forever.
 */
class RootPacketCaptureClient(
    private val taskId: String,
    private val runId: String,
    private val epoch: Long,
    private val admission: Admission,
) : Closeable {

    interface Admission {
        /** Called only after the explicit user start already occurred. */
        fun allowStart(): Boolean

        /** A stop/fence request must prevent any further read. */
        fun isCancelled(): Boolean
    }

    private data class Active(
        val client: FloeBinderClient,
        val claim: OperationClaim,
        val captureId: String,
        val grantId: String,
        val binder: IBinder,
    )

    private val lock = Any()
    private var active: Active? = null

    val isActive: Boolean get() = synchronized(lock) { active != null }

    fun start(
        helperId: String = HELPER_ID,
        interfaceName: String = "any",
        snaplen: Int = 65_535,
        maxBytes: Long,
        maxMillis: Long,
    ): RootResult<PacketCaptureInfo> {
        synchronized(lock) {
            if (active != null) return RootResult.Denied("capture_active")
            if (!admission.allowStart()) return RootResult.Denied("capture_not_authorized")
            if (taskId.isBlank() || taskId.length > 128 ||
                runId.isBlank() || runId.length > 128 || epoch <= 0
            ) return RootResult.Denied("claim")
            val published = BinderHub.peek(BinderProtocol.MODE_ROOT)
                ?: return RootResult.Unavailable("root_service_not_alive")
            val client = FloeBinderClient(published.binder)
            val grantId = ("capture-grant:" + UUID.randomUUID().toString()).take(128)
            when (val registered = registerGrant(client, grantId)) {
                is RootResult.Ok<*> -> Unit
                is RootResult.Denied -> return RootResult.Denied(registered.code, registered.message)
                is RootResult.Unavailable -> return RootResult.Unavailable(registered.code)
                is RootResult.Failed -> return RootResult.Failed(registered.code, registered.message)
            }
            val claim = claim(grantId)
            val started = client.packetCaptureStart(
                claim = claim,
                helperId = helperId,
                interfaceName = interfaceName,
                snaplen = snaplen,
                maxBytes = maxBytes,
                maxMillis = maxMillis,
            )
            if (started is RootResult.Ok<*>) {
                val info = started.value as? PacketCaptureInfo
                    ?: return RootResult.Failed("capture_reply")
                active = Active(client, claim, info.captureId, grantId, published.binder)
                return started
            }
            runCatching { client.revokeGrant(grantId) }
            return started
        }
    }

    fun read(captureId: String, maxBytes: Int = 256 * 1024): RootResult<PacketCaptureChunk> {
        val initial = synchronized(lock) {
            val value = active ?: return RootResult.Unavailable("capture_inactive")
            if (value.captureId != captureId) return RootResult.Denied("capture_unknown")
            value
        }
        if (admission.isCancelled()) return RootResult.Denied("cancelled")
        var current = initial
        var result = current.client.packetCaptureRead(current.claim, captureId, maxBytes)
        if (serviceDied(result)) {
            val rebound = recover(initial) ?: return result
            current = rebound
            result = current.client.packetCaptureRead(current.claim, captureId, maxBytes)
        }
        if (result is RootResult.Ok<*> &&
            (result.value as? PacketCaptureChunk)?.done == true
        ) {
            clear(current)
        }
        return result
    }

    fun stop(captureId: String): RootResult<PacketCaptureChunk> {
        val initial = synchronized(lock) {
            val value = active ?: return RootResult.Unavailable("capture_inactive")
            if (value.captureId != captureId) return RootResult.Denied("capture_unknown")
            value
        }
        return stopOn(initial)
    }

    override fun close() {
        val current = synchronized(lock) { active } ?: return
        val result = stopOn(current)
        val remaining = synchronized(lock) {
            if (active?.captureId == current.captureId) {
                val value = active
                active = null
                value
            } else {
                null
            }
        }
        if (remaining != null) {
            runCatching { remaining.client.revokeGrant(remaining.grantId) }
        } else if (!(result is RootResult.Ok<*> &&
                (result.value as? PacketCaptureChunk)?.done == true)
        ) {
            runCatching { current.client.revokeGrant(current.grantId) }
        }
    }

    private fun stopOn(initial: Active): RootResult<PacketCaptureChunk> {
        var current = initial
        var result = current.client.packetCaptureStop(current.claim, current.captureId)
        if (serviceDied(result)) {
            val rebound = recover(initial) ?: return result
            current = rebound
            result = current.client.packetCaptureStop(current.claim, current.captureId)
        }
        if (result is RootResult.Ok<*> &&
            (result.value as? PacketCaptureChunk)?.done == true
        ) {
            clear(current)
        }
        return result
    }

    /**
     * Rebind exactly once to the replacement root service. The server still
     * requires a live grant for the closed PACKET_CAPTURE operation; the
     * capture id is never treated as authority by itself.
     */
    private fun recover(previous: Active): Active? = synchronized(lock) {
        val already = active
        if (already != null && already !== previous &&
            already.captureId == previous.captureId && already.binder.pingBinder()
        ) {
            return already
        }
        if (previous.binder.pingBinder()) return null
        val published = BinderHub.peek(BinderProtocol.MODE_ROOT) ?: return null
        if (published.binder === previous.binder || !published.binder.pingBinder()) return null
        val client = FloeBinderClient(published.binder)
        val grantId = ("capture-recover:" + UUID.randomUUID().toString()).take(128)
        when (registerGrant(client, grantId)) {
            is RootResult.Ok<*> -> Unit
            else -> return null
        }
        val claim = claim(grantId)
        val rebound = Active(client, claim, previous.captureId, grantId, published.binder)
        active = rebound
        rebound
    }

    private fun clear(current: Active) {
        synchronized(lock) {
            if (active === current) {
                active = null
                runCatching { current.client.revokeGrant(current.grantId) }
            }
        }
    }

    private fun registerGrant(client: FloeBinderClient, grantId: String): RootResult<*> {
        val now = System.currentTimeMillis()
        val grant = GrantRequest(
            grantId = grantId,
            taskId = taskId,
            runId = runId,
            epoch = epoch,
            expiresAtMillis = now + GRANT_MILLIS,
            scopes = listOf(ScopeRoot("capture", "/data/local/tmp", writable = false)),
            operations = setOf(SystemOperation.PACKET_CAPTURE),
            packageManagementAllowed = false,
        )
        return client.registerGrant(grant)
    }

    private fun claim(grantId: String) = OperationClaim(
        taskId = taskId,
        runId = runId,
        epoch = epoch,
        grantId = grantId,
        requestId = ("capture:" + UUID.randomUUID().toString()).take(128),
    )

    private fun serviceDied(result: RootResult<*>): Boolean =
        result is RootResult.Unavailable &&
            (result.code == "service_died" || result.code == "root_service_not_alive")

    companion object {
        const val HELPER_ID = "tcpdump-v1"
        const val MAX_BYTES = 128L * 1024L * 1024L
        const val MAX_MILLIS = 5L * 60L * 1000L
        private const val GRANT_MILLIS = 10L * 60L * 1000L

        /** Real publication probe; never a fabricated root availability. */
        fun isRootServicePublished(): Boolean =
            BinderHub.peek(BinderProtocol.MODE_ROOT)?.binder?.pingBinder() == true
    }
}
