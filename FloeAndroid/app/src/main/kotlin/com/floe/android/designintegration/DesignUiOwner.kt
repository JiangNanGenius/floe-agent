// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import android.content.Context
import android.net.Uri
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.DesignPreviewReceipt
import com.floe.android.feature.canvas.DesignExportReceipt
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.StagedDesignPayload
import com.floe.android.feature.canvas.ui.design.DesignExportDeliveryResult
import com.floe.android.feature.canvas.ui.design.DesignPreservationConstraints
import com.floe.android.feature.canvas.ui.design.DesignPreviewContent
import com.floe.android.feature.canvas.ui.design.DesignProposalSource
import com.floe.android.feature.canvas.ui.design.DesignRestructureConfirmation
import com.floe.android.feature.canvas.ui.design.DesignRestructureRequest
import com.floe.android.feature.canvas.ui.design.DesignSessionProvider
import com.floe.android.feature.canvas.ui.design.DesignSessionRequest
import com.floe.android.feature.canvas.ui.design.DesignTrustedOperation
import com.floe.android.feature.canvas.ui.design.DesignUiPorts
import com.floe.android.feature.canvas.ui.design.DesignWorkflowController
import com.floe.android.host.creative.CreativeAcceptedRoot
import com.floe.android.host.creative.CreativeHostController
import com.floe.android.host.creative.DesignPreservationConstraintsModel
import com.floe.android.host.creative.DesignTrustedConfirmation
import com.floe.android.host.creative.DesignTrustedOperation as HostTrustedOperation
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.withContext
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Application-owned design UI integration.
 *
 * This is the single bounded bridge between the App entries and the existing
 * native design host. It owns:
 *  - a bounded map of retained feature controllers keyed by exact target +
 *    editor session (rotation/background reuse; actual close retires one);
 *  - the only proposal staging route (real SAF URI or App-written manual text
 *    handed to `CreativeR2DesignHost.stagePayload`);
 *  - verified preview/export opening over the captured accepted Root/epoch;
 *  - the App-side issuance registry for trusted restructure confirmations
 *    (native still mints/burns the single-use grant);
 *  - the design Save/Share delivery and its Root-stop drain gate.
 *
 * It creates no project, task, environment or root and never treats a source
 * identity string as authority.
 */
