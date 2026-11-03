// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import com.floe.android.feature.canvas.CreativeBinding
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignAdoptMode
import com.floe.android.feature.canvas.DesignAdoptRequest
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
import com.floe.android.feature.canvas.DesignPreviewReceipt
import com.floe.android.feature.canvas.DesignPreviewRequest
import com.floe.android.feature.canvas.DesignProjectProjection
import com.floe.android.feature.canvas.DesignProposalRequest
import com.floe.android.feature.canvas.DesignProposalResult
import com.floe.android.feature.canvas.DesignPublication
import com.floe.android.feature.canvas.DesignPublicationState
import com.floe.android.feature.canvas.DesignRejectRequest
import com.floe.android.feature.canvas.DesignRestoreRequest
import com.floe.android.feature.canvas.DesignSpecRequest
import com.floe.android.feature.canvas.DesignStateProjection
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.DesignTargetIdentity
import com.floe.android.feature.canvas.DesignTargetKind
import com.floe.android.feature.canvas.DesignWireLimits
import com.floe.android.feature.canvas.DesignWorkMode
import com.floe.android.feature.canvas.StagedDesignPayload
import com.floe.android.feature.canvas.ui.design.DesignDraft
import com.floe.android.feature.canvas.ui.design.DesignExportDeliveryResult
import com.floe.android.feature.canvas.ui.design.DesignOperation
import com.floe.android.feature.canvas.ui.design.DesignPreservationConstraints
import com.floe.android.feature.canvas.ui.design.DesignPreservationDraft
import com.floe.android.feature.canvas.ui.design.DesignPreviewContent
import com.floe.android.feature.canvas.ui.design.DesignProposalSource
import com.floe.android.feature.canvas.ui.design.DesignRestructureConfirmation
import com.floe.android.feature.canvas.ui.design.DesignRestructureRequest
import com.floe.android.feature.canvas.ui.design.DesignTargetDescriptor
import com.floe.android.feature.canvas.ui.design.DesignTrustedOperation
import com.floe.android.feature.canvas.ui.design.DesignUiPorts
import com.floe.android.feature.canvas.ui.design.DesignWorkflowController
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-authored controller tests (NOT RUN in this source-only stage).
 *
 * These exercise the real controller contract against an in-memory host:
 * exact expected revisions/stable operation ids, target-mismatch late
 * responses, staging retirement, trusted restructure prepare→confirm→host
 * ordering, and Canvas post-adoption refresh. They do not assert an actual
 * device/UI result.
 */
class DesignWorkflowControllerTest {
    private val canvasID = "11111111-1111-4111-8111-111111111111"
    private val documentID = "22222222-2222-4222-8222-222222222222"
    private val nodeID = "33333333-3333-4333-8333-333333333333"
    private val memberID = "44444444-4444-4444-8444-444444444444"
    private val revisionID = "55555555-5555-4555-8555-555555555555"

    private fun candidate(
        id: String = "candidate-1",
        status: DesignCandidateStatus = DesignCandidateStatus.PENDING,
    ) = DesignCandidateModel(
        id = id,
        artifactID = memberID,
        baseRevisionID = revisionID,
        proposedRevisionID = "66666666-6666-4666-8666-666666666666",
        summary = "Tighter landing hierarchy",
        diff = listOf("Hero: shorter"),
        status = status,
        createdAt = "2026-11-01T00:00:00Z",
    )

