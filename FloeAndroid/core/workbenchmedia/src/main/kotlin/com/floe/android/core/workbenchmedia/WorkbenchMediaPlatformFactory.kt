// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import android.content.Context
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaAssetProbeRequest
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.MediaProjectToolExportPort
import com.floe.android.feature.workbench.MediaRenderTicketTransport
import com.floe.android.feature.workbench.RenderTicketDescriptor
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/** Maximum entries returned by [WorkbenchMediaSession.listRecoveredExports]. */
const val MAX_RECOVERED_EXPORT_LIST = 24

/**
 * Native-owned accepted epoch/root truth. NativeFoundation supplies this from
 * its App facade; the platform never invents an epoch, a root or a "first
 * project". [mediaRootPath] must be the exact native-issued media root for
 * [currentEpoch], not a recorded project path.
 *
 * This is the accepted BASE root used for epoch liveness. An export journal is
 * written under the per-project root returned by [WorkbenchRecoveryAuthority];
 * do not use [mediaRootPath] to find a project journal.
 */
interface WorkbenchEpochOwner {
    fun currentEpoch(): Long

    fun isEpochLive(epoch: Long): Boolean

    fun mediaRootPath(epoch: Long): String?
}

/** One accepted authority decision with the exact facts the platform must match. */
data class AuthorityGrant(
    val epoch: Long,
    val mediaRootPath: String,
    val projectID: String? = null,
    val revision: Long? = null,
    val timelineDigest: String? = null,
)

sealed interface AuthorityDecision {
    data class Accepted(val grant: AuthorityGrant) : AuthorityDecision

    data class Refused(
        val code: String,
        val reason: String,
        val retryable: Boolean = false,
    ) : AuthorityDecision
}

/**
 * Native-issued lease/provenance validation. Implementations MUST verify that
 * the binding/ticket belongs to the accepted epoch, project, revision, digest
 * and trusted root; they must NOT simply echo client values. The platform
 * additionally re-proves the snapshot file path, size, digest and JSON schema
 * before using any bytes.
 *
 * None of these calls may block the native creative exchange: they are
 * expected to be bounded mailbox/DB lookups on the native side.
 */
interface WorkbenchLeaseAuthority {
    suspend fun validateRenderBinding(binding: MediaExportBinding): AuthorityDecision

    suspend fun validateProbeRoot(request: MediaAssetProbeRequest): AuthorityDecision

    suspend fun validateTicket(
        descriptor: RenderTicketDescriptor,
        claimToken: String,
    ): AuthorityDecision
}

/**
 * Exact App-DI inputs. `epochOwner`, `leaseAuthority`, `recoveryAuthority` and
 * `lifecycleAuthority` are required and have no dummy/default implementation:
 * a real native facade must supply them. In particular there is no path-based
 * recovery fallback and no no-op lifecycle pin; a missing native proof is a
 * startup/DI error, not a silently weaker authority model.
 *
 * `clockMillis` is a display/status clock only (lease expiry authority remains
 * native); `ioDispatcher` must be a real background dispatcher. The session is
 * process-scoped: closing a PlaybackHandle releases the editor player, while
 * an export keeps running in the service against its captured lease.
 */
class WorkbenchMediaPlatformConfig(
    context: Context,
    val epochOwner: WorkbenchEpochOwner,
    val leaseAuthority: WorkbenchLeaseAuthority,
    val recoveryAuthority: WorkbenchRecoveryAuthority,
    val lifecycleAuthority: WorkbenchMediaLifecycleAuthority,
    val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    val clockMillis: () -> Long = System::currentTimeMillis,
    val progressPollMillis: Long = 500L,
    val ticketHeartbeatMillis: Long = 5_000L,
) {
    val context: Context = context.applicationContext

    init {
        require(ioDispatcher !== Dispatchers.Unconfined) { "Media platform requires a background IO dispatcher" }
        require(progressPollMillis in 100L..5_000L) { "progressPollMillis must be 100..5000" }
        require(ticketHeartbeatMillis in 1_000L..30_000L) { "ticketHeartbeatMillis must be 1000..30000" }
    }
}

data class MediaDrainReport(
    val drained: Boolean,
    val activeExports: Int,
    val activeTickets: Int,
    val openPlayers: Int,
    val reason: String? = null,
    val measuredAt: String,
    /** Registered pins plus in-flight acquisitions whose release is not yet confirmed. */
    val outstandingPins: Int = 0,
    /** True when a native unpin returned false/threw and the pin is retained. */
    val pinReleaseUnknown: Boolean = false,
)

