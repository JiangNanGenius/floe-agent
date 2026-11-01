// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

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
            val now = System.currentTimeMillis()
            val grant = GrantRequest(
                grantId = grantId,
                taskId = taskId,
                runId = runId,
                epoch = epoch,
                expiresAtMillis = now + 10L * 60L * 1000L,
                scopes = listOf(ScopeRoot("capture", "/data/local/tmp", writable = false)),
                operations = setOf(SystemOperation.PACKET_CAPTURE),
                packageManagementAllowed = false,
            )
            when (val registered = client.registerGrant(grant)) {
                is RootResult.Ok<*> -> Unit
                is RootResult.Denied -> return RootResult.Denied(registered.code, registered.message)
                is RootResult.Unavailable -> return RootResult.Unavailable(registered.code)
                is RootResult.Failed -> return RootResult.Failed(registered.code, registered.message)
            }
            val claim = OperationClaim(
                taskId = taskId,
                runId = runId,
                epoch = epoch,
                grantId = grantId,
                requestId = ("capture:" + UUID.randomUUID().toString()).take(128),
            )
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
                active = Active(client, claim, info.captureId, grantId)
                return started
            }
            runCatching { client.revokeGrant(grantId) }
            return started
        }
    }

    fun read(captureId: String, maxBytes: Int = 256 * 1024): RootResult<PacketCaptureChunk> {
        val current = synchronized(lock) {
            val value = active ?: return RootResult.Unavailable("capture_inactive")
            if (value.captureId != captureId) return RootResult.Denied("capture_unknown")
            value
        }
        if (admission.isCancelled()) return RootResult.Denied("cancelled")
        val result = current.client.packetCaptureRead(current.claim, captureId, maxBytes)
        if (result is RootResult.Ok<*> &&
            (result.value as? PacketCaptureChunk)?.done == true
        ) {
            synchronized(lock) {
                if (active === current) {
                    active = null
                    runCatching { current.client.revokeGrant(current.grantId) }
                }
            }
        }
        return result
    }

    fun stop(captureId: String): RootResult<PacketCaptureChunk> {
        val current = synchronized(lock) {
            val value = active ?: return RootResult.Unavailable("capture_inactive")
            if (value.captureId != captureId) return RootResult.Denied("capture_unknown")
            value
        }
        val result = current.client.packetCaptureStop(current.claim, captureId)
        val done = (result as? RootResult.Ok<*>)?.value
            ?.let { it as? PacketCaptureChunk }
            ?.done == true
        // A stop that did not prove process/file completion keeps the exact
        // client/grant so a later stop or tail read can continue. Releasing it
        // here would hide a live helper and allow Root retirement.
        if (done) {
            synchronized(lock) {
                if (active === current) {
                    active = null
                    runCatching { current.client.revokeGrant(current.grantId) }
                }
            }
        }
        return result
    }

    override fun close() {
        val current = synchronized(lock) {
            val value = active
            active = null
            value
        } ?: return
        runCatching { current.client.packetCaptureStop(current.claim, current.captureId) }
        runCatching { current.client.revokeGrant(current.grantId) }
    }

    companion object {
        const val HELPER_ID = "tcpdump-v1"
        const val MAX_BYTES = 128L * 1024L * 1024L
        const val MAX_MILLIS = 5L * 60L * 1000L

        /** Real publication probe; never a fabricated root availability. */
        fun isRootServicePublished(): Boolean =
            BinderHub.peek(BinderProtocol.MODE_ROOT)?.binder?.pingBinder() == true
    }
}
