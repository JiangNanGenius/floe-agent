// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import com.floe.android.core.workbenchmedia.AuthorityDecision
import com.floe.android.core.workbenchmedia.AuthorityGrant
import com.floe.android.core.workbenchmedia.MediaLifecycleKind
import com.floe.android.core.workbenchmedia.MediaLifecyclePin
import com.floe.android.core.workbenchmedia.MediaLifecyclePinDecision
import com.floe.android.core.workbenchmedia.MediaLifecyclePinRequest
import com.floe.android.core.workbenchmedia.RecoveryOwnerGrant
import com.floe.android.core.workbenchmedia.RecoveryRootDecision
import com.floe.android.core.workbenchmedia.WorkbenchEpochOwner
import com.floe.android.core.workbenchmedia.WorkbenchLeaseAuthority
import com.floe.android.core.workbenchmedia.WorkbenchMediaLifecycleAuthority
import com.floe.android.core.workbenchmedia.WorkbenchRecoveryAuthority
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaAssetProbeRequest
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.RenderTicketDescriptor
import com.floe.android.host.creative.CreativeHostController
import com.floe.android.host.creative.R2AuthorityDecision
import com.floe.android.host.creative.R2PreparedRenderBinding
import com.floe.android.host.creative.R2ProjectMediaRoot

/**
 * App-owned adapters between the plain native host authority
 * (`CreativeR2HostAuthority`) and the platform module's required ports.
 *
 * The native host deliberately imports no platform module. Every adapter here
 * is a STATELESS projection over the CURRENT `CreativeHostController` read
 * through [hostProvider], so an epoch replacement can never leave a captured
 * old controller/root behind. No adapter invents an epoch, a root, a lease or
 * an owner proof; refusals are carried through as a typed decision.
 */
internal class MediaWorkbenchEpochOwner(
    private val hostProvider: () -> CreativeHostController,
) : WorkbenchEpochOwner {
    private val authority get() = hostProvider().r2Authority

    override fun currentEpoch(): Long = authority.currentEpoch()

    override fun isEpochLive(epoch: Long): Boolean = authority.isEpochLive(epoch)

    /**
     * The accepted ANCESTOR root only (journal/epoch fence). Per-project
     * roots always come from a native lease or [resolveProjectMediaRoot].
     */
    override fun mediaRootPath(epoch: Long): String? =
        if (authority.isEpochLive(epoch)) authority.acceptedBaseRootPath() else null
}

internal class MediaWorkbenchLeaseAuthority(
    private val hostProvider: () -> CreativeHostController,
) : WorkbenchLeaseAuthority {
    private val authority get() = hostProvider().r2Authority

    override suspend fun validateRenderBinding(
        binding: MediaExportBinding,
    ): AuthorityDecision = authority.validateRenderBinding(binding.toPrepared()).toPlatform()

    override suspend fun validateProbeRoot(
        request: MediaAssetProbeRequest,
    ): AuthorityDecision = authority.validateProbeRoot(
        request.context, request.mediaRootPath, request.relativePath,
    ).toPlatform()

    override suspend fun validateTicket(
        descriptor: RenderTicketDescriptor,
        claimToken: String,
    ): AuthorityDecision = authority.validateTicket(descriptor, claimToken).toPlatform()
}

/**
 * Per-project recovery root, resolved by native truth from the CURRENT
 * session/project/storage/origin. `ownerProof` (stable durable owner) is the
 * platform's `ownerKey`; the accepted base root and the ephemeral session
 * digest are never substituted for it.
 */
internal class MediaWorkbenchRecoveryAuthority(
    private val hostProvider: () -> CreativeHostController,
) : WorkbenchRecoveryAuthority {
    private val authority get() = hostProvider().r2Authority

    override suspend fun resolveRecoveryRoot(
        context: CreativeProjectContext,
    ): RecoveryRootDecision = try {
        authority.resolveProjectMediaRoot(context).toPlatformGrant()
    } catch (cancelled: kotlinx.coroutines.CancellationException) {
        throw cancelled
    } catch (error: CreativeException) {
        RecoveryRootDecision.Refused(error.code, error.reason ?: error.code, error.retryable)
    } catch (_: Throwable) {
        RecoveryRootDecision.Refused(
            "rendererUnavailable", "recoveryAuthorityUnavailable", retryable = true)
    }
}

