// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.feature.canvas.CreativeBinding
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignAdoptMode
import com.floe.android.feature.canvas.DesignAdoptRequest
import com.floe.android.feature.canvas.DesignBriefModel
import com.floe.android.feature.canvas.DesignBriefRequest
import com.floe.android.feature.canvas.DesignBindRequest
import com.floe.android.feature.canvas.DesignCandidateModel
import com.floe.android.feature.canvas.DesignCandidateStatus
import com.floe.android.feature.canvas.DesignCompareRequest
import com.floe.android.feature.canvas.DesignComparison
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignDecisionReceipt
import com.floe.android.feature.canvas.DesignDecisionResult
import com.floe.android.feature.canvas.DesignDelivery
import com.floe.android.feature.canvas.DesignDeliveryState
import com.floe.android.feature.canvas.DesignExportReceipt
import com.floe.android.feature.canvas.DesignExportRequest
import com.floe.android.feature.canvas.DesignFreezeReceipt
import com.floe.android.feature.canvas.DesignFreezeRequest
import com.floe.android.feature.canvas.DesignFrozenRunModel
import com.floe.android.feature.canvas.DesignHostApi
import com.floe.android.feature.canvas.DesignHostStatus
import com.floe.android.feature.canvas.DesignProposalRequest
import com.floe.android.feature.canvas.DesignProposalResult
import com.floe.android.feature.canvas.DesignPublication
import com.floe.android.feature.canvas.DesignPublicationState
import com.floe.android.feature.canvas.DesignPreviewReceipt
import com.floe.android.feature.canvas.DesignPreviewRequest
import com.floe.android.feature.canvas.DesignProjectProjection
import com.floe.android.feature.canvas.DesignRejectRequest
import com.floe.android.feature.canvas.DesignRestoreRequest
import com.floe.android.feature.canvas.DesignSpecModel
import com.floe.android.feature.canvas.DesignSpecRequest
import com.floe.android.feature.canvas.DesignStateProjection
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.DesignTargetIdentity
import com.floe.android.feature.canvas.DesignTargetKind
import com.floe.android.feature.canvas.DesignWireLimits
import com.floe.android.feature.canvas.DesignWorkMode
import com.floe.android.feature.canvas.StagedDesignPayload
import java.io.File
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Pure, locked staging-slot/fence ledger for the design proposal payload
 * transport. It owns NO Android/SAF types; the host owns the actual input
 * stream, worker job and file. This is the testable lifecycle state machine:
 *
 *  * a slot is reserved before any IO, bounded by `maximumSlots` across both
 *    active copies and completed staged files;
 *  * a fence increments the generation, marks every active copy cancelled and
 *    returns the REAL worker slots for cancel/close/join;
 *  * publication requires an unchanged generation, an unfenced ledger, no
 *    per-token cancel and the exact live accepted epoch/root.
 *
 * A cancelled Job flag alone is never authority; the host only reports drained
 * after the real workers joined.
 */
internal class CreativeDesignStagingLedger(
    private val maximumSlots: Int,
) {
    internal data class Slot(
        val token: String,
        val generation: Long,
        val acceptedEpoch: Long,
        val acceptedRootPath: String,
        val target: File,
        var job: Job? = null,
        var input: InputStream? = null,
        var cancelled: Boolean = false,
    )

    private val lock = Any()
    private val slots = LinkedHashMap<String, Slot>()
    private var fenced = false
    private var generation = 0L

    fun begin(
        token: String,
        accepted: CreativeAcceptedRoot,
        target: File,
        stagedCount: Int,
    ): Long? = synchronized(lock) {
        if (fenced || slots.size + stagedCount >= maximumSlots) return null
        slots[token] = Slot(
            token = token,
            generation = generation,
            acceptedEpoch = accepted.epoch,
            acceptedRootPath = accepted.path,
            target = target)
        generation
    }

    fun attach(token: String, job: Job?, input: InputStream): Boolean =
        synchronized(lock) {
            val slot = slots[token] ?: return false
            if (fenced || slot.generation != generation || slot.cancelled) {
                return false
            }
            slot.job = job
            slot.input = input
            true
        }

    fun isCancelled(token: String, generation: Long): Boolean =
        synchronized(lock) {
            val slot = slots[token]
            fenced || slot == null || slot.generation != generation || slot.cancelled
        }

    fun canPublish(
        token: String,
        generation: Long,
        liveEpoch: Long?,
        liveRootPath: String?,
    ): Boolean = synchronized(lock) {
        val slot = slots[token] ?: return false
        !fenced &&
            slot.generation == generation &&
            !slot.cancelled &&
            liveEpoch == slot.acceptedEpoch &&
            liveRootPath == slot.acceptedRootPath
    }

    /**
     * Atomic publication gate. Verifies the SAME live accepted root/epoch and
     * an unfenced/uncancelled slot, removes the slot and runs [register] while
     * holding the ledger lock, so a concurrent fence/cancel cannot interleave
     * between the proof and the file registration. False publishes nothing.
     */
    fun publish(
        token: String,
        generation: Long,
        liveEpoch: Long?,
        liveRootPath: String?,
        register: () -> Unit,
    ): Boolean = synchronized(lock) {
        val slot = slots[token] ?: return false
        if (fenced ||
            slot.generation != generation ||
            slot.cancelled ||
            liveEpoch != slot.acceptedEpoch ||
            liveRootPath != slot.acceptedRootPath
        ) {
            return false
        }
        slots.remove(token)
        register()
        true
    }

    fun publish(token: String) {
        synchronized(lock) { slots.remove(token) }
    }

    fun finish(token: String) {
        synchronized(lock) { slots.remove(token) }
    }

    fun cancel(token: String): Slot? = synchronized(lock) {
        val slot = slots.remove(token) ?: return null
        slot.cancelled = true
        slot
    }

    fun fence(): List<Slot> = synchronized(lock) {
        fenced = true
        generation += 1
        val active = slots.values.toList()
        active.forEach { it.cancelled = true }
        active
    }

    fun unfence() {
        synchronized(lock) { fenced = false }
    }

    fun active(): List<Slot> = synchronized(lock) { slots.values.toList() }

    fun activeCount(): Int = synchronized(lock) { slots.size }
}

