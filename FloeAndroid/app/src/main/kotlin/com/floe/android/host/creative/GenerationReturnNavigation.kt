// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The REAL project context captured from the accepted R2 generation request.
 *
 * It is copied from `CreativeProjectContext.storage/origin` that the editor
 * actually submitted with. It is never reconstructed from a project summary,
 * a recorded task path, a cloud job row or the notification Intent.
 */
data class GenerationReturnContext(
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext?,
)

/**
 * Exact registered claim + project context a notification token resolves to.
 *
 * [token] is the opaque return token minted by the foreground owner. The
 * Intent never carries [projectID], a root or a path; this object is produced
 * only after the process-local registered claim and the live native epoch
 * agree.
 */
data class GenerationReturnTarget(
    val token: String,
    val jobID: String,
    val epoch: Long,
    val projectID: String,
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext?,
)

/** Read-only projection of one live foreground claim for authorization. */
data class GenerationReturnClaimSnapshot(
    val token: String,
    val jobID: String,
    val epoch: Long,
    val projectID: String,
    val registered: Boolean,
    val storage: CreativeStorageLayer?,
    val origin: CreativeOriginContext?,
    val startedAtElapsedMillis: Long,
)

enum class GenerationReturnRejection {
    /** The Intent/token shape is not our opaque same-app identity. */
    INVALID_REQUEST,

    /** No live claim owns the token (cold process/stale token). */
    UNKNOWN_TOKEN,

    /** The resolved claim does not equal the requested opaque token. */
    TOKEN_MISMATCH,

    /** The service-start claim exists but the native foreground lease did not. */
    NOT_REGISTERED,

    /** No exact accepted project context was captured for this claim. */
    NO_CONTEXT,

    /** The bounded claim lifetime (same 6 h cap as the dataSync owner) elapsed. */
    EXPIRED,

    /** The live creative host/root is not available right now. */
    HOST_UNAVAILABLE,

    /** The claim's accepted generation epoch is not the current bound epoch. */
    EPOCH_MISMATCH,
}

sealed interface GenerationReturnDecision {
    data class Authorized(val target: GenerationReturnTarget) :
        GenerationReturnDecision

    data class Rejected(val reason: GenerationReturnRejection) :
        GenerationReturnDecision
}

/**
 * Pure return-authorization policy. Every authority input is explicit so the
 * same bytes can be pinned by a JVM test and by the production owner:
 *
 *  * the token must be the opaque canonical UUID minted by this App;
 *  * the claim must be the exact one resolved by that token and REGISTERED by
 *    a real native foreground lease;
 *  * the captured storage must be explicit and the origin valid;
 *  * the claim must not have exceeded the bounded foreground lifetime;
 *  * the creative host must be available and the claim's accepted epoch must
 *    equal the CURRENT native bound epoch.
 *
 * A registered service-start-only claim (no native lease) or an unregistered
 * claim is never navigation authority.
 */