    private fun projection(
        target: DesignTargetIdentity = canvasTarget(),
        revision: Long = 3L,
        candidates: List<DesignCandidateModel> = listOf(candidate()),
    ): DesignStateProjection = DesignStateProjection(
        target = target,
        ownerRevision = revision,
        schemaVersion = 17,
        project = DesignProjectProjection(
            contentType = DesignContentType.WEBPAGE,
            brief = null,
            spec = null,
            candidates = candidates,
            frozenRun = DesignFrozenRunModel(
                operationID = "freeze-1",
                inputRevisionID = revisionID,
                workMode = DesignWorkMode.MODIFY,
                frozenAt = "2026-11-01T00:00:00Z",
            ),
            creativeRequest = null,
            appliedOperationIDs = emptyList(),
            createdAt = "2026-11-01T00:00:00Z",
            updatedAt = "2026-11-01T00:00:00Z",
            rawProject = buildJsonObject {
                put("contentType", "webpage")
                put(
                    "artifacts",
                    buildJsonArray {
                        add(
                            buildJsonObject {
                                put("id", memberID)
                                put("contentType", "webpage")
                                put("currentRevisionID", revisionID)
                                put(
                                    "revisions",
                                    buildJsonArray {
                                        add(
                                            buildJsonObject {
                                                put("id", revisionID)
                                                put("number", 1)
                                                put("payloadFormat", "html")
                                            },
                                        )
                                        add(
                                            buildJsonObject {
                                                put("id", "66666666-6666-4666-8666-666666666666")
                                                put("number", 2)
                                                put("payloadFormat", "html")
                                            },
                                        )
                                    },
                                )
                            },
                        )
                    },
                )
                put("candidates", buildJsonArray { })
            },
        ),
        writable = true,
        availableActions = listOf(
            "design.canvas.snapshot", "design.canvas.mutate", "design.canvas.adopt",
            "design.canvas.compare", "design.canvas.restore", "design.canvas.export",
            "design.canvas.preview",
        ),
    )

    private fun canvasTarget() = DesignTargetIdentity(
        kind = DesignTargetKind.CANVAS_NODE,
        ownerID = canvasID,
        documentID = documentID,
        sourceID = nodeID,
    )

    private fun binding() = DesignTargetBinding(
        target = canvasTarget(),
        storage = CreativeStorageLayer.AppOwned,
        origin = CreativeOriginContext(kind = CreativeOriginContext.CANVAS, ownerID = canvasID),
        sessionToken = "session-token-1",
    )

    private fun controller(
        host: FakeDesignHost,
        ports: FakePorts,
        refresh: (suspend () -> Boolean)? = null,
    ): DesignWorkflowController = DesignWorkflowController(
        host = host,
        binding = binding(),
        ports = ports,
        descriptor = DesignTargetDescriptor(
            title = "Landing page node",
            kindLabel = "Canvas node",
            expectedRevision = 3L,
        ),
        scope = CoroutineScope(Dispatchers.Unconfined),
        canvasRefresh = refresh,
    )

    @Test
    fun startUsesExpectedRevisionAndBriefRetryReusesOperationId() {
        val host = FakeDesignHost(projection())
        val ports = FakePorts()
        val controller = controller(host, ports)
        controller.start()
        assertEquals(3L, host.bindRequest?.expectedRevision)
        assertNotNull(controller.state)
        controller.updateDraft(DesignDraft(goal = "Publish the new landing page"))
        host.failNextBrief = true
        controller.saveBrief()
        assertEquals(DesignOperation.BRIEF, controller.failure?.operation)
        val failedOp = host.briefRequests.single().opID
        controller.saveBrief()
        assertEquals(2, host.briefRequests.size)
        assertEquals(failedOp, host.briefRequests.last().opID)
        assertNull(controller.failure)
    }

    @Test
    fun changedBriefUsesANewOperationId() {
        val host = FakeDesignHost(projection())
        val controller = controller(host, FakePorts())
        controller.start()
        controller.updateDraft(DesignDraft(goal = "First goal"))
        controller.saveBrief()
        val first = host.briefRequests.single().opID
        controller.updateDraft(DesignDraft(goal = "Second goal"))
        controller.saveBrief()
        val second = host.briefRequests.last().opID
        assertFalse(first == second)
    }

    @Test
    fun mismatchedLateResponseNeverReplacesCapturedState() {
        val host = FakeDesignHost(projection())
        val controller = controller(host, FakePorts())
        controller.start()
        val original = controller.state
        host.projection = projection(
            target = canvasTarget().copy(sourceID = "77777777-7777-4777-8777-777777777777"),
        )
        controller.refresh()
        assertEquals("designTargetMismatch", controller.failure?.code)
        assertEquals(original, controller.state)
    }