/**
 * Native lifecycle pin/release for direct playback, export and preview.
 *
 * Native `pinMediaLifecycle` requires an attempt prepared by
 * `prepareRenderBinding`; it pins that EXACT lease (never a caller root/lease
 * echo). The echo is verified here before it reaches the platform, and a
 * mismatched pin is released so it cannot leak ownership.
 */
internal class MediaWorkbenchLifecycleAuthority(
    private val hostProvider: () -> CreativeHostController,
) : WorkbenchMediaLifecycleAuthority {
    private val authority get() = hostProvider().r2Authority

    override suspend fun pin(request: MediaLifecyclePinRequest): MediaLifecyclePinDecision {
        val pin = try {
            authority.pinMediaLifecycle(
                context = request.context,
                kind = request.kind.wire,
                epoch = request.epoch,
                mediaRootPath = request.mediaRootPath,
                attemptID = request.attemptID,
                jobID = request.jobID,
            )
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (error: CreativeException) {
            return MediaLifecyclePinDecision.Refused(
                error.code, error.reason ?: error.code, error.retryable)
        } catch (_: Throwable) {
            return MediaLifecyclePinDecision.Refused(
                "rendererUnavailable", "lifecyclePinUnavailable", retryable = true)
        }
        val echoedKind = MediaLifecycleKind.entries.firstOrNull { it.wire == pin.kind }
        val echoMatches = echoedKind == request.kind &&
            pin.epoch == request.epoch &&
            pin.projectID == request.context.projectID &&
            pin.attemptID == request.attemptID &&
            pin.mediaRootPath == request.mediaRootPath
        if (!echoMatches) {
            // Never accept a mismatched pin; release the exact issued handle.
            runCatching { authority.releaseMediaLifecycle(pin.pinHandle) }
            return MediaLifecyclePinDecision.Refused(
                "invalidCoreResponse", "lifecyclePinEchoMismatch", retryable = false)
        }
        return MediaLifecyclePinDecision.Pinned(
            MediaLifecyclePin(
                pinToken = pin.pinHandle,
                epoch = pin.epoch,
                mediaRootPath = pin.mediaRootPath,
                projectID = pin.projectID,
                kind = echoedKind ?: request.kind,
                attemptID = pin.attemptID,
            ),
        )
    }

    override suspend fun release(pin: MediaLifecyclePin): Boolean =
        authority.releaseMediaLifecycle(pin.pinToken)
}

internal fun MediaExportBinding.toPrepared(): R2PreparedRenderBinding =
    R2PreparedRenderBinding(
        context = context,
        mediaRootPath = mediaRootPath,
        projectRevision = projectRevision,
        timelineDigest = timelineDigest,
        attemptID = attemptID,
        snapshot = snapshot,
    )

internal fun R2PreparedRenderBinding.toExportBinding(): MediaExportBinding =
    MediaExportBinding(
        context = context,
        mediaRootPath = mediaRootPath,
        projectRevision = projectRevision,
        timelineDigest = timelineDigest,
        attemptID = attemptID,
        snapshot = snapshot,
    )

internal fun R2AuthorityDecision.toPlatform(): AuthorityDecision {
    val value = grant
    return if (accepted && value != null) {
        AuthorityDecision.Accepted(
            AuthorityGrant(
                epoch = value.epoch,
                mediaRootPath = value.mediaRootPath,
                projectID = value.projectID,
                revision = value.revision,
                timelineDigest = value.timelineDigest,
            ),
        )
    } else {
        AuthorityDecision.Refused(
            code = code ?: "authorityRefused",
            reason = reason ?: code ?: "authorityRefused",
            retryable = retryable,
        )
    }
}

internal fun R2ProjectMediaRoot.toPlatformGrant(): RecoveryRootDecision {
    if (epoch <= 0L || mediaRootPath.isBlank() || projectID.isBlank() ||
        storageKey.isBlank() || ownerProof.isBlank()
    ) {
        return RecoveryRootDecision.Refused(
            "invalidCoreResponse", "incompleteRecoveryGrant", retryable = false)
    }
    return RecoveryRootDecision.Accepted(
        RecoveryOwnerGrant(
            epoch = epoch,
            mediaRootPath = mediaRootPath,
            projectID = projectID,
            storageKey = storageKey,
            ownerKey = ownerProof,
            originKey = originKey,
        ),
    )
}
