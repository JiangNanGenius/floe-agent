// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer

/**
 * G09-R2 bounded render-ticket transport.
 *
 * This maps a FUTURE dedicated C ABI shaped like the existing
 * `OfficeAIHostMailbox` (bind/claim/describe/live/stop/heartbeat/complete/
 * close/stats). It is deliberately NOT a reverse call on
 * `floe_bridge_exchange`: a multi-minute Media3 export must never hold
 * `CreativeProjectController.exchangeLocked` or the single creative lane.
 *
 * The ticket transport is IPC, not a project or job store. The existing native
 * project/job stores remain the truth; the platform ticket service claims,
 * renders and settles exactly once, and the native side drains before Root stop.
 * At most [WorkbenchR2Limits.MAX_LIVE_RENDER_TICKETS] tickets are live.
 *
 * The descriptor carries a native-verified SNAPSHOT FILE lease (trusted media
 * root + relative path + digest + project revision) instead of inline project
 * JSON. The root comes only from the native lease/envelope, never from
 * recorded project JSON. Descriptor ≤ 64 KiB, reply ≤ 1 MiB; neither is a
 * second project document.
 */
data class RenderTicketDescriptor(
    val ticketID: String,
    val descriptorVersion: Int,
    val kind: MediaExportKind,
    val projectID: String,
    /** Attempt identity bound to the native export binding. */
    val attemptID: String,
    /** Native-issued trusted media root; never a recorded project path. */
    val mediaRootPath: String,
    /** Explicit storage layer bound to this ticket. */
    val storage: CreativeStorageLayer,
    /** Real route provenance when one exists; never storage authority. */
    val origin: CreativeOriginContext? = null,
    val projectRevision: Long,
    val timelineDigest: String,
    /** Native-issued lease identity, never a credential. */
    val leaseID: String,
    /** Opaque native owner reference for audit, not a secret. */
    val ownerReference: String,
    val epoch: Long,
    /** Trusted relative path under the accepted media root. */
    val snapshotRelativePath: String,
    val snapshotSHA256: String,
    val snapshotByteCount: Long,
    /** Expiry of the native snapshot lease; an expired lease is refused. */
    val snapshotLeaseExpiresAt: String,
    /** Service-derived output path under the trusted media root. */
    val outputRelativePath: String,
    val videoSettings: VideoExportSettings? = null,
    val imageSettings: ImageExportSettings? = null,
    val previewWindow: PreviewWindow? = null,
    val expiresAt: String,
    val descriptorByteCount: Int,
)

data class ClaimedRenderTicket(
    val descriptor: RenderTicketDescriptor,
    val claimToken: String,
    val claimedAt: String,
    val leaseExpiresAt: String,
)

enum class RenderTicketReplyStatus(val wire: String) {
    COMPLETED("completed"),
    FAILED("failed"),
    CANCELLED("cancelled"),
    TIMEOUT("timeout"),
    UNSUPPORTED("unsupported"),
}

/**
 * Exactly one terminal reply per ticket. A completed reply MUST carry a
 * verified [MediaExportReceipt]; a failure reply carries a typed code and no
 * receipt.
 */
data class RenderTicketReply(
    val ticketID: String,
    val status: RenderTicketReplyStatus,
    val receipt: MediaExportReceipt? = null,
    val errorCode: String? = null,
    val completedAt: String,
    val replyByteCount: Int,
)

data class RenderTicketStats(
    val live: Int,
    val claimed: Int,
    val completed: Int,
    val cancelled: Int,
    val failed: Int,
    val maxLive: Int = WorkbenchR2Limits.MAX_LIVE_RENDER_TICKETS,
    val lastErrorCode: String? = null,
)

/**
 * Callback/polling transport bound to one accepted epoch. Implementations must:
 * * reject claim/complete after epoch change or Root stop;
 * * enforce exactly-one terminal settlement (a duplicate complete returns
 *   false and never rewrites a receipt);
 * * cancel/drain claimed work on stop and heartbeat with the declared lease;
 * * require the claim token on shouldStop/heartbeat/complete/close so a
 *   different owner cannot settle another service's ticket;
 * * never call back into the Kotlin creative exchange while rendering.
 */
interface MediaRenderTicketTransport {
    suspend fun bind(epoch: Long): Boolean

    /** Null on a bounded poll timeout; never an invented ticket. */
    suspend fun claim(timeoutMillis: Long): ClaimedRenderTicket?

    suspend fun describe(ticketID: String): RenderTicketDescriptor?

    fun isLive(ticketID: String): Boolean

    suspend fun shouldStop(ticketID: String, claimToken: String): Boolean

    suspend fun heartbeat(ticketID: String, claimToken: String): Boolean

    /** Exactly once. A mismatched claim token or duplicate settlement returns false. */
    suspend fun complete(ticketID: String, claimToken: String, reply: RenderTicketReply): Boolean

    /** Claimed close; root drain closes every claimed ticket with its own token. */
    suspend fun close(ticketID: String, claimToken: String)

    suspend fun stats(): RenderTicketStats
}

enum class MediaProjectToolExportRoute(val wire: String) {
    /** A real renderer route through [MediaRenderTicketTransport]. */
    RENDER_TICKET("renderTicket"),

    /** No real renderer is connected; export must be reported unavailable. */
    UNAVAILABLE("unavailable"),
}

/**
 * Honest `media.project` tool export capability. A permanent fake exporter or
 * a success-string-only export is not representable: a route is either the
 * real render-ticket transport or explicitly unavailable with a reason.
 *
 * Registering the tool is deliberately NOT part of this contract package.
 */
data class MediaProjectToolExportCapability(
    val route: MediaProjectToolExportRoute,
    val registered: Boolean = false,
    val reason: String? = null,
    val supportedActions: Set<String> = setOf("read", "propose", "apply", "export"),
)

data class MediaProjectToolExportSubmission(
    val ticketID: String,
    val leaseID: String,
    val projectRevision: Long,
    val acceptedAt: String,
)

/**
 * Agent-tool-side port. A later tool host may use it only after the native
 * render-ticket bridge is real and registered; this package performs no tool
 * registration and no export.
 */
interface MediaProjectToolExportPort {
    fun capability(): MediaProjectToolExportCapability

    suspend fun submitExport(request: MediaExportRequest): MediaProjectToolExportSubmission
}
