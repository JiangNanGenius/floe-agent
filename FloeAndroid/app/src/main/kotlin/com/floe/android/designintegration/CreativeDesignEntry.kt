// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignBriefModel
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignPublicationState
import com.floe.android.feature.canvas.DesignStateProjection
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.StagedDesignPayload
import com.floe.android.feature.canvas.ui.design.DesignSessionProvider
import com.floe.android.feature.canvas.ui.design.DesignSessionRequest
import com.floe.android.feature.canvas.ui.design.DesignTargetDescriptor
import com.floe.android.feature.canvas.ui.design.DesignWorkflowController
import com.floe.android.host.creative.CreativeDesignAsset
import com.floe.android.host.creative.CreativeDesignAssetPage
import com.floe.android.host.creative.CreativeDesignImportReceipt
import com.floe.android.host.creative.CreativeDesignPendingPage
import com.floe.android.host.creative.CreativeDesignPendingRequest
import com.floe.android.host.creative.CreativeDesignRequestState
import com.floe.android.host.creative.CreativeHostController
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Typed seam over the EXISTING creative host for the creative-library entry.
 *
 * It exists so the entry state machine (stable ids, bounded cursors, expected
 * revisions and retry rules) is testable without a device; production wires
 * [CreativeHostEntryAdapter] straight to `CreativeHostController`. No method
 * invents a project, task, environment, path or asset id.
 */
internal interface CreativeDesignEntryHost {
    suspend fun bind(
        binding: DesignTargetBinding,
        expectedRevision: Long?,
        opID: String,
    ): DesignStateProjection

    suspend fun begin(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        brief: DesignBriefModel,
    ): DesignStateProjection

    suspend fun retainedAssets(cursor: String?, limit: Int): CreativeDesignAssetPage

    suspend fun pendingRequests(cursor: String?, limit: Int): CreativeDesignPendingPage

    suspend fun bindRetained(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        assetID: String,
        displayName: String?,
    ): DesignStateProjection

    suspend fun stage(source: Uri, sessionToken: String): StagedDesignPayload

    suspend fun importStaged(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        payload: StagedDesignPayload,
        displayName: String?,
    ): CreativeDesignImportReceipt

    fun discardStaged(token: String)
}

internal class CreativeHostEntryAdapter(
    private val hostProvider: () -> CreativeHostController,
) : CreativeDesignEntryHost {
    override suspend fun bind(
        binding: DesignTargetBinding,
        expectedRevision: Long?,
        opID: String,
    ): DesignStateProjection = hostProvider().designHost.bindTarget(
        com.floe.android.feature.canvas.DesignBindRequest(
            binding = binding,
            expectedRevision = expectedRevision,
            opID = opID,
        ),
    )

    override suspend fun begin(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        brief: DesignBriefModel,
    ): DesignStateProjection = hostProvider().beginCreative(
        binding = binding,
        expectedRevision = expectedRevision,
        opID = opID,
        brief = brief,
    )

    override suspend fun retainedAssets(
        cursor: String?,
        limit: Int,
    ): CreativeDesignAssetPage = hostProvider().creativeAssets(
        cursor = cursor,
        limit = limit.coerceIn(1, MAX_PAGE),
    )

    override suspend fun pendingRequests(
        cursor: String?,
        limit: Int,
    ): CreativeDesignPendingPage = hostProvider().creativePendingRequests(
        cursor = cursor,
        limit = limit.coerceIn(1, MAX_PAGE),
    )

    override suspend fun bindRetained(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        assetID: String,
        displayName: String?,
    ): DesignStateProjection = hostProvider().bindCreativeRetainedFirstResult(
        binding = binding,
        expectedRevision = expectedRevision,
        opID = opID,
        boundResultID = assetID,
        displayName = displayName,
    )

    override suspend fun stage(source: Uri, sessionToken: String): StagedDesignPayload =
        hostProvider().stageDesignPayload(source, sessionToken)

    override suspend fun importStaged(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        payload: StagedDesignPayload,
        displayName: String?,
    ): CreativeDesignImportReceipt = hostProvider().importCreativeFirstResult(
        binding = binding,
        expectedRevision = expectedRevision,
        opID = opID,
        payload = payload,
        displayName = displayName,
    )

    override fun discardStaged(token: String) {
        runCatching { hostProvider().discardDesignPayload(token) }
    }

    private companion object {
        const val MAX_PAGE = 24
    }
}