data class TicketDrainReport(
    val drained: Boolean,
    val activeTickets: Int,
    val claimedTickets: Int,
    val reason: String? = null,
    val measuredAt: String,
)

/**
 * The one media platform entry point for the App. It owns:
 *  * the real Media3 playback/export/image platform behind the frozen ports;
 *  * the mediaProcessing export service binding (service-owned jobs survive
 *    editor close);
 *  * the bounded render-ticket consumer over the native-injected transport.
 *
 * `startRenderTickets` is idempotent only for the SAME transport instance and
 * epoch; a different transport/epoch requires a stopped/drained consumer, so a
 * root swap can never retarget an in-flight ticket. `drain` first fences the
 * session against new exports/players/previews/tickets, then cancels owned
 * work and only reports `drained=true` after actual workers/tickets/players
 * AND native lifecycle pins are gone; it never treats a cancel request or a UI
 * terminal status as proof of drain. A drained/closed session is one-way; use
 * a new session only after native accepts a new live epoch.
 *
 * Root/epoch replacement must call [retire] instead of merely `drain`/`close`:
 * only [retire] returns after the process export registry and the render-ticket
 * transport have been released, so a new factory/session can be installed
 * without racing the old process-wide registry. `drain` is the reusable
 * readiness barrier; `retire` is the one-way teardown.
 */
interface WorkbenchMediaSession : AutoCloseable {
    val platform: WorkbenchMediaPlatform

    /** Honest agent-tool export port; unavailable until a native transport is attached. */
    val toolExport: MediaProjectToolExportPort

    suspend fun startRenderTickets(transport: MediaRenderTicketTransport, epoch: Long): Boolean

    /** Honest transport state (including typed last error) for the App's unavailable UI. */
    fun ticketState(): com.floe.android.core.workbenchmedia.ticket.RenderTicketServiceState

    suspend fun stopRenderTickets(timeoutMillis: Long = 10_000L): TicketDrainReport

    /**
     * Bounded list of active and durable recovered exports for one accepted
     * project/storage/origin owner. The native [WorkbenchRecoveryAuthority]
     * reauthorizes the current editor session and supplies the project root;
     * the list never accepts a caller path and never creates a second job store.
     *
     * `limit` must be 1..[MAX_RECOVERED_EXPORT_LIST]; an invalid value is a
     * typed `invalidPayload` refusal (not a silent clamp). Active in-memory
     * statuses take exact precedence over the same job's journal record, and a
     * completed record is only included after the same size+SHA proof used by
     * `exportStatus`. Listing never retries or resubmits work.
     */
    suspend fun listRecoveredExports(
        context: CreativeProjectContext,
        limit: Int = MAX_RECOVERED_EXPORT_LIST,
    ): List<MediaExportStatus>

    suspend fun drain(timeoutMillis: Long = 15_000L): MediaDrainReport

    /**
     * Awaitable one-way retirement for a Root/epoch replacement.
     *
     * This is the ONLY call an App-DI owner may await before installing a new
     * session: it fences the session, awaits the actual export workers, ticket
     * claims/transport loop, players and native lifecycle pins, synchronously
     * releases the process-scoped export registry and the render-ticket
     * transport, and only then returns `drained=true`. There is no sleep/poll
     * hand-off and no fire-and-forget cleanup: the registry is gone BEFORE this
     * method returns. [close] may launch this best-effort for an AutoCloseable
     * caller, but Root replacement must await [retire] itself.
     *
     * `timeoutMillis` is bounded to 0..60000. On `drained=false` ownership is
     * retained (workers/players/claims/pins and the registry stay installed) so
     * a later [retire] can retry; `drained=true` is never returned for a
     * partially released session. A successful retire is idempotent and later
     * calls return the completed report. A failed retire leaves the session
     * fenced and closed to new work (one-way, like [drain]).
     */
    suspend fun retire(timeoutMillis: Long = 15_000L): MediaDrainReport

    override fun close()
}

object WorkbenchMediaPlatformFactory {
    fun create(config: WorkbenchMediaPlatformConfig): WorkbenchMediaSession =
        WorkbenchMediaSessionImpl(config)
}
