// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.design

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.DesignAdoptMode
import com.floe.android.feature.canvas.DesignAdoptRequest
import com.floe.android.feature.canvas.DesignBriefModel
import com.floe.android.feature.canvas.DesignBriefRequest
import com.floe.android.feature.canvas.DesignBindRequest
import com.floe.android.feature.canvas.DesignCandidateModel
import com.floe.android.feature.canvas.DesignCandidateStatus
import com.floe.android.feature.canvas.DesignCompareRequest
import com.floe.android.feature.canvas.DesignComparison
import com.floe.android.feature.canvas.DesignDecisionReceipt
import com.floe.android.feature.canvas.DesignDecisionResult
import com.floe.android.feature.canvas.DesignDeliveryState
import com.floe.android.feature.canvas.DesignExportReceipt
import com.floe.android.feature.canvas.DesignExportRequest
import com.floe.android.feature.canvas.DesignFreezeRequest
import com.floe.android.feature.canvas.DesignHostApi
import com.floe.android.feature.canvas.DesignHostStatus
import com.floe.android.feature.canvas.DesignPreviewReceipt
import com.floe.android.feature.canvas.DesignPreviewRequest
import com.floe.android.feature.canvas.DesignProjectProjection
import com.floe.android.feature.canvas.DesignProposalRequest
import com.floe.android.feature.canvas.DesignPublicationState
import com.floe.android.feature.canvas.DesignRejectRequest
import com.floe.android.feature.canvas.DesignRestoreRequest
import com.floe.android.feature.canvas.DesignSpecModel
import com.floe.android.feature.canvas.DesignSpecRequest
import com.floe.android.feature.canvas.DesignStateProjection
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.DesignTargetKind
import com.floe.android.feature.canvas.DesignWireLimits
import com.floe.android.feature.canvas.DesignWorkMode
import com.floe.android.feature.canvas.StagedDesignPayload
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/** One user-visible operation; used only to choose precise product copy. */
enum class DesignOperation {
    BIND,
    LOAD,
    BRIEF,
    SPEC,
    FREEZE,
    PROPOSE,
    ADOPT,
    REJECT,
    COMPARE,
    RESTORE,
    PREVIEW,
    EXPORT,
    CANVAS_REFRESH,
}

/** Typed UI failure; [code] comes from the host, never a raw exception. */
data class DesignFailure(
    val code: String,
    val detail: String? = null,
    val retryable: Boolean = false,
    val operation: DesignOperation,
)

enum class DesignNotice {
    SAVED,
    FROZEN,
    PROPOSED,
    ADOPTED,
    REJECTED,
    RESTORED,
    EXPORTED,
    CANVAS_REFRESH_PENDING,
}

/** Unsaved brief/spec edits; reloads never overwrite a dirty draft. */
data class DesignDraft(
    val goal: String = "",
    val audience: String = "",
    val constraintsText: String = "",
    val paletteText: String = "",
    val typography: String = "",
    val layout: String = "",
    val spacing: String = "",
    val brandAssetRefsText: String = "",
    val voice: String = "",
    val prohibitionsText: String = "",
    val rawMarkdown: String = "",
)

data class DesignPreservationDraft(
    val content: String = "",
    val data: String = "",
    val behavior: String = "",
    val formatBounds: String = "",
) {
    fun toConstraints(): DesignPreservationConstraints = DesignPreservationConstraints(
        content = lines(content),
        data = lines(data),
        behavior = lines(behavior),
        formatBounds = lines(formatBounds),
    )

    companion object {
        internal fun lines(raw: String): List<String> = raw
            .lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toList()

        fun from(constraints: DesignPreservationConstraints): DesignPreservationDraft =
            DesignPreservationDraft(
                content = constraints.content.joinToString("\n"),
                data = constraints.data.joinToString("\n"),
                behavior = constraints.behavior.joinToString("\n"),
                formatBounds = constraints.formatBounds.joinToString("\n"),
            )
    }
}

/**
 * Retained design workflow controller.
 *
 * The controller is created and retained by the App owner (outside
 * composition) for one exact [DesignTargetBinding]. Rotation/background keep
 * the loaded projection, selected candidate, drafts and pending operation IDs.
 * An actual close retires only this target's staged payload, trusted
 * confirmation and preview buffers; a late response from target A can never
 * mutate target B because every applied projection is compared to the captured
 * target identity and the controller is released by identity.
 *
 * Every mutation uses the host's exact owner revision and a stable operation
 * ID that is reused only for the SAME payload/decision (a changed payload gets
 * a new ID), so an outcome-unknown retry cannot silently become a second
 * design edit.
 */