internal fun authorizeGenerationReturn(
    requestToken: String?,
    claim: GenerationReturnClaimSnapshot?,
    nowElapsedMillis: Long,
    liveEpoch: Long?,
    availability: CreativeAvailability,
    claimTtlMillis: Long = GenerationReturnNavigation.CLAIM_TTL_MILLIS,
): GenerationReturnDecision {
    if (!isOpaqueGenerationToken(requestToken)) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.INVALID_REQUEST)
    }
    if (claim == null) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.UNKNOWN_TOKEN)
    }
    if (claim.token != requestToken) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.TOKEN_MISMATCH)
    }
    if (!isOpaqueGenerationToken(claim.jobID) ||
        !isOpaqueGenerationToken(claim.projectID) ||
        claim.epoch <= 0L ||
        claim.startedAtElapsedMillis <= 0L
    ) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.INVALID_REQUEST)
    }
    if (!claim.registered) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.NOT_REGISTERED)
    }
    val storage = claim.storage
        ?: return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.NO_CONTEXT)
    if (!isExplicitReturnStorage(storage)) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.NO_CONTEXT)
    }
    val origin = claim.origin
    if (origin != null && !origin.isValid()) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.INVALID_REQUEST)
    }
    if (claimTtlMillis <= 0L ||
        nowElapsedMillis - claim.startedAtElapsedMillis > claimTtlMillis
    ) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.EXPIRED)
    }
    if (availability != CreativeAvailability.Available) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.HOST_UNAVAILABLE)
    }
    // A missing or different live epoch would retarget the same project into
    // another accepted root. There is no first-project or same-id fallback.
    if (liveEpoch == null || liveEpoch <= 0L || liveEpoch != claim.epoch) {
        return GenerationReturnDecision.Rejected(
            GenerationReturnRejection.EPOCH_MISMATCH)
    }
    return GenerationReturnDecision.Authorized(
        GenerationReturnTarget(
            token = claim.token,
            jobID = claim.jobID,
            epoch = claim.epoch,
            projectID = claim.projectID,
            storage = storage,
            origin = origin,
        ),
    )
}

/** True only for an explicit storage layer; never a nil/inferred root. */
internal fun isExplicitReturnStorage(storage: CreativeStorageLayer?): Boolean =
    when (storage) {
        null -> false
        is CreativeStorageLayer.AppOwned -> true
        is CreativeStorageLayer.Workspace ->
            storage.workspaceID.isNotBlank() && storage.workspaceID.length <= 128
    }

/**
 * The notification identity is an OPAQUE canonical UUID minted in-process.
 * A path, project id from an Intent extra, root name or arbitrary string is
 * never accepted here.
 */
internal fun isOpaqueGenerationToken(value: String?): Boolean {
    if (value == null || value.length != 36) return false
    val parsed = runCatching { UUID.fromString(value) }.getOrNull() ?: return false
    return parsed.toString() == value
}

/**
 * Process-scoped one-shot return request bridge.
 *
 * The notification PendingIntent carries only two opaque UUIDs (return token +
 * request id) and the explicit same-app activity component. [submitFromIntent]
 * rejects any other action/component/shape. The shell resolves the token
 * against the live claim/epoch and only then calls [approve]; a refused
 * temporary-chat fence calls [dismiss] and therefore publishes nothing, so it
 * can never route, open or claim success.
 *
 * [approved] is retained across Activity recreation until the Creative
 * destination actually dispatches the open. A re-delivery of the SAME request
 * id (rotation/cold Activity recreation) is ignored once resolved, so no
 * second editor is opened. A genuinely new notification tap mints a new
 * request id and may reopen the still-live project.
 */
object GenerationReturnNavigation {
    const val ACTION_RETURN =
        "com.floe.android.host.creative.GENERATION_RETURN"
    const val EXTRA_RETURN_TOKEN =
        "com.floe.android.host.creative.GENERATION_RETURN_TOKEN"
    const val EXTRA_RETURN_REQUEST_ID =
        "com.floe.android.host.creative.GENERATION_RETURN_REQUEST_ID"

    /** Same bounded lifetime as the Android 15+ dataSync foreground owner. */
    const val CLAIM_TTL_MILLIS: Long = 6L * 60L * 60L * 1000L
    private const val MAX_HANDLED_REQUESTS = 32

    enum class Source { GENERATION, EXPORT }
    data class PendingRequest(val requestID: String, val token: String, val source: Source = Source.GENERATION)

    data class ApprovedRequest(
        val requestID: String,
        val targetSource: Source = Source.GENERATION,
        val sequence: Long,
        val target: GenerationReturnTarget,
    )

    private val pendingFlow = MutableStateFlow<PendingRequest?>(null)
    val pending: StateFlow<PendingRequest?> = pendingFlow.asStateFlow()

    private val approvedFlow = MutableStateFlow<ApprovedRequest?>(null)
    val approved: StateFlow<ApprovedRequest?> = approvedFlow.asStateFlow()