/** One real retained material shown by the picker (metadata only). */
internal data class CreativeDesignAssetUi(
    val asset: CreativeDesignAsset,
    val matchesRequestedKind: Boolean,
)

/** The request the picker/binding currently belongs to. */
internal data class CreativeDesignActive(
    val binding: DesignTargetBinding,
    val ownerRevision: Long,
    val requestedKind: DesignContentType,
    val requestState: CreativeDesignRequestState,
    val boundAssetName: String? = null,
    val boundFormat: String? = null,
    val pendingImport: CreativeDesignPendingImport? = null,
)

internal data class CreativeDesignPendingImport(
    val payload: StagedDesignPayload,
    val displayName: String?,
    val opID: String,
)

/** Typed, user-safe failure (raw reason text is never shown as product copy). */
internal data class CreativeDesignEntryFailure(
    val code: String,
    val reason: String?,
    val retryable: Boolean,
) {
    companion object {
        fun from(error: Throwable): CreativeDesignEntryFailure = when (error) {
            is CreativeException -> CreativeDesignEntryFailure(
                code = error.code, reason = error.reason, retryable = error.retryable)
            else -> CreativeDesignEntryFailure(
                code = "designUnavailable", reason = null, retryable = false)
        }
    }
}

/**
 * App-owned state machine for the ACTUAL creative-library design entry.
 *
 * It drives only the published `CreativeHostController` creative API:
 * bounded pending list, explicit output kind, fresh request identity, real
 * retained-asset bind or SAF import, and the retained design workflow sheet.
 * Raw asset UUIDs are never requested or displayed; every selection op id is
 * derived deterministically from the exact request/asset/payload so a
 * transport-unknown retry reuses the same identity.
 */