    @Test
    fun closeDiscardsStagedPayloadAndBlocksLateMutation() {
        val host = FakeDesignHost(projection())
        val ports = FakePorts()
        val controller = controller(host, ports)
        controller.start()
        controller.stageManualText("# Proposal", "md")
        val staged = controller.stagedPayload
        assertNotNull(staged)
        controller.close()
        assertEquals(listOf(staged!!.token), ports.discarded)
        controller.freeze()
        assertEquals(0, host.freezeRequests.size)
    }

    @Test
    fun restructureFreezePreparesConfirmsThenCallsHostWithSameOperation() {
        val host = FakeDesignHost(projection())
        val ports = FakePorts()
        val controller = controller(host, ports)
        controller.start()
        controller.selectWorkMode(DesignWorkMode.RESTRUCTURE)
        controller.updatePreservationDraft(
            DesignPreservationDraft(content = "Marketing copy", behavior = "Checkout flow"))
        controller.freeze()
        assertEquals(0, host.freezeRequests.size)
        val prepared = ports.prepared.single()
        assertEquals(DesignTrustedOperation.FREEZE, prepared.operation)
        assertTrue(prepared.preservation.content.contains("Marketing copy"))
        controller.confirmRestructure()
        assertTrue(ports.confirmed.isNotEmpty())
        val request = host.freezeRequests.single()
        assertEquals(prepared.opID, request.opID)
        assertEquals(DesignWorkMode.RESTRUCTURE, request.workMode)
        assertEquals(ports.confirmation.preservationDigest, request.preservationDigest)
    }

    @Test
    fun proposalUsesRealArtifactAndStagedPayloadAtExactRevision() {
        val host = FakeDesignHost(projection())
        val ports = FakePorts()
        val controller = controller(host, ports)
        controller.start()
        controller.stageManualText("# Proposal", "md")
        controller.proposalSummary = "New hero"
        controller.propose()
        val request = host.proposalRequests.single()
        assertEquals(memberID, request.artifactID)
        assertEquals(3L, request.expectedRevision)
        assertEquals("token-1", request.payload.token)
        assertEquals("candidate-1", controller.selectedCandidateID)
        assertNull(controller.stagedPayload)
    }

    @Test
    fun adoptUsesCurrentRevisionAndRefreshesCanvasOnce() {
        val host = FakeDesignHost(projection())
        var refreshes = 0
        val controller = controller(host, FakePorts(), refresh = { refreshes += 1; true })
        controller.start()
        controller.selectCandidate("candidate-1")
        controller.adopt(DesignAdoptMode.UPDATE_ORIGINAL)
        assertEquals(1, host.adoptRequests.size)
        assertEquals(3L, host.adoptRequests.single().expectedRevision)
        assertEquals(1, refreshes)
        assertFalse(controller.canvasRefreshPending)
    }

    @Test
    fun exportFormatComesFromPreservedProjectPayloadFormat() {
        val host = FakeDesignHost(projection())
        val controller = controller(host, FakePorts())
        controller.start()
        assertEquals(
            "canvas.snapshot",
            controller.formatFor(candidateID = null, revisionID = null),
        )
        assertEquals("html", controller.formatFor(candidateID = "candidate-1", revisionID = null))
    }

    private class FakeDesignHost(var projection: DesignStateProjection) : DesignHostApi {
        var bindRequest: DesignBindRequest? = null
        var failNextBrief = false
        val briefRequests = mutableListOf<DesignBriefRequest>()
        val specRequests = mutableListOf<DesignSpecRequest>()
        val freezeRequests = mutableListOf<DesignFreezeRequest>()
        val proposalRequests = mutableListOf<DesignProposalRequest>()
        val adoptRequests = mutableListOf<DesignAdoptRequest>()
        val rejectRequests = mutableListOf<DesignRejectRequest>()
        val restoreRequests = mutableListOf<DesignRestoreRequest>()