@Stable
class DesignWorkflowController(
    val host: DesignHostApi,
    val binding: DesignTargetBinding,
    val ports: DesignUiPorts,
    val descriptor: DesignTargetDescriptor,
    private val scope: CoroutineScope,
    private val canvasRefresh: (suspend () -> Boolean)? = null,
    private val newOperationID: () -> String = { UUID.randomUUID().toString() },
) {
    var status: DesignHostStatus? by mutableStateOf(null)
        private set
    var state: DesignStateProjection? by mutableStateOf(null)
        private set
    var artifacts: List<DesignArtifactInfo> by mutableStateOf(emptyList())
        private set
    var loading by mutableStateOf(true)
        private set
    var busy by mutableStateOf(false)
        private set
    var failure: DesignFailure? by mutableStateOf(null)
        private set
    var notice: DesignNotice? by mutableStateOf(null)
        private set
    var closed by mutableStateOf(false)
        private set

    var draft: DesignDraft by mutableStateOf(DesignDraft())
        private set
    var draftsDirty by mutableStateOf(false)
        private set
    var preservationDraft: DesignPreservationDraft by mutableStateOf(DesignPreservationDraft())
        private set
    var workMode: DesignWorkMode by mutableStateOf(DesignWorkMode.CREATE)
        private set
    var desiredFormat: String by mutableStateOf("")
        private set
    var selectedArtifactID: String? by mutableStateOf(null)
        private set
    var selectedCandidateID: String? by mutableStateOf(null)
        private set
    var comparison: DesignComparison? by mutableStateOf(null)
        private set
    var decision: DesignDecisionResult? by mutableStateOf(null)
        private set
    var stagedPayload: StagedDesignPayload? by mutableStateOf(null)
        private set
    var stagedLabel: String? by mutableStateOf(null)
        private set
    var proposalSummary: String by mutableStateOf("")
    var proposalDiffText: String by mutableStateOf("")
    var manualProposalText: String by mutableStateOf("")
    var manualProposalFormat: String by mutableStateOf("md")
    var manualProposalOpen: Boolean by mutableStateOf(false)
    var previewContent: DesignPreviewContent? by mutableStateOf(null)
        private set
    var previewReceipt: DesignPreviewReceipt? by mutableStateOf(null)
        private set
    var previewCandidateID: String? by mutableStateOf(null)
        private set
    var previewRevisionID: String? by mutableStateOf(null)
        private set
    var exportResult: DesignExportDeliveryResult? by mutableStateOf(null)
        private set
    var canvasRefreshPending by mutableStateOf(false)
        private set
    var pendingConfirmation: DesignRestructureConfirmation? by mutableStateOf(null)
        private set
    var pendingConfirmationOperation: DesignTrustedOperation? by mutableStateOf(null)
        private set

    private val operationMutex = Mutex()
    private var started = false
    private var workModeTouched = false
    private var desiredFormatTouched = false
    private var appliedPreservation: DesignPreservationConstraints? = null
    private var pendingAfterConfirm: (suspend () -> Unit)? = null
    private var pendingRevoke: DesignRestructureConfirmation? = null
    private var activeOperations = 0

    private data class PendingOp(val key: String, val id: String)

    private val pendingOps = mutableMapOf<DesignOperation, PendingOp>()

    // MARK: - Lifecycle

    fun start() {
        if (started || closed) return
        started = true
        loading = true
        launchOperation(DesignOperation.BIND) {
            val nextStatus = host.status()
            status = nextStatus
            if (!nextStatus.bound) {
                throw CreativeException(
                    "designUnavailable", "designNotBound", retryable = true)
            }
            val kind = binding.target.kind.wire
            if (!nextStatus.availableTargetKinds.contains(kind)) {
                throw CreativeException(
                    "designTargetUnavailable",
                    nextStatus.targetKindReasons[kind] ?: "targetKindUnavailable")
            }
            val projection = host.bindTarget(
                DesignBindRequest(
                    binding = binding,
                    expectedRevision = descriptor.expectedRevision,
                    opID = operationID(DesignOperation.BIND, ""),
                ),
            )
            applyState(projection)
            settleOperation(DesignOperation.BIND)
        }
    }

    fun refresh() {
        if (closed) return
        if (!started) {
            start()
            return
        }
        launchOperation(DesignOperation.LOAD, clearFailure = false) {
            val projection = host.state(binding)
            applyState(projection)
        }
    }

    fun retry() {
        if (closed) return
        failure = null
        if (state == null) {
            // A failed initial bind must be retryable with the SAME exact
            // target/session; no new owner or path is invented.
            started = false
            start()
        } else {
            refresh()
        }
    }

    fun dismissFailure() {
        failure = null
    }

    fun dismissNotice() {
        notice = null
    }

    fun updateDraft(next: DesignDraft) {
        draft = next
        draftsDirty = true
    }

    fun updatePreservationDraft(next: DesignPreservationDraft) {
        preservationDraft = next
    }

    fun selectWorkMode(mode: DesignWorkMode) {
        workMode = mode
        workModeTouched = true
    }

    fun updateDesiredFormat(value: String) {
        desiredFormat = value
        desiredFormatTouched = true
    }

    fun selectArtifact(artifactID: String) {
        selectedArtifactID = artifactID
        comparison = null
    }

    fun selectCandidate(candidateID: String?) {
        selectedCandidateID = candidateID
        comparison = null
    }

    // MARK: - Brief / spec

    fun saveBrief() {
        val goal = draft.goal.trim()
        if (goal.isEmpty()) {
            failure = DesignFailure("invalidRequest", "briefGoalRequired", false, DesignOperation.BRIEF)
            return
        }
        val key = "brief|$goal|${draft.audience.trim()}|${draft.constraintsText.trim()}"
        val opID = operationID(DesignOperation.BRIEF, key)
        launchOperation(DesignOperation.BRIEF) {
            val current = requireState()
            val sent = draft
            val projection = host.setBrief(
                DesignBriefRequest(
                    binding = binding,
                    expectedRevision = current.ownerRevision,
                    opID = opID,
                    brief = DesignBriefModel(
                        goal = goal,
                        audience = draft.audience.trim().ifBlank { null },
                        constraints = DesignPreservationDraft.lines(draft.constraintsText),
                        createdAt = current.project.brief?.createdAt
                            ?: java.time.Instant.now().toString(),
                    ),
                ),
            )
            applyState(projection)
            if (draft == sent) draftsDirty = false
            settleOperation(DesignOperation.BRIEF)
            notice = DesignNotice.SAVED
        }
    }

    fun saveSpec() {
        val key = "spec|${draft.paletteText}|${draft.typography}|${draft.layout}|" +
            "${draft.spacing}|${draft.brandAssetRefsText}|${draft.voice}|" +
            "${draft.prohibitionsText}|${draft.rawMarkdown}"
        val opID = operationID(DesignOperation.SPEC, key)
        launchOperation(DesignOperation.SPEC) {
            val current = requireState()
            val sent = draft
            val projection = host.setSpec(
                DesignSpecRequest(
                    binding = binding,
                    expectedRevision = current.ownerRevision,
                    opID = opID,
                    spec = DesignSpecModel(
                        palette = DesignPreservationDraft.lines(draft.paletteText)
                            .takeIf { it.isNotEmpty() },
                        typography = draft.typography.trim().ifBlank { null },
                        layout = draft.layout.trim().ifBlank { null },
                        spacing = draft.spacing.trim().ifBlank { null },
                        brandAssetRefs = DesignPreservationDraft.lines(draft.brandAssetRefsText)
                            .takeIf { it.isNotEmpty() },
                        voice = draft.voice.trim().ifBlank { null },
                        prohibitions = DesignPreservationDraft.lines(draft.prohibitionsText)
                            .takeIf { it.isNotEmpty() },
                        rawMarkdown = draft.rawMarkdown.ifBlank { null },
                    ),
                ),
            )
            applyState(projection)
            if (draft == sent) draftsDirty = false
            settleOperation(DesignOperation.SPEC)
            notice = DesignNotice.SAVED
        }
    }

    // MARK: - Freeze

    fun freeze() {
        if (pendingConfirmation != null) {
            failure = DesignFailure(
                "designAuthorityPending", "confirmationPending", false, DesignOperation.FREEZE)
            return
        }
        val opID = operationID(DesignOperation.FREEZE, freezeKey())
        if (workMode == DesignWorkMode.RESTRUCTURE) {
            val constraints = preservationDraft.toConstraints()
            if (constraints.isEmpty()) {
                failure = DesignFailure(
                    "designAuthorityInvalid",
                    "preservationConstraintsRequired",
                    false,
                    DesignOperation.FREEZE,
                )
                return
            }
            launchOperation(DesignOperation.FREEZE) {
                requireState()
                val intendedMode = workMode
                val confirmation = ports.prepareRestructure(
                    DesignRestructureRequest(
                        binding = binding,
                        operation = DesignTrustedOperation.FREEZE,
                        opID = opID,
                        preservation = constraints,
                        // Freeze resolves the live base itself; the frozen
                        // run below (if any) is not the new freeze base.
                        baseRevisionID = null,
                    ),
                )
                showConfirmation(
                    confirmation = confirmation,
                    operation = DesignTrustedOperation.FREEZE,
                    afterConfirm = {
                        appliedPreservation = confirmation.preservation
                        freezeInternal(
                            opID, confirmation.preservationDigest, intendedMode)
                    },
                )
            }
            return
        }
        launchOperation(DesignOperation.FREEZE) { freezeInternal(opID, null) }
    }

    private suspend fun freezeInternal(
        opID: String,
        preservationDigest: String?,
        mode: DesignWorkMode = workMode,
    ) {
        val current = requireState()
        host.freeze(
            DesignFreezeRequest(
                binding = binding,
                expectedRevision = current.ownerRevision,
                opID = opID,
                // A NEW freeze snapshots the current source into a new
                // revision; the caller never reuses the previous frozen
                // revision id (that would overwrite history). Restructure
                // base authority comes from the trusted confirmation.
                inputRevisionID = null,
                specSHA256 = null,
                targetRevisionID = null,
                desiredFormat = desiredFormat.trim().ifBlank { null },
                workMode = mode,
                preservationDigest = preservationDigest,
            ),
        )
        applyState(host.state(binding))
        settleOperation(DesignOperation.FREEZE)
        notice = DesignNotice.FROZEN
    }

    // MARK: - Proposal

    fun stagePicked(uri: android.net.Uri, displayName: String?) {
        stage(DesignProposalSource.PickedUri(uri, displayName), displayName ?: "")
    }

    fun stageManualText(text: String, format: String) {
        if (text.isEmpty()) {
            failure = DesignFailure("invalidRequest", "proposalTextRequired", false, DesignOperation.PROPOSE)
            return
        }
        stage(
            DesignProposalSource.ManualText(text, format),
            "manual.${format.ifBlank { "txt" }}",
        )
    }

    private fun stage(source: DesignProposalSource, label: String) {
        if (pendingConfirmation != null) {
            failure = DesignFailure(
                "designAuthorityPending", "confirmationPending", false, DesignOperation.PROPOSE)
            return
        }
        launchOperation(DesignOperation.PROPOSE) {
            val previous = stagedPayload
            val next = ports.stageProposal(source, binding.sessionToken)
            if (closed) {
                // The sheet closed while the real stage copy was running; the
                // newly staged token is still OURS and must be discarded.
                ports.discardProposal(next.token)
                return@launchOperation
            }
            if (previous != null && previous.token != next.token) {
                ports.discardProposal(previous.token)
            }
            stagedPayload = next
            stagedLabel = label.take(120).ifBlank { null }
            settleOperation(DesignOperation.PROPOSE)
        }
    }

    fun discardStaged() {
        val current = stagedPayload ?: return
        stagedPayload = null
        stagedLabel = null
        ports.discardProposal(current.token)
    }

    fun propose() {
        if (pendingConfirmation != null) {
            failure = DesignFailure(
                "designAuthorityPending", "confirmationPending", false, DesignOperation.PROPOSE)
            return
        }
        val staged = stagedPayload
        if (staged == null) {
            failure = DesignFailure("designPayloadMissing", "proposalSourceRequired", false, DesignOperation.PROPOSE)
            return
        }
        val artifactID = selectedArtifactID
        if (artifactID == null) {
            failure = DesignFailure("designPayloadMissing", "freezeRequired", false, DesignOperation.PROPOSE)
            return
        }
        val summary = proposalSummary.trim()
        if (summary.isEmpty()) {
            failure = DesignFailure("invalidRequest", "proposalSummaryRequired", false, DesignOperation.PROPOSE)
            return
        }
        val opID = operationID(DesignOperation.PROPOSE, proposeKey(staged, artifactID))
        if (workMode == DesignWorkMode.RESTRUCTURE) {
            val constraints = preservationDraft.toConstraints()
            if (constraints.isEmpty()) {
                failure = DesignFailure(
                    "designAuthorityInvalid",
                    "preservationConstraintsRequired",
                    false,
                    DesignOperation.PROPOSE,
                )
                return
            }
            launchOperation(DesignOperation.PROPOSE) {
                val current = requireState()
                val intendedMode = workMode
                val confirmation = ports.prepareRestructure(
                    DesignRestructureRequest(
                        binding = binding,
                        operation = DesignTrustedOperation.PROPOSE,
                        opID = opID,
                        preservation = constraints,
                        artifactID = artifactID,
                        baseRevisionID = current.project.frozenRun?.inputRevisionID,
                    ),
                )
                showConfirmation(
                    confirmation = confirmation,
                    operation = DesignTrustedOperation.PROPOSE,
                    afterConfirm = {
                        appliedPreservation = confirmation.preservation
                        proposeInternal(
                            opID, artifactID, staged,
                            confirmation.preservationDigest, intendedMode)
                    },
                )
            }
            return
        }
        launchOperation(DesignOperation.PROPOSE) {
            proposeInternal(opID, artifactID, staged, null)
        }
    }

    private suspend fun proposeInternal(
        opID: String,
        artifactID: String,
        staged: StagedDesignPayload,
        preservationDigest: String?,
        mode: DesignWorkMode = workMode,
    ) {
        val current = requireState()
        val result = host.propose(
            DesignProposalRequest(
                binding = binding,
                expectedRevision = current.ownerRevision,
                opID = opID,
                artifactID = artifactID,
                baseRevisionID = current.project.frozenRun?.inputRevisionID,
                payload = staged,
                summary = proposalSummary.trim(),
                diff = DesignPreservationDraft.lines(proposalDiffText),
                feedbackIDs = emptyList(),
                workMode = mode,
                desiredFormat = desiredFormat.trim().ifBlank { null },
                preservationDigest = preservationDigest,
            ),
        )
        stagedPayload = null
        stagedLabel = null
        applyState(result.state)
        selectedCandidateID = result.candidate.id
        settleOperation(DesignOperation.PROPOSE)
        notice = DesignNotice.PROPOSED
    }

    // MARK: - Candidate decisions

    fun adopt(mode: DesignAdoptMode) {
        if (pendingConfirmation != null) {
            failure = DesignFailure(
                "designAuthorityPending", "confirmationPending", false, DesignOperation.ADOPT)
            return
        }
        val candidate = requireSelectedCandidate(DesignOperation.ADOPT) ?: return
        val opID = operationID(DesignOperation.ADOPT, "adopt|${candidate.id}|${mode.name}")
        if (candidate.workMode == DesignWorkMode.RESTRUCTURE) {
            val constraints = preservationDraft.toConstraints()
                .takeUnless { it.isEmpty() }
                ?: appliedPreservation
            if (constraints == null || constraints.isEmpty()) {
                failure = DesignFailure(
                    "designAuthorityInvalid",
                    "preservationConstraintsRequired",
                    false,
                    DesignOperation.ADOPT,
                )
                return
            }
            launchOperation(DesignOperation.ADOPT) {
                val confirmation = ports.prepareRestructure(
                    DesignRestructureRequest(
                        binding = binding,
                        operation = DesignTrustedOperation.ADOPT,
                        opID = opID,
                        preservation = constraints,
                        candidateID = candidate.id,
                        baseRevisionID = candidate.baseRevisionID,
                    ),
                )
                showConfirmation(
                    confirmation = confirmation,
                    operation = DesignTrustedOperation.ADOPT,
                    afterConfirm = {
                        adoptInternal(candidate.id, mode, opID, confirmation.preservationDigest)
                    },
                )
            }
            return
        }
        launchOperation(DesignOperation.ADOPT) {
            adoptInternal(candidate.id, mode, opID, null)
        }
    }

    private suspend fun adoptInternal(
        candidateID: String,
        mode: DesignAdoptMode,
        opID: String,
        preservationDigest: String?,
    ) {
        val current = requireState()
        val result = host.adopt(
            DesignAdoptRequest(
                binding = binding,
                expectedRevision = current.ownerRevision,
                opID = opID,
                candidateID = candidateID,
                mode = mode,
            ),
        )
        if (closed) {
            // The decision committed after the sheet closed. Do not write
            // sheet state, but still refresh the authoritative Canvas so the
            // committed node content is visible in the surviving editor.
            if (binding.target.kind == DesignTargetKind.CANVAS_NODE && canvasRefresh != null) {
                refreshCanvasInternal()
            }
            return
        }
        decision = result
        applyState(result.state)
        result.committedRevisionToken?.takeIf { it.isNotBlank() }?.let { token ->
            artifacts.firstOrNull { artifact ->
                artifact.revisions.any { it.revisionID == token }
            }?.let { artifact -> selectedArtifactID = artifact.artifactID }
        }
        settleOperation(DesignOperation.ADOPT)
        if (result.delivery.state == DesignDeliveryState.PENDING ||
            result.publication.state == DesignPublicationState.PENDING
        ) {
            failure = DesignFailure(
                "designPublicationPending",
                result.delivery.reason ?: result.publication.reason,
                retryable = false,
                operation = DesignOperation.ADOPT,
            )
        }
        // A restructure adoption can consume the prepared claim digest; keep
        // the UI's exact constraints visible for the result state.
        if (preservationDigest != null) {
            appliedPreservation = appliedPreservation ?: preservationDraft.toConstraints()
        }
        notice = DesignNotice.ADOPTED
        if (binding.target.kind == DesignTargetKind.CANVAS_NODE && canvasRefresh != null) {
            refreshCanvasInternal()
        }
    }

    fun reject() {
        if (pendingConfirmation != null) {
            failure = DesignFailure(
                "designAuthorityPending", "confirmationPending", false, DesignOperation.REJECT)
            return
        }
        val candidate = requireSelectedCandidate(DesignOperation.REJECT) ?: return
        val opID = operationID(DesignOperation.REJECT, "reject|${candidate.id}")
        launchOperation(DesignOperation.REJECT) {
            val current = requireState()
            val receipt: DesignDecisionReceipt = host.reject(
                DesignRejectRequest(
                    binding = binding,
                    expectedRevision = current.ownerRevision,
                    opID = opID,
                    candidateID = candidate.id,
                ),
            )
            applyState(receipt.state)
            settleOperation(DesignOperation.REJECT)
            notice = DesignNotice.REJECTED
        }
    }

    fun compare() {
        val candidate = requireSelectedCandidate(DesignOperation.COMPARE) ?: return
        launchOperation(DesignOperation.COMPARE) {
            comparison = host.compare(
                DesignCompareRequest(binding = binding, candidateID = candidate.id),
            )
        }
    }

    fun restore(revisionID: String) {
        if (revisionID.isBlank()) return
        if (pendingConfirmation != null) {
            failure = DesignFailure(
                "designAuthorityPending", "confirmationPending", false, DesignOperation.RESTORE)
            return
        }
        val opID = operationID(DesignOperation.RESTORE, "restore|$revisionID")
        launchOperation(DesignOperation.RESTORE) {
            val current = requireState()
            val projection = host.restore(
                DesignRestoreRequest(
                    binding = binding,
                    expectedRevision = current.ownerRevision,
                    opID = opID,
                    revisionID = revisionID,
                ),
            )
            applyState(projection)
            settleOperation(DesignOperation.RESTORE)
            notice = DesignNotice.RESTORED
            if (binding.target.kind == DesignTargetKind.CANVAS_NODE && canvasRefresh != null) {
                refreshCanvasInternal()
            }
        }
    }

    // MARK: - Preview / export

    fun preview(candidateID: String? = null, revisionID: String? = null) {
        launchOperation(DesignOperation.PREVIEW) {
            val receipt = host.preview(
                DesignPreviewRequest(
                    binding = binding,
                    candidateID = candidateID,
                    revisionID = revisionID,
                    maxBytes = DesignWireLimits.MAX_PREVIEW_BYTES,
                ),
            )
            val content = ports.openPreview(receipt, binding)
            replacePreview(content)
            previewReceipt = receipt
            previewCandidateID = candidateID
            previewRevisionID = revisionID
        }
    }

    fun closePreview() {
        val current = previewContent
        previewContent = null
        previewReceipt = null
        previewCandidateID = null
        previewRevisionID = null
        current?.let(::recycleSoon)
    }

    fun exportCurrent(candidateID: String? = null, revisionID: String? = null) {
        val format = formatFor(candidateID, revisionID)
        if (format == null) {
            failure = DesignFailure(
                "designPayloadMissing",
                "exportFormatUnavailable",
                false,
                DesignOperation.EXPORT,
            )
            return
        }
        launchOperation(DesignOperation.EXPORT) {
            val receipt: DesignExportReceipt = host.export(
                DesignExportRequest(
                    binding = binding,
                    candidateID = candidateID,
                    revisionID = revisionID,
                    format = format,
                    suggestedFileName = suggestedFileName(format),
                ),
            )
            val result = ports.deliverExport(receipt, binding)
            exportResult = result
            when (result) {
                is DesignExportDeliveryResult.Delivered -> notice = DesignNotice.EXPORTED
                DesignExportDeliveryResult.Cancelled -> Unit
                is DesignExportDeliveryResult.Refused -> failure = DesignFailure(
                    result.code, null, result.retryable, DesignOperation.EXPORT)
            }
        }
    }

    /**
     * Current/revision original format. Canvas has a real snapshot document for
     * the current state; owner targets read the recorded payload format from
     * the preserved project JSON. A missing format is a typed refusal, never a
     * guessed conversion.
     */
    fun formatFor(candidateID: String?, revisionID: String?): String? {
        val current = state ?: return null
        if (binding.target.kind == DesignTargetKind.CANVAS_NODE) {
            if (candidateID == null && revisionID == null) return "canvas.snapshot"
        }
        val resolvedRevision = when {
            candidateID != null -> current.project.candidates
                .firstOrNull { it.id == candidateID }
                ?.proposedRevisionID
            revisionID != null -> revisionID
            else -> current.project.inspectArtifacts()
                .firstOrNull { it.artifactID == selectedArtifactID }
                ?.currentRevision?.revisionID
                ?: current.project.inspectArtifacts().firstOrNull()
                    ?.currentRevision?.revisionID
        } ?: return null
        return current.project.revision(resolvedRevision)?.format
    }

    // MARK: - Trusted restructure confirmation

    fun confirmRestructure() {
        val confirmation = pendingConfirmation ?: return
        val operation = pendingConfirmationOperation ?: return
        launchOperation(operation.toDesignOperation()) {
            ports.confirmRestructure(confirmation, binding)
            pendingConfirmation = null
            pendingConfirmationOperation = null
            val action = pendingAfterConfirm
            pendingAfterConfirm = null
            action?.invoke()
        }
    }

    fun cancelRestructure() {
        val confirmation = pendingConfirmation ?: return
        val operation = pendingConfirmationOperation ?: DesignTrustedOperation.FREEZE
        pendingConfirmation = null
        pendingConfirmationOperation = null
        pendingAfterConfirm = null
        settleOperation(operation.toDesignOperation())
        launchOperation(DesignOperation.FREEZE) {
            ports.revokeRestructure(confirmation, binding)
        }
    }

    // MARK: - Canvas refresh

    fun reloadCanvas() {
        if (canvasRefresh == null) return
        launchOperation(DesignOperation.CANVAS_REFRESH, clearFailure = false) {
            refreshCanvasInternal()
        }
    }

    private suspend fun refreshCanvasInternal() {
        val refresh = canvasRefresh ?: return
        try {
            val refreshed = refresh()
            canvasRefreshPending = !refreshed
            if (!refreshed) notice = DesignNotice.CANVAS_REFRESH_PENDING
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            canvasRefreshPending = true
            notice = DesignNotice.CANVAS_REFRESH_PENDING
        }
    }

    // MARK: - Close

    fun close() {
        if (closed) return
        closed = true
        val staged = stagedPayload
        stagedPayload = null
        stagedLabel = null
        if (staged != null) ports.discardProposal(staged.token)
        val confirmation = pendingConfirmation
        pendingConfirmation = null
        pendingConfirmationOperation = null
        pendingAfterConfirm = null
        if (confirmation != null) {
            // Revoked synchronously by closeAndDrain before the App cancels
            // this controller's scope; a bare job could be cancelled first.
            pendingRevoke = confirmation
        }
    }

    /** Close for an actual close/Root stop; awaits the owned operation. */
    suspend fun closeAndDrain(timeoutMillis: Long = 5_000L) {
        close()
        withTimeoutOrNull(timeoutMillis) { operationMutex.withLock { } }
        pendingRevoke?.let { runCatching { ports.revokeRestructure(it, binding) } }
        pendingRevoke = null
        // By this point the sheet is gone and no Compose draw can reference
        // these buffers, so the bounded bitmap/pager memory can be freed now.
        releasePreviewNow()
    }

    fun releasePreview() {
        val current = previewContent
        previewContent = null
        previewReceipt = null
        previewCandidateID = null
        previewRevisionID = null
        current?.let(::recycleSoon)
    }

    private fun releasePreviewNow() {
        val current = previewContent
        previewContent = null
        previewReceipt = null
        previewCandidateID = null
        previewRevisionID = null
        current?.recycle()
    }

    private fun recycleSoon(content: DesignPreviewContent) {
        // The old preview may still be drawn for one frame after the state
        // write; recycle shortly after so a sheet close/replace cannot recycle
        // a bitmap under an in-flight draw.
        scope.launch {
            delay(500L)
            content.recycle()
        }
    }

    // MARK: - Derived availability

    val effectiveActions: List<String>
        get() = state?.availableActions.orEmpty()

    private fun actionAvailable(owner: String, canvas: String): Boolean =
        effectiveActions.contains(owner) || effectiveActions.contains(canvas)

    val canEditBrief: Boolean
        get() = state?.writable == true && actionAvailable("design.owner.brief", "design.canvas.mutate")
    val canEditSpec: Boolean
        get() = state?.writable == true && actionAvailable("design.owner.spec", "design.canvas.mutate")
    val canFreeze: Boolean
        get() = state?.writable == true && actionAvailable("design.owner.freeze", "design.canvas.mutate")
    val canPropose: Boolean
        get() = state?.writable == true && actionAvailable("design.owner.propose", "design.canvas.mutate")
    val canAdopt: Boolean
        get() = state?.writable == true && actionAvailable("design.owner.adopt", "design.canvas.adopt")
    val canReject: Boolean
        get() = state?.writable == true && actionAvailable("design.owner.reject", "design.canvas.mutate")
    val canCompare: Boolean
        get() = actionAvailable("design.owner.compare", "design.canvas.compare")
    val canRestore: Boolean
        get() = state?.writable == true && actionAvailable("design.owner.restore", "design.canvas.restore")

    val candidates: List<DesignCandidateModel>
        get() = state?.project?.candidates.orEmpty()

    /**
     * True when a RESTRUCTURE freeze/proposal/adoption can be started, so the
     * explicit preservation controls stay visible for an existing restructure
     * candidate even after a reload reset the default work mode to Modify.
     */
    val requiresPreservation: Boolean
        get() = workMode == DesignWorkMode.RESTRUCTURE ||
            candidates.any {
                it.workMode == DesignWorkMode.RESTRUCTURE &&
                    it.status == DesignCandidateStatus.PENDING
            }

    val selectedArtifact: DesignArtifactInfo?
        get() = artifacts.firstOrNull { it.artifactID == selectedArtifactID }
            ?: artifacts.firstOrNull()

    val revisions: List<DesignRevisionInfo>
        get() = selectedArtifact?.revisions.orEmpty()

    // MARK: - Private

    private fun requireSelectedCandidate(operation: DesignOperation): DesignCandidateModel? {
        val candidate = candidates.firstOrNull { it.id == selectedCandidateID }
        if (candidate == null) {
            failure = DesignFailure(
                "candidateNotFound", "selectCandidate", false, operation)
        }
        return candidate
    }

    private fun requireState(): DesignStateProjection =
        state ?: throw CreativeException("designUnavailable", "stateNotLoaded", retryable = true)

    private fun launchOperation(
        operation: DesignOperation,
        clearFailure: Boolean = true,
        block: suspend () -> Unit,
    ) {
        if (closed) return
        scope.launch {
            operationMutex.withLock {
                if (closed) return@withLock
                busy = true
                activeOperations += 1
                if (clearFailure) failure = null
                try {
                    block()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = error.toDesignFailure(operation)
                } finally {
                    activeOperations -= 1
                    busy = false
                    loading = false
                }
            }
        }
    }

    private fun applyState(next: DesignStateProjection) {
        if (closed) return
        val captured = binding.target
        val actual = next.target
        if (captured.kind != actual.kind ||
            captured.ownerID != actual.ownerID ||
            captured.documentID != actual.documentID ||
            captured.sourceID != actual.sourceID
        ) {
            failure = DesignFailure(
                "designTargetMismatch",
                "responseTargetMismatch",
                false,
                DesignOperation.LOAD,
            )
            return
        }
        state = next
        val inspected = next.project.inspectArtifacts()
        artifacts = inspected
        if (selectedArtifactID == null || inspected.none { it.artifactID == selectedArtifactID }) {
            selectedArtifactID = inspected.firstOrNull()?.artifactID
        }
        if (selectedCandidateID == null ||
            next.project.candidates.none { it.id == selectedCandidateID }
        ) {
            selectedCandidateID = next.project.candidates
                .firstOrNull { it.status == DesignCandidateStatus.PENDING }
                ?.id
                ?: next.project.candidates.firstOrNull()?.id
        }
        if (!draftsDirty) {
            draft = next.project.toDraft()
            draftsDirty = false
        }
        if (!workModeTouched) {
            workMode = if (next.project.candidates.isEmpty() &&
                next.project.frozenRun == null
            ) {
                DesignWorkMode.CREATE
            } else {
                DesignWorkMode.MODIFY
            }
        }
        if (!desiredFormatTouched) {
            desiredFormat = next.project.frozenRun?.desiredFormat
                ?: selectedArtifact?.currentRevision?.format
                ?: ""
        }
        loading = false
    }

    private fun showConfirmation(
        confirmation: DesignRestructureConfirmation,
        operation: DesignTrustedOperation,
        afterConfirm: suspend () -> Unit,
    ) {
        if (closed) {
            scope.launch {
                runCatching { ports.revokeRestructure(confirmation, binding) }
            }
            return
        }
        pendingConfirmation = confirmation
        pendingConfirmationOperation = operation
        pendingAfterConfirm = afterConfirm
    }

    private fun replacePreview(content: DesignPreviewContent) {
        if (closed) {
            content.recycle()
            return
        }
        val previous = previewContent
        previewContent = content
        previous?.let(::recycleSoon)
    }

    private fun suggestedFileName(format: String): String {
        val base = "design-${state?.ownerRevision ?: 0}-${binding.target.kind.wire}"
            .replace(Regex("[^A-Za-z0-9._-]"), "-")
            .take(80)
        val extension = when (format.lowercase()) {
            "canvas.snapshot", "json" -> "json"
            "markdown" -> "md"
            else -> format.lowercase().replace(".", "").take(12).ifBlank { "bin" }
        }
        return "$base.$extension"
    }

    private fun operationID(operation: DesignOperation, key: String): String {
        val current = pendingOps[operation]
        if (current != null && current.key == key) return current.id
        val created = PendingOp(key, newOperationID())
        pendingOps[operation] = created
        return created.id
    }

    private fun settleOperation(operation: DesignOperation) {
        pendingOps.remove(operation)
    }

    private fun freezeKey(): String =
        "${workMode.name}|${desiredFormat.trim()}|${preservationDraft.content}|" +
            "${preservationDraft.data}|${preservationDraft.behavior}|${preservationDraft.formatBounds}"

    private fun proposeKey(staged: StagedDesignPayload, artifactID: String): String =
        "$artifactID|${staged.token}|${staged.sha256}|${workMode.name}|" +
            "${desiredFormat.trim()}|${proposalSummary.trim()}|${proposalDiffText.trim()}"

    private fun DesignTrustedOperation.toDesignOperation(): DesignOperation = when (this) {
        DesignTrustedOperation.FREEZE -> DesignOperation.FREEZE
        DesignTrustedOperation.PROPOSE -> DesignOperation.PROPOSE
        DesignTrustedOperation.ADOPT -> DesignOperation.ADOPT
    }

    private fun DesignProjectProjection.toDraft(): DesignDraft = DesignDraft(
        goal = brief?.goal.orEmpty(),
        audience = brief?.audience.orEmpty(),
        constraintsText = brief?.constraints.orEmpty().joinToString("\n"),
        paletteText = spec?.palette.orEmpty().joinToString("\n"),
        typography = spec?.typography.orEmpty(),
        layout = spec?.layout.orEmpty(),
        spacing = spec?.spacing.orEmpty(),
        brandAssetRefsText = spec?.brandAssetRefs.orEmpty().joinToString("\n"),
        voice = spec?.voice.orEmpty(),
        prohibitionsText = spec?.prohibitions.orEmpty().joinToString("\n"),
        rawMarkdown = spec?.rawMarkdown.orEmpty(),
    )

    private fun Throwable.toDesignFailure(operation: DesignOperation): DesignFailure {
        val typed = this as? CreativeException
        return if (typed != null) {
            DesignFailure(
                code = typed.code,
                detail = typed.reason,
                retryable = typed.retryable,
                operation = operation,
            )
        } else {
            DesignFailure("designUnavailable", "unexpectedFailure", true, operation)
        }
    }
}