internal class CreativeDesignEntryController(
    private val host: CreativeDesignEntryHost,
    private val sessions: DesignSessionProvider,
    private val scope: CoroutineScope,
    private val newSessionToken: () -> String = { CreativeSessionTokens.newToken() },
    private val newOperationID: () -> String = { UUID.randomUUID().toString() },
    private val now: () -> String = { Instant.now().toString() },
) {
    var pending: List<CreativeDesignPendingRequest> by mutableStateOf(emptyList())
        private set
    var pendingLoading: Boolean by mutableStateOf(false)
        private set
    var pendingHasMore: Boolean by mutableStateOf(false)
        private set
    var pendingFailure: CreativeDesignEntryFailure? by mutableStateOf(null)
        private set

    var assets: List<CreativeDesignAssetUi> by mutableStateOf(emptyList())
        private set
    var assetsLoading: Boolean by mutableStateOf(false)
        private set
    var assetsHasMore: Boolean by mutableStateOf(false)
        private set
    var assetsFailure: CreativeDesignEntryFailure? by mutableStateOf(null)
        private set

    var selectedKind: DesignContentType by mutableStateOf(DesignContentType.IMAGE)
        private set
    var briefGoal: String by mutableStateOf("")
        private set

    var active: CreativeDesignActive? by mutableStateOf(null)
        private set
    var busy: Boolean by mutableStateOf(false)
        private set
    var failure: CreativeDesignEntryFailure? by mutableStateOf(null)
        private set
    var workflowController: DesignWorkflowController? by mutableStateOf(null)
        private set
    /**
     * True when the last sheet decision committed but its publication is
     * still pending. This is surfaced as pending, never as a completed save.
     */
    var lastPublicationPending: Boolean by mutableStateOf(false)
        private set

    private var pendingCursor: String? = null
    private var assetsCursor: String? = null
    private var generation = 0L
    private var createDraft: CreateDraft? = null

    private data class CreateDraft(
        val binding: DesignTargetBinding,
        val opID: String,
    )

    // MARK: - Draft

    fun selectKind(kind: DesignContentType) {
        if (active != null || busy) return
        // A retryable (transport-unknown) create keeps the exact request
        // identity/op id; a definitive failure may start a different kind.
        if (createDraft != null && failure?.retryable == true) return
        createDraft = null
        selectedKind = kind
    }

    fun updateBrief(value: String) {
        if (active != null) return
        if (createDraft != null && failure?.retryable == true) return
        if (createDraft != null) createDraft = null
        briefGoal = value.take(MAX_BRIEF_CHARS)
    }

    // MARK: - Pending requests

    fun refreshPending() {
        if (pendingLoading) return
        pendingCursor = null
        pendingFailure = null
        loadPending(append = false)
    }

    fun loadMorePending() {
        if (pendingLoading || pendingCursor == null) return
        loadPending(append = true)
    }

    private fun loadPending(append: Boolean) {
        val gen = generation
        pendingLoading = true
        scope.launch {
            try {
                val page = host.pendingRequests(
                    cursor = if (append) pendingCursor else null,
                    limit = PAGE_LIMIT,
                )
                ensureCurrent(gen)
                pending = if (append) {
                    (pending + page.requests).distinctBy { it.targetKey }
                } else {
                    page.requests
                }
                pendingCursor = page.nextCursor
                pendingHasMore = page.nextCursor != null
                pendingFailure = null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: EntryStale) {
                // A newer native generation owns the state now.
            } catch (error: Throwable) {
                if (gen == generation) {
                    pendingFailure = CreativeDesignEntryFailure.from(error)
                }
            } finally {
                if (gen == generation) pendingLoading = false
            }
        }
    }

    // MARK: - Materials

    fun refreshAssets() {
        if (assetsLoading) return
        assetsCursor = null
        assetsFailure = null
        loadAssets(append = false)
    }

    fun loadMoreAssets() {
        if (assetsLoading || assetsCursor == null) return
        loadAssets(append = true)
    }

    private fun loadAssets(append: Boolean) {
        val gen = generation
        val kind = active?.requestedKind ?: selectedKind
        assetsLoading = true
        scope.launch {
            try {
                val page = host.retainedAssets(
                    cursor = if (append) assetsCursor else null,
                    limit = PAGE_LIMIT,
                )
                ensureCurrent(gen)
                val mapped = page.assets.map { asset ->
                    CreativeDesignAssetUi(
                        asset = asset,
                        matchesRequestedKind = CreativeDesignFormats.matches(kind, asset.format),
                    )
                }
                assets = if (append) {
                    (assets + mapped).distinctBy { it.asset.assetID }
                } else {
                    mapped
                }
                assetsCursor = page.nextCursor
                assetsHasMore = page.nextCursor != null
                assetsFailure = null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: EntryStale) {
                // A newer native generation owns the state now.
            } catch (error: Throwable) {
                if (gen == generation) {
                    assetsFailure = CreativeDesignEntryFailure.from(error)
                }
            } finally {
                if (gen == generation) assetsLoading = false
            }
        }
    }

    // MARK: - Create / reopen

    fun createRequest() {
        if (busy) return
        if (active != null) {
            failure = CreativeDesignEntryFailure("invalidRequest", "alreadyActive", false)
            return
        }
        val gen = generation
        val draft = createDraft ?: run {
            // Fresh request UUID is identity only, never a grant. The stable
            // owner is the public creative-library surface.
            val binding = DesignTargetResolver.creativeBinding(
                ownerID = DesignTargetResolver.CREATIVE_LIBRARY_OWNER,
                assetID = newOperationID(),
                requestedOutputKind = selectedKind,
                originConversationID = null,
                sessionToken = newSessionToken(),
            )
            CreateDraft(binding = binding, opID = newOperationID()).also { createDraft = it }
        }
        val brief = briefGoal.trim()
        val briefOpID = if (brief.isEmpty()) null else "brief-" + shortDigest(brief)
        busy = true
        failure = null
        scope.launch {
            try {
                var state = host.bind(draft.binding, expectedRevision = null, opID = draft.opID)
                ensureCurrent(gen)
                if (briefOpID != null) {
                    state = host.begin(
                        binding = draft.binding,
                        expectedRevision = state.ownerRevision,
                        opID = briefOpID,
                        brief = DesignBriefModel(
                            goal = brief,
                            audience = null,
                            constraints = emptyList(),
                            createdAt = now(),
                        ),
                    )
                    ensureCurrent(gen)
                }
                createDraft = null
                active = activeOf(draft.binding, state, selectedKind)
                lastPublicationPending = false
                refreshAssets()
                refreshPending()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: EntryStale) {
                // A newer native generation owns the state now.
            } catch (error: Throwable) {
                if (gen == generation) {
                    failure = CreativeDesignEntryFailure.from(error)
                }
            } finally {
                if (gen == generation) busy = false
            }
        }
    }

    fun reopen(request: CreativeDesignPendingRequest) {
        if (busy) return
        if (active != null) {
            failure = CreativeDesignEntryFailure("invalidRequest", "alreadyActive", false)
            return
        }
        val gen = generation
        val binding = DesignTargetBinding(
            target = request.target,
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext.standalone(),
            sessionToken = newSessionToken(),
        )
        busy = true
        failure = null
        scope.launch {
            try {
                val state = host.bind(
                    binding = binding,
                    expectedRevision = request.ownerRevision,
                    opID = newOperationID(),
                )
                ensureCurrent(gen)
                active = activeOf(
                    binding = binding,
                    state = state,
                    requestedKind = request.requestedOutputKind,
                    boundFormat = request.boundFormat,
                )
                lastPublicationPending = false
                refreshAssets()
                refreshPending()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: EntryStale) {
                // A newer native generation owns the state now.
            } catch (error: Throwable) {
                if (gen == generation) {
                    failure = CreativeDesignEntryFailure.from(error)
                }
            } finally {
                if (gen == generation) busy = false
            }
        }
    }

    /** Bind a REAL retained asset already listed by `creativeAssets`. */
    fun chooseRetained(material: CreativeDesignAssetUi) {
        val current = active ?: return
        if (busy || !material.asset.selectable) return
        if (!CreativeDesignFormats.matches(current.requestedKind, material.asset.format)) {
            failure = CreativeDesignEntryFailure(
                "creativeMaterialTypeMismatch", "formatFamilyMismatch", false)
            return
        }
        val gen = generation
        val opID = bindOpID(current.binding.target.sourceID, material.asset.assetID)
        busy = true
        failure = null
        scope.launch {
            try {
                val state = host.bindRetained(
                    binding = current.binding,
                    expectedRevision = current.ownerRevision,
                    opID = opID,
                    assetID = material.asset.assetID,
                    displayName = material.asset.displayName,
                )
                ensureCurrent(gen)
                active = activeOf(
                    binding = current.binding,
                    state = state,
                    requestedKind = current.requestedKind,
                    boundAssetName = material.asset.displayName,
                    boundFormat = material.asset.format,
                )
                refreshPending()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: EntryStale) {
                // A newer native generation owns the state now.
            } catch (error: Throwable) {
                if (gen == generation) {
                    failure = CreativeDesignEntryFailure.from(error)
                }
            } finally {
                if (gen == generation) busy = false
            }
        }
    }

    // MARK: - SAF import

    /**
     * Stage the exact SAF selection through the Root-owned App staging seam,
     * then import it into the existing creative asset library and bind the
     * canonical asset. A failed import keeps the staged payload for an exact
     * retry with the SAME op id; a new selection discards the old payload.
     */
    fun importFile(uri: Uri, displayName: String?) {
        val current = active ?: return
        if (busy) return
        discardPendingImport(current)
        val gen = generation
        busy = true
        failure = null
        scope.launch {
            try {
                val payload = host.stage(uri, current.binding.sessionToken)
                ensureCurrent(gen)
                val opID = importOpID(current.binding.target.sourceID, payload.sha256)
                updateActive(current.binding) { value ->
                    value.copy(
                        pendingImport = CreativeDesignPendingImport(
                            payload = payload, displayName = displayName, opID = opID),
                    )
                }
                runImport(
                    binding = current.binding,
                    expectedRevision = current.ownerRevision,
                    payload = payload,
                    displayName = displayName,
                    opID = opID,
                    gen = gen,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: EntryStale) {
                // The newer generation reset already discarded its own exact
                // staged token; never mutate the new generation's state.
            } catch (error: Throwable) {
                if (gen == generation) {
                    failure = CreativeDesignEntryFailure.from(error)
                }
            } finally {
                if (gen == generation) busy = false
            }
        }
    }

    /**
     * Import a payload that was already staged through the Root-owned seam.
     *
     * The SAF picker stages and runs the same [runImport] under its own busy
     * window; this bounded post-stage seam exists for the focused source test
     * (and any future App caller that already owns an opaque staged token).
     * A retry of the SAME payload goes through [retryImport] so its op id and
     * token never change.
     */
    internal fun importVerifiedStagedPayload(
        payload: StagedDesignPayload,
        displayName: String?,
        opID: String,
    ) {
        val current = active ?: return
        if (busy) return
        updateActive(current.binding) { value ->
            value.copy(
                pendingImport = CreativeDesignPendingImport(
                    payload = payload, displayName = displayName, opID = opID),
            )
        }
        runImportAttempt()
    }

    /** Retry the EXACT retained staged payload with the SAME stable op id. */
    fun retryImport() {
        runImportAttempt()
    }

    private fun runImportAttempt() {
        val current = active ?: return
        val pending = current.pendingImport ?: return
        if (busy) return
        val gen = generation
        busy = true
        failure = null
        scope.launch {
            try {
                runImport(
                    binding = current.binding,
                    expectedRevision = current.ownerRevision,
                    payload = pending.payload,
                    displayName = pending.displayName,
                    opID = pending.opID,
                    gen = gen,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: EntryStale) {
                // The new generation owns its own state/tokens.
            } catch (error: Throwable) {
                if (gen == generation) {
                    failure = CreativeDesignEntryFailure.from(error)
                }
            } finally {
                if (gen == generation) busy = false
            }
        }
    }

    fun discardImport() {
        val current = active ?: return
        discardPendingImport(current)
    }

    private suspend fun runImport(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        payload: StagedDesignPayload,
        displayName: String?,
        opID: String,
        gen: Long,
    ) {
        val receipt = host.importStaged(
            binding = binding,
            expectedRevision = expectedRevision,
            opID = opID,
            payload = payload,
            displayName = displayName,
        )
        ensureCurrent(gen)
        active = activeOf(
            binding = binding,
            state = receipt.state,
            requestedKind = active?.requestedKind ?: selectedKind,
            boundAssetName = receipt.asset.displayName.ifBlank { displayName },
            boundFormat = receipt.asset.format,
        )
        refreshPending()
        refreshAssets()
    }

    private fun discardPendingImport(current: CreativeDesignActive) {
        val pending = current.pendingImport ?: return
        host.discardStaged(pending.payload.token)
        updateActive(current.binding) { it.copy(pendingImport = null) }
    }

    // MARK: - Workflow sheet

    /**
     * Open the retained design workflow for the request whose first real
     * material is bound. [title]/[kindLabel] are the localized display strings
     * resolved by the App; no raw id is shown.
     */
    fun openWorkflow(title: String, kindLabel: String) {
        val current = active ?: return
        if (current.requestState != CreativeDesignRequestState.FIRST_RESULT_BOUND) return
        if (workflowController != null) return
        val controller = runCatching {
            sessions.acquire(
                DesignSessionRequest(
                    binding = current.binding,
                    descriptor = DesignTargetDescriptor(
                        title = title,
                        kindLabel = kindLabel,
                        // Continuing an existing creative request must not
                        // compare against a revision captured before a prior
                        // sheet adoption: the controller start binds the SAME
                        // target/session, and every mutation still uses the
                        // live ownerRevision CAS.
                        expectedRevision = null,
                    ),
                ),
            )
        }.getOrElse { error ->
            failure = CreativeDesignEntryFailure.from(error)
            return
        }
        workflowController = controller
    }

    fun closeWorkflow() {
        val controller = workflowController ?: return
        // Keep the entry's projection aligned with the ACTUAL owner revision
        // the sheet reached (adopt/restore), not the revision captured when
        // the material was bound.
        controller.state?.let { state ->
            updateActive(controller.binding) { value ->
                value.copy(
                    ownerRevision = state.ownerRevision,
                    requestState = requestStateOf(state),
                    boundFormat = boundFormatOf(state) ?: value.boundFormat,
                )
            }
        }
        lastPublicationPending =
            controller.decision?.publication?.state == DesignPublicationState.PENDING
        workflowController = null
        sessions.release(controller)
        // A published adoption creates a real immutable creative asset; the
        // material list and pending state must reflect the actual receipt
        // (a pending publication stays visible as pending in the sheet and is
        // never counted as published here).
        refreshAssets()
        refreshPending()
    }

    /** Close the panel; an unreferenced staged import is discarded. */
    fun closePanel() {
        active?.let { discardPendingImport(it) }
        active = null
        failure = null
        createDraft = null
    }

    fun dismissFailure() {
        failure = null
        assetsFailure = null
        pendingFailure = null
        lastPublicationPending = false
    }

    /**
     * New accepted native generation. Any in-flight callback from the old
     * generation is fenced by [generation] and can never mutate the new one.
     */
    fun onGenerationChanged() {
        generation += 1
        active?.pendingImport?.let { pending ->
            runCatching { host.discardStaged(pending.payload.token) }
        }
        active = null
        createDraft = null
        workflowController = null
        pending = emptyList()
        pendingCursor = null
        pendingHasMore = false
        assets = emptyList()
        assetsCursor = null
        assetsHasMore = false
        busy = false
        failure = null
        assetsFailure = null
        pendingFailure = null
        lastPublicationPending = false
    }

    private fun activeOf(
        binding: DesignTargetBinding,
        state: DesignStateProjection,
        requestedKind: DesignContentType,
        boundAssetName: String? = null,
        boundFormat: String? = null,
    ): CreativeDesignActive = CreativeDesignActive(
        binding = binding,
        ownerRevision = state.ownerRevision,
        requestedKind = state.target.requestedOutputKind ?: requestedKind,
        requestState = requestStateOf(state),
        boundAssetName = boundAssetName,
        boundFormat = boundFormat ?: boundFormatOf(state),
    )

    private fun requestStateOf(state: DesignStateProjection): CreativeDesignRequestState {
        val raw = (state.project.creativeRequest?.get("state") as? JsonPrimitive)?.contentOrNull
        return CreativeDesignRequestState.fromWire(raw)
            ?: if (state.project.candidates.isNotEmpty() ||
                state.creativeFirstResultProvenance != null
            ) {
                CreativeDesignRequestState.FIRST_RESULT_BOUND
            } else {
                CreativeDesignRequestState.AWAITING_FIRST_RESULT
            }
    }

    private fun boundFormatOf(state: DesignStateProjection): String? {
        val request = state.project.creativeRequest ?: return null
        return (request["boundFormat"] as? JsonPrimitive)?.contentOrNull
    }

    private fun updateActive(
        binding: DesignTargetBinding,
        transform: (CreativeDesignActive) -> CreativeDesignActive,
    ) {
        val current = active ?: return
        if (current.binding != binding) return
        active = transform(current)
    }

    private fun ensureCurrent(gen: Long) {
        if (gen != generation) throw EntryStale()
    }

    private class EntryStale : Exception()

    private fun shortDigest(value: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
        return digest.take(12).joinToString("") { "%02x".format(it) }
    }

    /** Stable across retries/transport-unknown for the exact request+asset. */
    private fun bindOpID(sourceID: String, assetID: String): String =
        "bind-$sourceID-$assetID"

    /** Stable across retries for the exact request+staged bytes. */
    private fun importOpID(sourceID: String, sha256: String): String =
        "import-$sourceID-${sha256.take(24).lowercase()}"

    companion object {
        const val PAGE_LIMIT = 24
        private const val MAX_BRIEF_CHARS = 2_000

        val AVAILABLE_KINDS: List<DesignContentType> = listOf(
            DesignContentType.IMAGE,
            DesignContentType.PDF,
            DesignContentType.PRESENTATION,
            DesignContentType.OFFICE_DOCUMENT,
            DesignContentType.NOTES,
            DesignContentType.WEBPAGE,
            DesignContentType.CAD,
            DesignContentType.VIDEO,
        )
    }
}