        override suspend fun bind(epoch: Long): CreativeBinding =
            CreativeBinding(epoch = epoch, bound = true)

        override suspend fun status(): DesignHostStatus = DesignHostStatus(
            bound = true,
            epoch = 7,
            rootFingerprint = "root",
            availableTargetKinds = listOf("canvasNode", "fileDocument", "chatAttachment"),
            availableActions = projection.availableActions,
            maxProposalBytes = DesignWireLimits.MAX_DESIGN_SOURCE_BYTES,
            maxPreviewBytes = DesignWireLimits.MAX_PREVIEW_BYTES,
        )

        override suspend fun state(binding: DesignTargetBinding): DesignStateProjection =
            projection

        override suspend fun bindTarget(request: DesignBindRequest): DesignStateProjection {
            bindRequest = request
            return projection
        }

        override suspend fun setBrief(request: DesignBriefRequest): DesignStateProjection {
            briefRequests += request
            if (failNextBrief) {
                failNextBrief = false
                throw CreativeException("designConflict", "briefConflict")
            }
            return projection
        }

        override suspend fun setSpec(request: DesignSpecRequest): DesignStateProjection {
            specRequests += request
            return projection
        }

        override suspend fun freeze(request: DesignFreezeRequest): DesignFreezeReceipt {
            freezeRequests += request
            return DesignFreezeReceipt(
                target = projection.target,
                ownerRevision = projection.ownerRevision,
                operationID = request.opID,
                frozenRun = projection.project.frozenRun ?: DesignFrozenRunModel(
                    operationID = request.opID,
                    frozenAt = "2026-11-01T00:00:00Z",
                ),
                idempotent = false,
            )
        }

        override suspend fun propose(request: DesignProposalRequest): DesignProposalResult {
            proposalRequests += request
            val proposed = projection.copy(ownerRevision = projection.ownerRevision + 1)
            projection = proposed
            return DesignProposalResult(
                state = proposed,
                candidate = proposed.project.candidates.first(),
                payloadRelativePath = "payloads/${request.payload.token}",
                replayed = false,
            )
        }

        override suspend fun adopt(request: DesignAdoptRequest): DesignDecisionResult {
            adoptRequests += request
            return DesignDecisionResult(
                state = projection,
                candidateID = request.candidateID,
                operationID = request.opID,
                idempotent = false,
                committedRevisionToken = "revision-token",
                delivery = DesignDelivery(DesignDeliveryState.NOT_REQUIRED),
                publication = DesignPublication(DesignPublicationState.NOT_REQUIRED),
            )
        }

        override suspend fun reject(request: DesignRejectRequest): DesignDecisionReceipt {
            rejectRequests += request
            return DesignDecisionReceipt(
                state = projection,
                candidateID = request.candidateID,
                operationID = request.opID,
                idempotent = false,
            )
        }

        override suspend fun compare(request: DesignCompareRequest): DesignComparison =
            DesignComparison(
                candidateID = request.candidateID,
                baseSHA256 = "a".repeat(64),
                proposedSHA256 = "b".repeat(64),
                changed = true,
                status = DesignCandidateStatus.PENDING,
            )

        override suspend fun restore(request: DesignRestoreRequest): DesignStateProjection {
            restoreRequests += request
            return projection
        }

        override suspend fun preview(request: DesignPreviewRequest): DesignPreviewReceipt =
            DesignPreviewReceipt(
                target = projection.target,
                ownerRevision = projection.ownerRevision,
                candidateID = request.candidateID,
                revisionID = request.revisionID ?: revisionIDString(),
                format = "html",
                rootPath = "/accepted/root/DesignArtifacts/Previews",
                relativePath = "preview.html",
                byteCount = 12,
                sha256 = "c".repeat(64),
                createdAt = "2026-11-01T00:00:00Z",
            )