    private val lock = Any()
    private var nextSequence = 0L
    private val handled = LinkedHashSet<String>()

    /**
     * MainActivity-side admission. The action and explicit same-app component
     * are part of the private PendingIntent contract; arbitrary launch intents
     * (launcher, external links, other activities) cannot inject a return.
     */
    fun submitFromIntent(
        action: String?,
        componentPackage: String?,
        ownPackage: String,
        requestID: String?,
        token: String?,
    ): Boolean {
        if (action != ACTION_RETURN) return false
        if (componentPackage.isNullOrEmpty() || componentPackage != ownPackage) {
            return false
        }
        return submit(requestID, token)
    }

    fun submitExportFromIntent(action: String?, componentPackage: String?, ownPackage: String,
        requestID: String?, token: String?): Boolean {
        if (action != com.floe.android.core.workbenchmedia.export.MediaExportReturns.ACTION ||
            componentPackage.isNullOrEmpty() || componentPackage != ownPackage) return false
        return submit(requestID, token, Source.EXPORT)
    }

    /**
     * Records one opaque return request. Duplicate delivery of the same
     * request id is a no-op (rotation/Activity recreation). A genuinely newer
     * request id supersedes an unconsumed older request.
     */
    fun submit(requestID: String?, token: String?, source: Source = Source.GENERATION): Boolean {
        val id = requestID?.takeIf { isOpaqueGenerationToken(it) } ?: return false
        val opaque = token?.takeIf { isOpaqueGenerationToken(it) } ?: return false
        synchronized(lock) {
            if (handled.contains(id)) return false
            val current = pendingFlow.value
            if (current != null && current.requestID == id) return false
            if (current != null) markHandled(current.requestID)
            // A genuinely newer tap also supersedes a previous approval that
            // has not been consumed yet, so an older project cannot open
            // after this newer explicit action.
            approvedFlow.value = null
            pendingFlow.value = PendingRequest(id, opaque, source)
            return true
        }
    }

    /**
     * Refusal path (stale token, mismatched epoch, unavailable host or a
     * refused temporary-chat fence). Marks the request handled so a rotation
     * cannot resurrect it. No approval is published.
     */
    fun dismiss(requestID: String): Boolean {
        synchronized(lock) {
            val current = pendingFlow.value ?: return false
            if (current.requestID != requestID) return false
            pendingFlow.value = null
            markHandled(requestID)
            return true
        }
    }

    /**
     * Publishes the one-shot open ONLY after the existing route/fence admitted
     * and committed. The requested pending token must equal the authorized
     * target token, so a late/stale resolution can never replace a newer tap.
     */
    fun approve(
        requestID: String,
        target: GenerationReturnTarget,
    ): Boolean {
        synchronized(lock) {
            val current = pendingFlow.value ?: return false
            if (current.requestID != requestID) return false
            if (current.token != target.token) return false
            pendingFlow.value = null
            markHandled(requestID)
            approvedFlow.value = ApprovedRequest(
                requestID = requestID,
                targetSource = current.source,
                sequence = ++nextSequence,
                target = target,
            )
            return true
        }
    }

    /** Consumes the approved request exactly once (Creative destination). */
    fun consumeApproved(requestID: String): Boolean {
        synchronized(lock) {
            val current = approvedFlow.value ?: return false
            if (current.requestID != requestID) return false
            approvedFlow.value = null
            return true
        }
    }

    private fun markHandled(requestID: String) {
        handled.add(requestID)
        while (handled.size > MAX_HANDLED_REQUESTS) {
            val iterator = handled.iterator()
            if (!iterator.hasNext()) return
            iterator.next()
            iterator.remove()
        }
    }

    internal fun resetForTest() {
        synchronized(lock) {
            pendingFlow.value = null
            approvedFlow.value = null
            handled.clear()
            nextSequence = 0L
        }
    }
}