internal class DesignUiOwner(
    context: Context,
    hostScope: CoroutineScope,
    private val hostProvider: () -> CreativeHostController,
    private val acceptedRootProvider: () -> CreativeAcceptedRoot?,
    private val epochProvider: () -> Long?,
    /**
     * Live captured Canvas owner accessor for the design snapshot's real
     * image bytes. Supplied by the App binding point; never a path from JSON.
     */
    private val canvasAssetsBasePathProvider: (String) -> String? = { null },
) : DesignUiPorts, DesignSessionProvider {
    private val applicationContext = context.applicationContext
    private val appScope = hostScope
    private val lock = Any()
    private val sessions = LinkedHashMap<String, RetainedSession>()
    private val confirmations = LinkedHashMap<String, DesignTrustedConfirmation>()

    @Volatile
    private var boundEpoch = 0L

    private var creativeEntryController: CreativeDesignEntryController? = null

    @Volatile
    private var stopping = false

    val exportDelivery = DesignExportDelivery(applicationContext, hostScope)
    private val artifacts = DesignArtifactAccess(
        hostProvider = hostProvider,
        acceptedRootProvider = acceptedRootProvider,
        epochProvider = epochProvider,
        delivery = exportDelivery,
        canvasAssetsBasePathProvider = canvasAssetsBasePathProvider,
    )

    fun onNativeCreativeBound(epoch: Long) {
        val stale = synchronized(lock) {
            val changed = epoch > 0L && epoch != boundEpoch
            boundEpoch = epoch
            stopping = false
            if (!changed) {
                emptyList<RetainedSession>()
            } else {
                val values = sessions.values.toList()
                sessions.clear()
                confirmations.clear()
                values
            }
        }
        artifacts.clearForRootStop()
        exportDelivery.onNativeCreativeBound()
        synchronized(lock) { creativeEntryController }?.onGenerationChanged()
        stale.forEach { closeDetached(it) }
    }

    /** Root-stop gate; false keeps Root bound and the operation owned. */
    suspend fun prepareForRootStop(): Boolean {
        synchronized(lock) { stopping = true }
        exportDelivery.fenceForRootStop()
        val current = synchronized(lock) {
            val values = sessions.values.toList()
            sessions.clear()
            confirmations.clear()
            values
        }
        for (session in current) {
            withTimeoutOrNull(5_000L) {
                runCatching { session.controller.closeAndDrain(5_000L) }
            }
            session.scope.cancel()
        }
        artifacts.clearForRootStop()
        val drained = exportDelivery.retireForRootStop()
        if (drained) {
            synchronized(lock) { creativeEntryController }?.onGenerationChanged()
        }
        if (!drained) {
            // Root was NOT released; keep the old generation usable for a
            // later exact retry instead of permanently fencing design UI.
            synchronized(lock) { stopping = false }
            exportDelivery.onNativeRootStopAborted()
        }
        return drained
    }

    /**
     * The App-owned creative-library entry state (create/continue, bounded
     * material picker, SAF import, pending reopen). It is created lazily,
     * survives rotation/background and is reset with the accepted generation;
     * it never owns a Canvas/design store of its own.
     */
    val creativeEntry: CreativeDesignEntryController
        get() = synchronized(lock) {
            creativeEntryController ?: CreativeDesignEntryController(
                host = CreativeHostEntryAdapter(hostProvider),
                sessions = this,
                scope = appScope,
            ).also { creativeEntryController = it }
        }

    // MARK: - DesignSessionProvider

    override fun acquire(request: DesignSessionRequest): DesignWorkflowController {
        if (stopping) {
            throw CreativeException("staleGeneration", "designGenerationStopped", retryable = true)
        }
        DesignTargetResolver.validate(request.binding)
        val key = DesignTargetResolver.targetKey(request.binding)
        var evicted: RetainedSession? = null
        val controller = synchronized(lock) {
            val existing = sessions[key]
            if (existing != null && !existing.controller.closed) {
                return existing.controller
            }
            if (existing != null) {
                sessions.remove(key)
                evicted = existing
            }
            val child = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val created = DesignWorkflowController(
                host = hostProvider().designHost,
                binding = request.binding,
                ports = this,
                descriptor = request.descriptor,
                scope = child,
                canvasRefresh = request.canvasRefresh,
            )
            sessions[key] = RetainedSession(created, child)
            while (sessions.size > MAX_SESSIONS) {
                val oldest = sessions.entries.firstOrNull() ?: break
                sessions.remove(oldest.key)
                evicted = oldest.value
            }
            created
        }
        evicted?.let(::closeDetached)
        return controller
    }

    override fun release(controller: DesignWorkflowController) {
        val removed = synchronized(lock) {
            val entry = sessions.entries.firstOrNull { it.value.controller === controller }
            if (entry != null) sessions.remove(entry.key)
            entry?.value
        }
        appScope.launch {
            runCatching { controller.closeAndDrain(5_000L) }
            (removed?.scope ?: return@launch).cancel()
        }
    }

    // MARK: - DesignUiPorts

    override suspend fun stageProposal(
        source: DesignProposalSource,
        sessionToken: String,
    ): StagedDesignPayload {
        requireRetainedSession(sessionToken)
        return when (source) {
            is DesignProposalSource.PickedUri ->
                hostProvider().stageDesignPayload(source.uri, sessionToken)
            is DesignProposalSource.ManualText -> stageManualText(source, sessionToken)
        }
    }

    override fun discardProposal(token: String) {
        runCatching { hostProvider().discardDesignPayload(token) }
    }

    override suspend fun openPreview(
        receipt: DesignPreviewReceipt,
        binding: DesignTargetBinding,
    ): DesignPreviewContent {
        requireRetained(binding)
        return artifacts.openPreview(receipt, binding)
    }

    override suspend fun deliverExport(
        receipt: DesignExportReceipt,
        binding: DesignTargetBinding,
    ): DesignExportDeliveryResult {
        requireRetained(binding)
        return artifacts.deliverExport(receipt, binding)
    }

    override suspend fun prepareRestructure(
        request: DesignRestructureRequest,
    ): DesignRestructureConfirmation {
        requireRetained(request.binding)
        val hostConfirmation = hostProvider().designTrustedApprovals.prepare(
            binding = request.binding,
            operation = request.operation.toHost(),
            opID = request.opID,
            preservation = request.preservation.toHost(),
            artifactID = request.artifactID,
            candidateID = request.candidateID,
            baseRevisionID = request.baseRevisionID,
        )
        val evicted = synchronized(lock) {
            confirmations[hostConfirmation.token] = hostConfirmation
            var oldest: DesignTrustedConfirmation? = null
            while (confirmations.size > MAX_CONFIRMATIONS) {
                val first = confirmations.entries.firstOrNull() ?: break
                confirmations.remove(first.key)
                oldest = first.value
            }
            oldest
        }
        evicted?.let { stale ->
            appScope.launch {
                runCatching { hostProvider().designTrustedApprovals.revoke(stale) }
            }
        }
        return hostConfirmation.toUi()
    }

    override suspend fun confirmRestructure(
        confirmation: DesignRestructureConfirmation,
        binding: DesignTargetBinding,
    ): Boolean {
        requireRetained(binding)
        val expected = synchronized(lock) { confirmations.remove(confirmation.token) }
            ?: throw CreativeException(
                "designAuthorityExpired", "confirmationMissing", retryable = false)
        if (expected.toUi() != confirmation) {
            throw CreativeException(
                "designAuthorityMismatch", "confirmationDoesNotMatchTarget")
        }
        return hostProvider().designTrustedApprovals.confirm(expected)
    }

    override suspend fun revokeRestructure(
        confirmation: DesignRestructureConfirmation,
        binding: DesignTargetBinding,
    ) {
        val expected = synchronized(lock) { confirmations.remove(confirmation.token) }
            ?: return
        runCatching { hostProvider().designTrustedApprovals.revoke(expected) }
    }

    // MARK: - Creative first-result binding (actual App API, future entry)

    /**
     * Persist a creative START request in the SAME owner envelope. Only a
     * retained trusted editor target may call this; the native service also
     * re-checks the registered session. No model call path uses this owner.
     */
    suspend fun beginCreative(
        binding: DesignTargetBinding,
        expectedRevision: Long?,
        opID: String,
        brief: com.floe.android.feature.canvas.DesignBriefModel? = null,
        spec: com.floe.android.feature.canvas.DesignSpecModel? = null,
    ) = run {
        requireRetained(binding)
        hostProvider().beginCreative(
            binding = binding,
            expectedRevision = expectedRevision,
            opID = opID,
            brief = brief,
            spec = spec,
        )
    }

    /**
     * Bind a REAL retained creative asset as the first result. The source must
     * be that exact asset's bytes staged through [stageProposal]; native
     * verifies the asset row, digest and durable run/job link before CAS.
     */
    suspend fun bindCreativeFirstResult(
        binding: DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        boundResultID: String,
        payload: StagedDesignPayload,
        displayName: String? = null,
    ) = run {
        requireRetained(binding)
        hostProvider().bindCreativeFirstResult(
            binding = binding,
            expectedRevision = expectedRevision,
            opID = opID,
            boundResultID = boundResultID,
            payload = payload,
            displayName = displayName,
        )
    }

    // MARK: - Private

    private suspend fun stageManualText(
        source: DesignProposalSource.ManualText,
        sessionToken: String,
    ): StagedDesignPayload {
        val format = source.format.lowercase()
        if (format !in MANUAL_FORMATS) {
            throw CreativeException("invalidRequest", "unsupportedProposalTextFormat")
        }
        val bytes = source.text.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty()) {
            throw CreativeException("assetEmpty", "proposalTextEmpty")
        }
        if (bytes.size > MAX_MANUAL_BYTES) {
            throw CreativeException("designPayloadTooLarge", "proposalTextTooLarge")
        }
        val directory = File(applicationContext.cacheDir, "DesignProposalStaging")
        val file = File(directory, "${UUID.randomUUID()}.$format")
        try {
            withContext(Dispatchers.IO) {
                if (!directory.isDirectory && !directory.mkdirs()) {
                    throw CreativeException(
                        "assetStagingUnavailable", "designStagingUnavailable", retryable = true)
                }
                file.writeBytes(bytes)
            }
            return hostProvider().stageDesignPayload(Uri.fromFile(file), sessionToken)
        } finally {
            runCatching { file.delete() }
        }
    }

    private fun requireRetainedSession(sessionToken: String) {
        val present = synchronized(lock) {
            sessions.values.any { it.controller.binding.sessionToken == sessionToken }
        }
        if (!present) {
            throw CreativeException("staleSession", "designSessionClosed", retryable = true)
        }
    }

    private fun requireRetained(binding: DesignTargetBinding) {
        if (stopping) {
            throw CreativeException("staleGeneration", "designRootStopping", retryable = true)
        }
        val present = synchronized(lock) {
            sessions.values.any { it.controller.binding == binding }
        }
        if (!present) {
            throw CreativeException("staleSession", "designSessionClosed", retryable = true)
        }
    }

    private fun closeDetached(session: RetainedSession) {
        appScope.launch {
            runCatching { session.controller.closeAndDrain(2_000L) }
            session.scope.cancel()
        }
    }

    private data class RetainedSession(
        val controller: DesignWorkflowController,
        val scope: CoroutineScope,
    )

    private fun DesignPreservationConstraints.toHost(): DesignPreservationConstraintsModel =
        DesignPreservationConstraintsModel(
            content = content,
            data = data,
            behavior = behavior,
            formatBounds = formatBounds,
        )

    private fun DesignTrustedOperation.toHost(): HostTrustedOperation = when (this) {
        DesignTrustedOperation.PROPOSE -> HostTrustedOperation.PROPOSE
        DesignTrustedOperation.FREEZE -> HostTrustedOperation.FREEZE
        DesignTrustedOperation.ADOPT -> HostTrustedOperation.ADOPT
    }

    private fun DesignTrustedConfirmation.toUi(): DesignRestructureConfirmation =
        DesignRestructureConfirmation(
            token = token,
            targetKey = targetKey,
            operationID = operationID,
            originalTaskOwnerID = originalTaskOwnerID,
            baseRevisionID = baseRevisionID,
            preservationDigest = preservationDigest,
            preservation = DesignPreservationConstraints(
                content = preservation.content,
                data = preservation.data,
                behavior = preservation.behavior,
                formatBounds = preservation.formatBounds,
            ),
            expiresAt = expiresAt,
        )

    companion object {
        private const val MAX_SESSIONS = 8
        private const val MAX_CONFIRMATIONS = 8
        private const val MAX_MANUAL_BYTES = 2 * 1024 * 1024
        private val MANUAL_FORMATS = setOf("md", "txt", "html")
    }
}