        override suspend fun export(request: DesignExportRequest): DesignExportReceipt =
            DesignExportReceipt(
                target = projection.target,
                ownerRevision = projection.ownerRevision,
                candidateID = request.candidateID,
                revisionID = request.revisionID,
                format = request.format,
                rootPath = "/accepted/root/DesignArtifacts/Exports",
                relativePath = "export.${request.format}",
                byteCount = 12,
                sha256 = "d".repeat(64),
                createdAt = "2026-11-01T00:00:00Z",
            )

        private fun revisionIDString(): String =
            projection.project.inspectArtifactsForTest().firstOrNull()
                ?.currentRevision?.revisionID.orEmpty()
    }

    private class FakePorts : DesignUiPorts {
        val discarded = mutableListOf<String>()
        val prepared = mutableListOf<DesignRestructureRequest>()
        val confirmed = mutableListOf<DesignRestructureConfirmation>()
        val revoked = mutableListOf<DesignRestructureConfirmation>()
        var confirmation = DesignRestructureConfirmation(
            token = "confirm-token",
            targetKey = "target",
            operationID = "",
            originalTaskOwnerID = null,
            baseRevisionID = null,
            preservationDigest = "e".repeat(64),
            preservation = DesignPreservationConstraints(),
            expiresAt = "",
        )

        override suspend fun stageProposal(
            source: DesignProposalSource,
            sessionToken: String,
        ): StagedDesignPayload = StagedDesignPayload(
            token = "token-1",
            format = "md",
            byteCount = 9,
            sha256 = "f".repeat(64),
        )

        override fun discardProposal(token: String) {
            discarded += token
        }

        override suspend fun openPreview(
            receipt: DesignPreviewReceipt,
            binding: DesignTargetBinding,
        ): DesignPreviewContent = DesignPreviewContent.Text(
            text = "preview",
            format = receipt.format,
            truncated = false,
        )

        override suspend fun deliverExport(
            receipt: DesignExportReceipt,
            binding: DesignTargetBinding,
        ): DesignExportDeliveryResult = DesignExportDeliveryResult.Delivered(
            byteCount = receipt.byteCount,
            sha256 = receipt.sha256,
        )

        override suspend fun prepareRestructure(
            request: DesignRestructureRequest,
        ): DesignRestructureConfirmation {
            prepared += request
            confirmation = confirmation.copy(
                operationID = request.opID,
                targetKey = request.binding.target.sourceID,
                baseRevisionID = request.baseRevisionID,
                preservationDigest = "e".repeat(64),
                preservation = request.preservation,
            )
            return confirmation
        }

        override suspend fun confirmRestructure(
            confirmation: DesignRestructureConfirmation,
            binding: DesignTargetBinding,
        ): Boolean {
            confirmed += confirmation
            return true
        }

        override suspend fun revokeRestructure(
            confirmation: DesignRestructureConfirmation,
            binding: DesignTargetBinding,
        ) {
            revoked += confirmation
        }
    }
}

private fun DesignProjectProjection.inspectArtifactsForTest(): List<TestArtifact> {
    val artifacts = rawProject["artifacts"]
        as? kotlinx.serialization.json.JsonArray ?: return emptyList()
    return artifacts.mapNotNull { item ->
        val artifact = item as? kotlinx.serialization.json.JsonObject ?: return@mapNotNull null
        val current = (artifact["currentRevisionID"] as? kotlinx.serialization.json.JsonPrimitive)
            ?.content
        val revisions = (artifact["revisions"]
            as? kotlinx.serialization.json.JsonArray).orEmpty()
        TestArtifact(
            currentRevision = revisions.mapNotNull { revision ->
                val value = revision as? kotlinx.serialization.json.JsonObject
                    ?: return@mapNotNull null
                val id = (value["id"] as? kotlinx.serialization.json.JsonPrimitive)?.content
                    ?: return@mapNotNull null
                if (id == current) TestRevision(id) else null
            }.firstOrNull(),
        )
    }
}

private data class TestArtifact(val currentRevision: TestRevision?)
private data class TestRevision(val revisionID: String)