/**
 * Production App adapter for the frozen [DesignHostApi].
 *
 * Every call uses the existing `floe_bridge_exchange` C ABI as
 * `floe.creative/6`; the native design service owns the workflow, owner CAS,
 * Canvas CAS and file receipts. Kotlin never persists a design project, never
 * accepts a caller path as authority and never labels a JSON snapshot as an
 * image.
 *
 * The native `bindTarget`/`state` actions are read actions with optional bind
 * fields (the closed action vocabulary has no separate `design.bind`). The
 * App stages proposal bytes under the accepted root via [stagePayload]; the
 * opaque token is the only payload argument.
 */
class CreativeR2DesignHost(
    context: Context,
    private val acceptedRootProvider: () -> CreativeAcceptedRoot?,
    private val epochProvider: () -> Long?,
    designAuthorityIssuer: DesignAuthorityIssuer? = null,
    private val transport: CreativeTransport = SwiftCreativeTransport,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : DesignHostApi {
    /**
     * Typed trusted UI callback for RESTRUCTURE preservation confirmation.
     * The App must show [DesignTrustedApprovalController.prepare]'s returned
     * target/base/digest/constraints and call confirm only on an explicit user
     * action. It is not part of the frozen DesignHostApi.
     */
    val trustedApprovals = DesignTrustedApprovalController(
        acceptedRootProvider = acceptedRootProvider,
        epochProvider = epochProvider,
        issuer = designAuthorityIssuer,
        ioDispatcher = ioDispatcher)
    private val exchangeMutex = Mutex()
    private val resolver: ContentResolver =
        context.applicationContext.contentResolver
    private val pump = CreativeSourcePump(ioDispatcher)
    private val staged = ConcurrentHashMap<String, File>()
    private val discardedStaging = mutableSetOf<String>()

    /**
     * Root-owned staging lifecycle. A slot is RESERVED before any SAF/IO work;
     * the actual input stream and worker are tracked until their finally block
     * closes; Root stop cancels/closes, joins the real copy, and only then may
     * the native aggregate claim the Root is drained. A post-copy re-proof of
     * the exact accepted root/epoch prevents a copy that crossed a Root
     * replacement from publishing into a new generation.
     */
    private val staging = CreativeDesignStagingLedger(MAX_STAGED)

    override suspend fun bind(epoch: Long): CreativeBinding = withContext(ioDispatcher) {
        if (epoch <= 0L) throw CreativeException("invalidRequest", "missingEpoch")
        // A new accepted generation may stage again. The generation counter
        // still invalidates copies started under an older fence.
        staging.unfence()
        val response = exchange(
            R2MediaWire.request(
                operation = "bind",
                requestID = CreativeWire.newRequestID(),
                epoch = epoch).toString())
        CreativeBinding(
            epoch = response.long("epoch") ?: epoch,
            bound = response.bool("bound") ?: false,
            rootFingerprint = response.string("rootFingerprint"))
    }

    override suspend fun status(): DesignHostStatus = withContext(ioDispatcher) {
        val response = exchange(
            R2MediaWire.request(
                operation = "status",
                requestID = CreativeWire.newRequestID()).toString())
        val design = response.objectValue("design")
            ?: throw CreativeException("needsCoreUpdate", "designStatusMissing")
        DesignHostStatus(
            bound = design.bool("bound") ?: false,
            epoch = design.long("epoch"),
            rootFingerprint = design.string("rootFingerprint"),
            availableTargetKinds = design.strings("availableTargetKinds"),
            targetKindReasons = design.objectValue("targetKindReasons")
                ?.entries
                ?.mapNotNull { (key, value) ->
                    (value as? JsonPrimitive)?.content?.let { key to it }
                }
                ?.toMap()
                .orEmpty(),
            availableActions = design.strings("availableActions"),
            maxProposalBytes = design.long("maxProposalBytes")
                ?: DesignWireLimits.MAX_DESIGN_SOURCE_BYTES,
            maxPreviewBytes = design.int("maxPreviewBytes")
                ?: DesignWireLimits.MAX_PREVIEW_BYTES)
    }

    override suspend fun state(binding: DesignTargetBinding): DesignStateProjection =
        withContext(ioDispatcher) {
            val response = command(
                stateAction(binding),
                buildJsonObject { put("binding", encodeBinding(binding)) })
            decodeState(response)
        }

    override suspend fun bindTarget(request: DesignBindRequest): DesignStateProjection =
        withContext(ioDispatcher) {
            requireOperation(request.opID)
            val payload = buildJsonObject {
                put("binding", encodeBinding(request.binding))
                request.expectedRevision?.let { put("expectedRevision", it) }
                put("opID", request.opID)
            }
            decodeState(command(stateAction(request.binding), payload))
        }

    override suspend fun setBrief(request: DesignBriefRequest): DesignStateProjection =
        withContext(ioDispatcher) {
            requireOperation(request.opID)
            if (isCanvas(request.binding)) {
                val response = command("design.canvas.mutate", buildJsonObject {
                    put("kind", "brief")
                    put("brief", encodeBriefRequest(request))
                })
                decodeState(response)
            } else {
                decodeState(command("design.owner.brief", encodeBriefRequest(request)))
            }
        }

    override suspend fun setSpec(request: DesignSpecRequest): DesignStateProjection =
        withContext(ioDispatcher) {
            requireOperation(request.opID)
            if (isCanvas(request.binding)) {
                val response = command("design.canvas.mutate", buildJsonObject {
                    put("kind", "spec")
                    put("spec", encodeSpecRequest(request))
                })
                decodeState(response)
            } else {
                decodeState(command("design.owner.spec", encodeSpecRequest(request)))
            }
        }

    override suspend fun freeze(request: DesignFreezeRequest): DesignFreezeReceipt =
        withContext(ioDispatcher) {
            requireOperation(request.opID)
            val response = if (isCanvas(request.binding)) {
                command("design.canvas.mutate", buildJsonObject {
                    put("kind", "freeze")
                    put("freeze", encodeFreezeRequest(request))
                })
            } else {
                command("design.owner.freeze", encodeFreezeRequest(request))
            }
            decodeFreezeReceipt(response, request.opID)
        }

    override suspend fun propose(request: DesignProposalRequest): DesignProposalResult =
        withContext(ioDispatcher) {
            requireOperation(request.opID)
            val response = if (isCanvas(request.binding)) {
                command("design.canvas.mutate", buildJsonObject {
                    put("kind", "propose")
                    put("propose", encodeProposeRequest(request))
                })
            } else {
                command("design.owner.propose", encodeProposeRequest(request))
            }
            decodeProposalResult(response)
        }

    override suspend fun adopt(request: DesignAdoptRequest): DesignDecisionResult =
        withContext(ioDispatcher) {
            requireOperation(request.opID)
            decodeDecisionResult(
                command(adoptAction(request.binding), encodeAdoptRequest(request)))
        }

    override suspend fun reject(request: DesignRejectRequest): DesignDecisionReceipt =
        withContext(ioDispatcher) {
            requireOperation(request.opID)
            val response = if (isCanvas(request.binding)) {
                command("design.canvas.mutate", buildJsonObject {
                    put("kind", "reject")
                    put("reject", encodeRejectRequest(request))
                })
            } else {
                command("design.owner.reject", encodeRejectRequest(request))
            }
            decodeDecisionReceipt(response)
        }

    override suspend fun compare(request: DesignCompareRequest): DesignComparison =
        withContext(ioDispatcher) {
            decodeComparison(
                command(compareAction(request.binding), encodeCompareRequest(request)))
        }

    override suspend fun restore(request: DesignRestoreRequest): DesignStateProjection =
        withContext(ioDispatcher) {
            requireOperation(request.opID)
            decodeState(
                command(restoreAction(request.binding), encodeRestoreRequest(request)))
        }

    override suspend fun preview(request: DesignPreviewRequest): DesignPreviewReceipt =
        withContext(ioDispatcher) {
            decodePreviewReceipt(
                command(previewAction(request.binding), encodePreviewRequest(request)))
        }

    override suspend fun export(request: DesignExportRequest): DesignExportReceipt =
        withContext(ioDispatcher) {
            decodeExportReceipt(
                command(exportAction(request.binding), encodeExportRequest(request)))
        }

    // MARK: - Creative owner (host-only extension over the same closed action)

    /**
     * Persist a creative START request (explicit requested output kind +
     * brief/spec) in the SAME owner envelope before any material exists. The
     * target must first be bound through [bindTarget] so the exact editor
     * session is registered; no canvas/workspace/project is created.
     */
    suspend fun beginCreative(
        binding: DesignTargetBinding,
        expectedRevision: Long?,
        opID: String,
        brief: DesignBriefModel? = null,
        spec: DesignSpecModel? = null,
    ): DesignStateProjection = withContext(ioDispatcher) {
        requireOperation(opID)
        requireCreative(binding)
        val payload = buildJsonObject {
            put("binding", encodeBinding(binding))
            expectedRevision?.let { put("expectedRevision", it) }
            put("opID", opID)
            putJsonObject("creative") {
                put("kind", "begin")
                if (brief != null || spec != null) {
                    putJsonObject("begin") {
                        brief?.let { put("brief", encodeBrief(it)) }
                        spec?.let { put("spec", encodeSpec(it)) }
                    }
                }
            }
        }
        decodeState(command("design.owner.state", payload))
    }

    /**
     * Bind the FIRST real creative result. [payload] must contain the retained
     * asset's actual bytes (staged through [stagePayload]); native verifies the
     * bytes/format against the asset row and the durable run/job link before
     * any envelope revision is written.
     */
    suspend fun bindCreativeFirstResult(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        boundResultID: String,
        payload: StagedDesignPayload,
        displayName: String? = null,
    ): DesignStateProjection = withContext(ioDispatcher) {
        requireOperation(opID)
        requireCreative(binding)
        if (boundResultID.isBlank()) {
            throw CreativeException("invalidRequest", "missingBoundResultID")
        }
        val request = buildJsonObject {
            put("binding", encodeBinding(binding))
            put("expectedRevision", expectedRevision)
            put("opID", opID)
            putJsonObject("creative") {
                put("kind", "bind")
                putJsonObject("bind") {
                    put("boundResultID", boundResultID)
                    putJsonObject("payload") {
                        put("token", payload.token)
                        put("format", payload.format)
                        put("byteCount", payload.byteCount)
                        put("sha256", payload.sha256)
                    }
                    displayName?.let { put("displayName", it) }
                }
            }
        }
        decodeState(command("design.owner.state", request))
    }

    // MARK: - Creative first-material selection (App, bounded)

    /**
     * Bounded metadata page over the EXISTING creative asset library. No byte
     * body and no path crosses the bridge; the selected [CreativeDesignAsset]
     * can be bound directly (native reads its verified bytes).
     */
    suspend fun creativeAssets(
        cursor: String? = null,
        limit: Int = 24,
    ): CreativeDesignAssetPage = withContext(ioDispatcher) {
        val request = buildJsonObject {
            putJsonObject("creative") {
                put("kind", "assets")
                putJsonObject("assets") {
                    cursor?.let { put("cursor", it) }
                    put("limit", pageLimit(limit))
                }
            }
        }
        decodeCreativeAssetPage(command("design.owner.state", request))
    }

    /**
     * Bounded reopen list over the SAME owner envelope store. The returned
     * [CreativeDesignPendingRequest.target] is the exact frozen identity; reopen
     * with bindTarget + [CreativeStorageLayer.AppOwned] + a fresh session.
     */
    suspend fun creativePendingRequests(
        cursor: String? = null,
        limit: Int = 24,
    ): CreativeDesignPendingPage = withContext(ioDispatcher) {
        val request = buildJsonObject {
            putJsonObject("creative") {
                put("kind", "pending")
                putJsonObject("pending") {
                    cursor?.let { put("cursor", it) }
                    put("limit", pageLimit(limit))
                }
            }
        }
        decodeCreativePendingPage(command("design.owner.state", request))
    }

    /**
     * Bind an EXISTING retained asset as the first result. The host supplies
     * only its real asset id; native verifies the contained bytes (size cap
     * first, digest against the canonical row) and then runs the same shared
     * first-result transaction. No payload token or SAF copy is involved.
     */
    suspend fun bindCreativeRetainedFirstResult(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        boundResultID: String,
        displayName: String? = null,
    ): DesignStateProjection = withContext(ioDispatcher) {
        requireOperation(opID)
        requireCreative(binding)
        if (boundResultID.isBlank()) {
            throw CreativeException("invalidRequest", "missingBoundResultID")
        }
        val request = buildJsonObject {
            put("binding", encodeBinding(binding))
            put("expectedRevision", expectedRevision)
            put("opID", opID)
            putJsonObject("creative") {
                put("kind", "bindRetained")
                putJsonObject("bindRetained") {
                    put("boundResultID", boundResultID)
                    displayName?.let { put("displayName", it) }
                }
            }
        }
        decodeState(command("design.owner.state", request))
    }

    /**
     * Import a staged SAF/manual first material into the EXISTING creative asset
     * library, then bind the resulting canonical asset. The staged token is
     * released only after a committed bind; on failure it stays available for a
     * retry with the same payload (or an explicit [discardPayload]).
     */
    suspend fun importCreativeFirstResult(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        payload: StagedDesignPayload,
        displayName: String? = null,
    ): CreativeDesignImportReceipt = withContext(ioDispatcher) {
        requireOperation(opID)
        requireCreative(binding)
        val request = buildJsonObject {
            put("binding", encodeBinding(binding))
            put("expectedRevision", expectedRevision)
            put("opID", opID)
            putJsonObject("creative") {
                put("kind", "importBind")
                putJsonObject("importBind") {
                    putJsonObject("payload") {
                        put("token", payload.token)
                        put("format", payload.format)
                        put("byteCount", payload.byteCount)
                        put("sha256", payload.sha256)
                    }
                    displayName?.let { put("displayName", it) }
                }
            }
        }
        val receipt = decodeCreativeImportReceipt(
            command("design.owner.state", request))
        // Native discarded the staged file on the committed bind. Release the
        // host slot without deleting a file it no longer owns.
        releaseStagedToken(payload.token)
        receipt
    }

    private fun releaseStagedToken(token: String) {
        staging.publish(token)
        synchronized(staged) { staged.remove(token) }
    }

    private fun pageLimit(value: Int): Int =
        value.coerceIn(1, MAX_CREATIVE_PAGE)

    // MARK: - Explicit App staging seam (proposal bytes only)

    /**
     * Stage one proposal payload under the accepted root. The token is opaque
     * and is the ONLY payload argument accepted by the bridge. Native consumes
     * it on a successful proposal; [discardPayload] is for an explicit UI
     * cancel/failure. The native design host never accepts a caller path.
     */
    suspend fun stagePayload(
        source: Uri,
        sessionToken: String,
    ): StagedDesignPayload = withContext(ioDispatcher) {
        CreativeOwnership.requireSessionToken(sessionToken)
        val accepted = CreativeOwnership.requireLive(
            acceptedRootProvider(), epochProvider())
        val token = CreativeOwnership.newStagingToken(sessionToken)
        val target = CreativeOwnership.stagingFile(accepted, token)
        val generation = staging.begin(
            token, accepted, target, stagedCount = staged.size)
            ?: throw stagingRefusal()
        var input: InputStream? = null
        try {
            val resolved = resolveSource(source)
            val opened = try {
                resolver.openInputStream(source)
            } catch (_: Throwable) {
                null
            } ?: throw CreativeException(
                "assetStagingUnavailable", "sourceUnreadable", retryable = true)
            input = opened
            val job = currentCoroutineContext()[Job]
            if (!staging.attach(token, job, opened)) {
                throw CreativeException(
                    "staleGeneration", "designStagingFenced", retryable = true)
            }
            val bytes = try {
                pump.stage(
                    opened, target, DesignWireLimits.MAX_DESIGN_SOURCE_BYTES,
                    isCancelled = { staging.isCancelled(token, generation) })
            } finally {
                runCatching { input?.close() }
            }
            val liveRoot = acceptedRootProvider()
            val liveEpoch = epochProvider()
            val published = staging.publish(
                token, generation,
                liveEpoch = liveEpoch,
                liveRootPath = liveRoot?.path
            ) {
                synchronized(staged) {
                    if (discardedStaging.remove(token)) {
                        target.delete()
                        throw CreativeException(
                            "staleGeneration", "designStagingCancelled",
                            retryable = true)
                    }
                    staged[token] = target
                }
            }
            if (!published) {
                target.delete()
                throw CreativeException(
                    "staleGeneration", "designStagingOwnerChanged",
                    retryable = true)
            }
            StagedDesignPayload(
                token = token,
                format = formatFor(resolved.first, resolved.second),
                byteCount = bytes.byteCount,
                sha256 = bytes.sha256)
        } catch (error: Throwable) {
            target.delete()
            throw error
        } finally {
            runCatching { input?.close() }
            staging.finish(token)
        }
    }

    /**
     * Root order step 1: fence new staging, cancel+CLOSE the actual SAF inputs,
     * and join the real copy workers. Returns true only when no owned copy is
     * still running. A false answer keeps Root bound; it is never treated as a
     * cancelled Job flag.
     */
    suspend fun fenceStaging(): Boolean {
        val workers = staging.fence()
        for (worker in workers) {
            worker.job?.cancel()
            runCatching { worker.input?.close() }
        }
        val settled = withTimeoutOrNull(STAGING_DRAIN_MILLIS) {
            workers.mapNotNull { it.job }.joinAll()
            true
        } ?: false
        val drained = settled && staging.activeCount() == 0
        if (drained) {
            val completed = synchronized(staged) {
                val values = staged.values.toList()
                staged.clear()
                values
            }
            completed.forEach { runCatching { it.delete() } }
        }
        return drained
    }

    /** Explicit UI cancel; the worker is cancelled/closed and its file removed. */
    fun discardPayload(token: String) {
        val slot = staging.cancel(token)
        synchronized(staged) {
            discardedStaging.add(token)
            staged.remove(token)?.delete()
        }
        slot?.job?.cancel()
        runCatching { slot?.input?.close() }
        slot?.target?.delete()
    }

    /** Root-stop-owned staging cleanup after `fenceStaging` succeeded. */
    suspend fun shutdownStaging() {
        fenceStaging()
        val remaining = synchronized(staged) {
            val values = staged.values.toList()
            staged.clear()
            values
        }
        remaining.forEach { runCatching { it.delete() } }
    }

    private fun stagingRefusal(): CreativeException {
        val active = staging.activeCount()
        return if (active + staged.size >= MAX_STAGED) {
            CreativeException(
                "stagingBusy", "tooManyStagedDesignPayloads", retryable = true)
        } else {
            CreativeException(
                "staleGeneration", "designStagingFenced", retryable = true)
        }
    }

    // MARK: - Transport

    private suspend fun command(action: String, payload: JsonObject): JsonObject {
        val epoch = epochProvider()?.takeIf { it > 0L }
            ?: throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        val request = R2MediaWire.request(
            operation = "command",
            requestID = CreativeWire.newRequestID(),
            epoch = epoch,
            action = action,
            payload = payload).toString()
        if (request.toByteArray(Charsets.UTF_8).size >
            DesignWireLimits.REQUEST_BYTES) {
            throw CreativeException("requestTooLarge", "designRequestTooLarge")
        }
        return exchange(request)
    }

    private suspend fun exchange(raw: String): JsonObject = exchangeMutex.withLock {
        val response = try {
            transport.exchange(raw)
        } catch (error: CreativeException) {
            throw error
        } catch (error: Throwable) {
            throw CreativeException(
                "invalidCoreResponse", "bridgeExchangeFailed", retryable = true)
        }
        if (response.toByteArray(Charsets.UTF_8).size >
            DesignWireLimits.RESPONSE_BYTES) {
            throw CreativeException("responseTooLarge", "designResponseTooLarge")
        }
        R2MediaWire.response(response)
    }

    // MARK: - Encode

    private fun encodeState(binding: DesignTargetBinding): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(binding))
        }

    private fun encodeBinding(binding: DesignTargetBinding): JsonObject =
        buildJsonObject {
            put("target", encodeTarget(binding.target))
            put("storage", encodeStorage(binding.storage))
            binding.origin?.let { put("origin", encodeOrigin(it)) }
            put("sessionToken", binding.sessionToken)
        }

    private fun encodeTarget(target: DesignTargetIdentity): JsonObject =
        buildJsonObject {
            put("kind", target.kind.wire)
            put("ownerID", target.ownerID)
            put("documentID", target.documentID)
            put("sourceID", target.sourceID)
            target.environmentID?.let { put("environmentID", it) }
            target.revision?.let { put("revision", it) }
            target.originConversationID?.let { put("originConversationID", it) }
            target.requestedOutputKind?.let { put("requestedOutputKind", it.wire) }
        }

    private fun encodeStorage(storage: CreativeStorageLayer): JsonObject =
        buildJsonObject {
            when (storage) {
                CreativeStorageLayer.AppOwned -> put("kind", "appOwned")
                is CreativeStorageLayer.Workspace -> {
                    put("kind", "workspace")
                    put("workspaceID", storage.workspaceID)
                }
            }
        }

    private fun encodeOrigin(origin: CreativeOriginContext): JsonObject =
        buildJsonObject {
            put("kind", origin.kind)
            origin.ownerID?.let { put("ownerID", it) }
            origin.environmentID?.let { put("environmentID", it) }
        }

    private fun encodeBriefRequest(request: DesignBriefRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            put("expectedRevision", request.expectedRevision)
            put("opID", request.opID)
            put("brief", encodeBrief(request.brief))
        }

    private fun encodeSpecRequest(request: DesignSpecRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            put("expectedRevision", request.expectedRevision)
            put("opID", request.opID)
            put("spec", encodeSpec(request.spec))
        }

    private fun encodeFreezeRequest(request: DesignFreezeRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            put("expectedRevision", request.expectedRevision)
            put("opID", request.opID)
            request.inputRevisionID?.let { put("inputRevisionID", it) }
            request.specSHA256?.let { put("specSHA256", it) }
            request.targetRevisionID?.let { put("targetRevisionID", it) }
            request.desiredFormat?.let { put("desiredFormat", it) }
            request.workMode?.let { put("workMode", it.wire) }
            request.preservationDigest?.let { put("preservationDigest", it) }
        }

    private fun encodeProposeRequest(request: DesignProposalRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            put("expectedRevision", request.expectedRevision)
            put("opID", request.opID)
            put("artifactID", request.artifactID)
            request.baseRevisionID?.let { put("baseRevisionID", it) }
            putJsonObject("payload") {
                put("token", request.payload.token)
                put("format", request.payload.format)
                put("byteCount", request.payload.byteCount)
                put("sha256", request.payload.sha256)
            }
            put("summary", request.summary)
            putJsonArray("diff") {
                request.diff.forEach { add(JsonPrimitive(it)) }
            }
            putJsonArray("feedbackIDs") {
                request.feedbackIDs.forEach { add(JsonPrimitive(it)) }
            }
            request.workMode?.let { mode ->
                putJsonObject("workIntent") {
                    put("mode", mode.wire)
                    put("actualDesiredFormat",
                        request.desiredFormat ?: request.payload.format)
                    request.baseRevisionID?.let { put("frozenRevisionID", it) }
                    put("operationID", request.opID)
                }
            }
        }

    private fun encodeAdoptRequest(request: DesignAdoptRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            put("expectedRevision", request.expectedRevision)
            put("opID", request.opID)
            put("candidateID", request.candidateID)
            put("mode", request.mode.wire)
        }

    private fun encodeRejectRequest(request: DesignRejectRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            put("expectedRevision", request.expectedRevision)
            put("opID", request.opID)
            put("candidateID", request.candidateID)
            request.reason?.let { put("reason", it) }
        }

    private fun encodeCompareRequest(request: DesignCompareRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            put("candidateID", request.candidateID)
        }

    private fun encodeRestoreRequest(request: DesignRestoreRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            put("expectedRevision", request.expectedRevision)
            put("opID", request.opID)
            put("revisionID", request.revisionID)
        }

    private fun encodePreviewRequest(request: DesignPreviewRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            request.candidateID?.let { put("candidateID", it) }
            request.revisionID?.let { put("revisionID", it) }
            put("maxBytes", request.maxBytes)
        }

    private fun encodeExportRequest(request: DesignExportRequest): JsonObject =
        buildJsonObject {
            put("binding", encodeBinding(request.binding))
            request.candidateID?.let { put("candidateID", it) }
            request.revisionID?.let { put("revisionID", it) }
            put("format", request.format)
            request.suggestedFileName?.let { put("suggestedFileName", it) }
        }

    private fun encodeBrief(brief: DesignBriefModel): JsonObject =
        buildJsonObject {
            put("goal", brief.goal)
            brief.audience?.let { put("audience", it) }
            putJsonArray("constraints") {
                brief.constraints.forEach { add(JsonPrimitive(it)) }
            }
            put("createdAt", isoOrNow(brief.createdAt))
        }

    private fun encodeSpec(spec: DesignSpecModel): JsonObject =
        buildJsonObject {
            spec.palette?.let { values ->
                putJsonArray("palette") { values.forEach { add(JsonPrimitive(it)) } }
            }
            spec.typography?.let { put("typography", it) }
            spec.layout?.let { put("layout", it) }
            spec.spacing?.let { put("spacing", it) }
            spec.brandAssetRefs?.let { values ->
                putJsonArray("brandAssetRefs") { values.forEach { add(JsonPrimitive(it)) } }
            }
            spec.voice?.let { put("voice", it) }
            spec.prohibitions?.let { values ->
                putJsonArray("prohibitions") { values.forEach { add(JsonPrimitive(it)) } }
            }
            spec.rawMarkdown?.let { put("rawMarkdown", it) }
        }

    // MARK: - Decode

    private fun decodeState(value: JsonObject): DesignStateProjection {
        val envelope = value.objectValue("envelope")
            ?: throw CreativeException("invalidResponse", "missingDesignEnvelope")
        val project = envelope.objectValue("project")
            ?: throw CreativeException("invalidResponse", "missingDesignProject")
        return DesignStateProjection(
            target = decodeTarget(
                envelope.objectValue("target")
                    ?: throw CreativeException("invalidResponse", "missingDesignTarget")),
            ownerRevision = envelope.long("revision") ?: 0L,
            schemaVersion = project.int("schemaVersion") ?: 0,
            project = decodeProject(project),
            creativeFirstResultProvenance =
                envelope.objectValue("creativeFirstResultProvenance"),
            writable = value.bool("writable") ?: false,
            warnings = value.strings("warnings"),
            availableActions = value.strings("availableActions"))
    }

    private fun decodeTarget(value: JsonObject): DesignTargetIdentity {
        val kind = DesignTargetKind.entries.firstOrNull {
            it.wire == value.string("kind")
        } ?: throw CreativeException("invalidResponse", "invalidDesignTargetKind")
        return DesignTargetIdentity(
            kind = kind,
            ownerID = value.string("ownerID").orEmpty(),
            documentID = value.string("documentID").orEmpty(),
            sourceID = value.string("sourceID").orEmpty(),
            environmentID = value.string("environmentID"),
            revision = value.string("revision"),
            originConversationID = value.string("originConversationID"),
            requestedOutputKind = decodeContentType(value.string("requestedOutputKind")))
    }

    private fun decodeProject(value: JsonObject): DesignProjectProjection =
        DesignProjectProjection(
            contentType = decodeContentType(value.string("contentType"))
                ?: DesignContentType.COMPOSITION,
            brief = value.objectValue("brief")?.let(::decodeBrief),
            spec = value.objectValue("spec")?.let(::decodeSpec),
            candidates = value.array("candidates")?.mapNotNull { element ->
                (element as? JsonObject)?.let(::decodeCandidate)
            }.orEmpty(),
            frozenRun = value.objectValue("frozenRun")?.let(::decodeFrozenRun),
            creativeRequest = value.objectValue("creativeRequest"),
            appliedOperationIDs = value.strings("appliedOperationIDs"),
            createdAt = value.string("createdAt").orEmpty(),
            updatedAt = value.string("updatedAt").orEmpty(),
            rawProject = value)

    private fun decodeBrief(value: JsonObject): DesignBriefModel =
        DesignBriefModel(
            goal = value.string("goal").orEmpty(),
            audience = value.string("audience"),
            constraints = value.strings("constraints"),
            createdAt = value.string("createdAt").orEmpty())

    private fun decodeSpec(value: JsonObject): DesignSpecModel =
        DesignSpecModel(
            palette = value.stringsOrNull("palette"),
            typography = value.string("typography"),
            layout = value.string("layout"),
            spacing = value.string("spacing"),
            brandAssetRefs = value.stringsOrNull("brandAssetRefs"),
            voice = value.string("voice"),
            prohibitions = value.stringsOrNull("prohibitions"),
            rawMarkdown = value.string("rawMarkdown"))

    private fun decodeFrozenRun(value: JsonObject): DesignFrozenRunModel =
        DesignFrozenRunModel(
            operationID = value.string("operationID").orEmpty(),
            inputRevisionID = value.string("inputRevisionID"),
            specSHA256 = value.string("specSHA256"),
            targetRevisionID = value.string("targetRevisionID"),
            desiredFormat = value.string("desiredFormat"),
            workMode = decodeWorkMode(value.string("workMode")),
            preservationDigest = value.string("preservationDigest"),
            frozenAt = value.string("frozenAt").orEmpty())

    private fun decodeCandidate(value: JsonObject): DesignCandidateModel =
        DesignCandidateModel(
            id = value.string("id").orEmpty(),
            artifactID = value.string("artifactID").orEmpty(),
            baseRevisionID = value.string("baseRevisionID").orEmpty(),
            proposedRevisionID = value.string("proposedRevisionID").orEmpty(),
            feedbackIDs = value.strings("feedbackIDs"),
            summary = value.string("summary").orEmpty(),
            diff = value.strings("diff"),
            status = DesignCandidateStatus.entries.firstOrNull {
                it.wire == value.string("status")
            } ?: DesignCandidateStatus.PENDING,
            createdAt = value.string("createdAt").orEmpty(),
            resolvedAt = value.string("resolvedAt"),
            variantArtifactID = value.string("variantArtifactID"),
            originConversationID = value.string("originConversationID"),
            originEnvironmentID = value.string("originEnvironmentID"),
            proposalOperationID = value.string("proposalOperationID"),
            proposalFingerprint = value.string("proposalFingerprint"),
            workMode = decodeWorkMode(value.string("workMode")),
            preservationDigest = value.string("preservationDigest"))

    private fun decodeFreezeReceipt(
        value: JsonObject,
        requestOperationID: String,
    ): DesignFreezeReceipt = DesignFreezeReceipt(
        target = decodeTarget(
            value.objectValue("target")
                ?: throw CreativeException("invalidResponse", "missingDesignTarget")),
        ownerRevision = value.long("ownerRevision") ?: 0L,
        operationID = value.string("operationID") ?: requestOperationID,
        frozenRun = decodeFrozenRun(
            value.objectValue("frozenRun")
                ?: throw CreativeException("invalidResponse", "missingFrozenRun")),
        idempotent = value.bool("idempotent") ?: false)

    private fun decodeProposalResult(value: JsonObject): DesignProposalResult =
        DesignProposalResult(
            state = decodeState(
                value.objectValue("state")
                    ?: throw CreativeException("invalidResponse", "missingDesignState")),
            candidate = decodeCandidate(
                value.objectValue("candidate")
                    ?: throw CreativeException("invalidResponse", "missingCandidate")),
            payloadRelativePath = value.string("payloadRelativePath").orEmpty(),
            replayed = value.bool("replayed") ?: false)

    private fun decodeDecisionResult(value: JsonObject): DesignDecisionResult {
        val delivery = value.objectValue("delivery")
        val publication = value.objectValue("publication")
        return DesignDecisionResult(
            state = decodeState(
                value.objectValue("state")
                    ?: throw CreativeException("invalidResponse", "missingDesignState")),
            candidateID = value.string("candidateID").orEmpty(),
            operationID = value.string("operationID").orEmpty(),
            idempotent = value.bool("idempotent") ?: false,
            committedRevisionToken = value.string("committedRevisionToken"),
            delivery = DesignDelivery(
                state = DesignDeliveryState.entries.firstOrNull {
                    it.wire == delivery?.string("state")
                } ?: DesignDeliveryState.PENDING,
                reason = delivery?.string("reason")),
            publication = DesignPublication(
                state = DesignPublicationState.entries.firstOrNull {
                    it.wire == publication?.string("state")
                } ?: DesignPublicationState.PENDING,
                identifier = publication?.string("identifier"),
                destination = publication?.string("destination"),
                contentSHA256 = publication?.string("contentSHA256"),
                reason = publication?.string("reason")))
    }

    private fun decodeDecisionReceipt(value: JsonObject): DesignDecisionReceipt =
        DesignDecisionReceipt(
            state = decodeState(
                value.objectValue("state")
                    ?: throw CreativeException("invalidResponse", "missingDesignState")),
            candidateID = value.string("candidateID").orEmpty(),
            operationID = value.string("operationID").orEmpty(),
            idempotent = value.bool("idempotent") ?: false)

    private fun decodeComparison(value: JsonObject): DesignComparison =
        DesignComparison(
            candidateID = value.string("candidateID").orEmpty(),
            baseSHA256 = value.string("baseSHA256").orEmpty(),
            proposedSHA256 = value.string("proposedSHA256").orEmpty(),
            changed = value.bool("changed") ?: false,
            diff = value.strings("diff"),
            diffTruncated = value.bool("diffTruncated") ?: false,
            diffNote = value.string("diffNote"),
            status = DesignCandidateStatus.entries.firstOrNull {
                it.wire == value.string("status")
            } ?: DesignCandidateStatus.PENDING)

    private fun decodePreviewReceipt(value: JsonObject): DesignPreviewReceipt =
        DesignPreviewReceipt(
            target = decodeTarget(
                value.objectValue("target")
                    ?: throw CreativeException("invalidResponse", "missingDesignTarget")),
            ownerRevision = value.long("ownerRevision") ?: 0L,
            candidateID = value.string("candidateID"),
            revisionID = value.string("revisionID"),
            format = value.string("format").orEmpty(),
            rootPath = value.string("rootPath")
                ?: throw CreativeException("invalidResponse", "missingPreviewRoot"),
            relativePath = value.string("relativePath")
                ?: throw CreativeException("invalidResponse", "missingPreviewPath"),
            byteCount = value.long("byteCount") ?: 0L,
            sha256 = value.string("sha256").orEmpty(),
            width = value.int("width"),
            height = value.int("height"),
            createdAt = value.string("createdAt").orEmpty())

    private fun decodeExportReceipt(value: JsonObject): DesignExportReceipt =
        DesignExportReceipt(
            target = decodeTarget(
                value.objectValue("target")
                    ?: throw CreativeException("invalidResponse", "missingDesignTarget")),
            ownerRevision = value.long("ownerRevision") ?: 0L,
            candidateID = value.string("candidateID"),
            revisionID = value.string("revisionID"),
            format = value.string("format").orEmpty(),
            rootPath = value.string("rootPath")
                ?: throw CreativeException("invalidResponse", "missingExportRoot"),
            relativePath = value.string("relativePath")
                ?: throw CreativeException("invalidResponse", "missingExportPath"),
            byteCount = value.long("byteCount") ?: 0L,
            sha256 = value.string("sha256").orEmpty(),
            createdAt = value.string("createdAt").orEmpty())

    // MARK: - Creative inventory / import decoding

    private fun decodeCreativeAssetPage(value: JsonObject): CreativeDesignAssetPage {
        val array = value.array("assets")
            ?: throw CreativeException("invalidResponse", "missingCreativeAssets")
        val assets = array.map { element ->
            val objectValue = element as? JsonObject
                ?: throw CreativeException("invalidResponse", "invalidCreativeAsset")
            decodeCreativeAsset(objectValue)
        }
        return CreativeDesignAssetPage(
            assets = assets,
            nextCursor = value.string("nextCursor"))
    }

    private fun decodeCreativeAsset(value: JsonObject): CreativeDesignAsset {
        val assetID = value.string("assetID")
            ?.takeIf { it.isNotBlank() }
            ?: throw CreativeException("invalidResponse", "missingCreativeAssetID")
        if (runCatching { UUID.fromString(assetID) }.isFailure) {
            throw CreativeException("invalidResponse", "invalidCreativeAssetID")
        }
        val digest = value.string("contentSHA256")
            ?.takeIf { it.length == 64 }
            ?: throw CreativeException("invalidResponse", "missingCreativeAssetDigest")
        val format = value.string("format")
            ?: throw CreativeException("invalidResponse", "missingCreativeAssetFormat")
        return CreativeDesignAsset(
            assetID = assetID,
            displayName = value.string("displayName").orEmpty(),
            kind = value.string("kind").orEmpty(),
            format = format,
            byteCount = value.long("byteCount") ?: 0L,
            contentSHA256 = digest,
            updatedAt = value.string("updatedAt"),
            selectable = value.bool("selectable") ?: false)
    }

    private fun decodeCreativePendingPage(value: JsonObject): CreativeDesignPendingPage {
        val array = value.array("requests")
            ?: throw CreativeException("invalidResponse", "missingCreativeRequests")
        val requests = array.map { element ->
            val objectValue = element as? JsonObject
                ?: throw CreativeException("invalidResponse", "invalidCreativeRequest")
            decodeCreativePendingRequest(objectValue)
        }
        return CreativeDesignPendingPage(
            requests = requests,
            nextCursor = value.string("nextCursor"))
    }

    private fun decodeCreativePendingRequest(
        value: JsonObject,
    ): CreativeDesignPendingRequest {
        val targetKey = value.string("targetKey")
            ?.takeIf { it.length == 64 }
            ?: throw CreativeException("invalidResponse", "missingCreativeTargetKey")
        val target = decodeTarget(
            value.objectValue("target")
                ?: throw CreativeException("invalidResponse", "missingCreativeTarget"))
        val requestedKind = decodeContentType(value.string("requestedOutputKind"))
            ?: throw CreativeException(
                "invalidResponse", "missingCreativeRequestedKind")
        val state = CreativeDesignRequestState.fromWire(value.string("state"))
            ?: throw CreativeException("invalidResponse", "invalidCreativeRequestState")
        return CreativeDesignPendingRequest(
            targetKey = targetKey,
            ownerRevision = value.long("ownerRevision") ?: 0L,
            target = target,
            storage = decodeStorageLayer(value.objectValue("storage")),
            requestedOutputKind = requestedKind,
            state = state,
            boundResultID = value.string("boundResultID"),
            boundFormat = value.string("boundFormat"),
            boundContentSHA256 = value.string("boundContentSHA256"),
            originConversationID = value.string("originConversationID"),
            environmentID = value.string("environmentID"),
            updatedAt = value.string("updatedAt"))
    }

    private fun decodeStorageLayer(value: JsonObject?): CreativeStorageLayer =
        when (value?.string("kind")) {
            "appOwned" -> CreativeStorageLayer.AppOwned
            "workspace" -> CreativeStorageLayer.Workspace(
                value?.string("workspaceID")
                    ?: throw CreativeException(
                        "invalidResponse", "missingStorageWorkspace"))
            else -> throw CreativeException(
                "invalidResponse", "invalidStorageLayer")
        }

    private fun decodeCreativeImportReceipt(
        value: JsonObject,
    ): CreativeDesignImportReceipt = CreativeDesignImportReceipt(
        state = decodeState(
            value.objectValue("state")
                ?: throw CreativeException("invalidResponse", "missingDesignState")),
        asset = decodeCreativeAsset(
            value.objectValue("asset")
                ?: throw CreativeException("invalidResponse", "missingCreativeAsset")),
        imported = value.bool("imported") ?: false)

    // MARK: - Routing / staging helpers

    private fun isCanvas(binding: DesignTargetBinding): Boolean =
        binding.target.kind == DesignTargetKind.CANVAS_NODE

    private fun stateAction(binding: DesignTargetBinding): String =
        if (isCanvas(binding)) "design.canvas.snapshot" else "design.owner.state"

    private fun adoptAction(binding: DesignTargetBinding): String =
        if (isCanvas(binding)) "design.canvas.adopt" else "design.owner.adopt"

    private fun compareAction(binding: DesignTargetBinding): String =
        if (isCanvas(binding)) "design.canvas.compare" else "design.owner.compare"

    private fun restoreAction(binding: DesignTargetBinding): String =
        if (isCanvas(binding)) "design.canvas.restore" else "design.owner.restore"

    private fun previewAction(binding: DesignTargetBinding): String =
        if (isCanvas(binding)) "design.canvas.preview" else "design.owner.preview"

    private fun exportAction(binding: DesignTargetBinding): String =
        if (isCanvas(binding)) "design.canvas.export" else "design.owner.export"

    private fun requireOperation(opID: String) {
        if (!opID.matches(Regex("[A-Za-z0-9._-]{1,100}"))) {
            throw CreativeException("invalidRequest", "invalidOperationID")
        }
    }

    private fun requireCreative(binding: DesignTargetBinding) {
        if (binding.target.kind != DesignTargetKind.CREATIVE_DOCUMENT) {
            throw CreativeException(
                "designTargetUnavailable", "creativeRouteRequiresCreativeTarget")
        }
        if (binding.target.requestedOutputKind == null) {
            throw CreativeException(
                "designTargetUnavailable", "creativeBeginRequiresRequestedKind")
        }
    }

    private fun resolveSource(uri: Uri): Pair<String, String?> {
        val mimeType = runCatching { resolver.getType(uri) }.getOrNull()
        val displayName = runCatching {
            resolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }
        }.getOrNull()
        val fallback = uri.lastPathSegment?.substringAfterLast('/')
        return (displayName ?: fallback ?: "design") to mimeType
    }

    private fun formatFor(displayName: String, mimeType: String?): String {
        val extension = File(displayName).extension.lowercase()
        if (extension.isNotEmpty()) return extension
        return when (mimeType?.lowercase()) {
            "image/png" -> "png"
            "image/jpeg" -> "jpg"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            "application/pdf" -> "pdf"
            "text/markdown" -> "md"
            "text/plain" -> "txt"
            "text/html" -> "html"
            "image/svg+xml" -> "svg"
            "application/json" -> "json"
            else -> "bin"
        }
    }

    private fun isoOrNow(value: String): String =
        if (value.isBlank()) R2MediaWire.isoNow() else value

    private fun decodeContentType(raw: String?): DesignContentType? =
        DesignContentType.entries.firstOrNull { it.wire == raw }

    private fun decodeWorkMode(raw: String?): DesignWorkMode? =
        DesignWorkMode.entries.firstOrNull { it.wire == raw }

    private fun JsonObject.strings(key: String): List<String> =
        array(key)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()

    private fun JsonObject.stringsOrNull(key: String): List<String>? =
        array(key)?.mapNotNull { (it as? JsonPrimitive)?.content }

    private companion object {
        const val MAX_STAGED = 32
        const val MAX_CREATIVE_PAGE = 24
        /** Bounded wait for the real copy workers to join at Root stop. */
        const val STAGING_DRAIN_MILLIS = 5_000L
    }
}
