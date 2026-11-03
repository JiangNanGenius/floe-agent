// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import android.net.Uri
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignBriefModel
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignProjectProjection
import com.floe.android.feature.canvas.DesignStateProjection
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.DesignTargetIdentity
import com.floe.android.feature.canvas.DesignTargetKind
import com.floe.android.feature.canvas.StagedDesignPayload
import com.floe.android.feature.canvas.ui.design.DesignSessionProvider
import com.floe.android.feature.canvas.ui.design.DesignSessionRequest
import com.floe.android.feature.canvas.ui.design.DesignWorkflowController
import com.floe.android.host.creative.CreativeDesignAsset
import com.floe.android.host.creative.CreativeDesignAssetPage
import com.floe.android.host.creative.CreativeDesignImportReceipt
import com.floe.android.host.creative.CreativeDesignPendingPage
import com.floe.android.host.creative.CreativeDesignPendingRequest
import com.floe.android.host.creative.CreativeDesignRequestState
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-authored creative-library entry tests (NOT RUN here).
 *
 * They exercise the real state machine against the PUBLISHED creative host
 * seam: explicit output kind, fresh request identity (never a grant/UUID
 * prompt), bounded pages, stable selection op ids across a transport-unknown
 * retry, exact expected revisions, pending reopen with the SAME frozen target,
 * and typed inventory failures that are not shown as an empty fake list.
 */
class CreativeDesignEntryControllerTest {
    private val now = "2026-11-01T00:00:00Z"
    private val conversationID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val messageID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val attachmentID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    private fun asset(
        format: String,
        name: String = "material.$format",
        selectable: Boolean = true,
    ) = CreativeDesignAsset(
        assetID = UUID.randomUUID().toString(),
        displayName = name,
        kind = "image",
        format = format,
        byteCount = 2048L,
        contentSHA256 = "a".repeat(64),
        updatedAt = now,
        selectable = selectable,
    )

    private fun projection(
        target: DesignTargetIdentity,
        revision: Long,
        stateWire: String,
        boundFormat: String? = null,
    ): DesignStateProjection = DesignStateProjection(
        target = target,
        ownerRevision = revision,
        schemaVersion = 17,
        project = DesignProjectProjection(
            contentType = target.requestedOutputKind ?: DesignContentType.COMPOSITION,
            candidates = emptyList(),
            creativeRequest = buildJsonObject {
                put("state", stateWire)
                boundFormat?.let { put("boundFormat", it) }
            },
            appliedOperationIDs = emptyList(),
            createdAt = now,
            updatedAt = now,
            rawProject = buildJsonObject {
                put("contentType", target.requestedOutputKind?.wire ?: "composition")
            },
        ),
        creativeFirstResultProvenance = if (stateWire == "firstResultBound") {
            buildJsonObject { put("boundResultID", "bound") }
        } else {
            null
        },
        writable = true,
        availableActions = listOf("design.owner.state", "design.owner.brief"),
    )

    private data class BindCall(
        val binding: DesignTargetBinding,
        val expectedRevision: Long?,
        val opID: String,
    )

    private data class RetainedCall(
        val binding: DesignTargetBinding,
        val expectedRevision: Long,
        val opID: String,
        val assetID: String,
    )

    private data class ImportCall(
        val binding: DesignTargetBinding,
        val expectedRevision: Long,
        val opID: String,
        val payload: StagedDesignPayload,
    )

    private data class PageCall(val cursor: String?, val limit: Int)

    private inner class FakeHost : CreativeDesignEntryHost {
        val binds = mutableListOf<BindCall>()
        val begins = mutableListOf<Triple<DesignTargetBinding, Long, DesignBriefModel>>()
        val retained = mutableListOf<RetainedCall>()
        val imports = mutableListOf<ImportCall>()
        val discarded = mutableListOf<String>()
        val assetCalls = mutableListOf<PageCall>()
        val pendingCalls = mutableListOf<PageCall>()

        var bindFailure: CreativeException? = null
        var retainedFailure: CreativeException? = null
        var importFailure: CreativeException? = null
        var assetFailure: CreativeException? = null
        var pendingFailure: CreativeException? = null
        var bindWire: String = "awaitingFirstResult"
        var retainedWire: String = "firstResultBound"
        // A REAL creative `design.owner.bind` persists the creative START
        // request (requested kind) and therefore returns revision 1, not the
        // generic pre-write revision 0; a following brief begin advances to 2.
        var bindRevision: Long = 1L
        var beginRevision: Long = 2L
        var retainedRevision: Long = 3L
        var importRevision: Long = 4L
        var assetPage: CreativeDesignAssetPage =
            CreativeDesignAssetPage(emptyList(), nextCursor = null)
        var pendingPages: MutableList<CreativeDesignPendingPage> = mutableListOf(
            CreativeDesignPendingPage(emptyList(), nextCursor = null),
        )

        override suspend fun bind(
            binding: DesignTargetBinding,
            expectedRevision: Long?,
            opID: String,
        ): DesignStateProjection {
            binds += BindCall(binding, expectedRevision, opID)
            bindFailure?.let { throw it }
            return projection(binding.target, bindRevision, bindWire)
        }

        override suspend fun begin(
            binding: DesignTargetBinding,
            expectedRevision: Long,
            opID: String,
            brief: DesignBriefModel,
        ): DesignStateProjection {
            begins += Triple(binding, expectedRevision, brief)
            return projection(binding.target, beginRevision, bindWire)
        }

        override suspend fun retainedAssets(
            cursor: String?,
            limit: Int,
        ): CreativeDesignAssetPage {
            assetCalls += PageCall(cursor, limit)
            assetFailure?.let { throw it }
            return assetPage
        }

        override suspend fun pendingRequests(
            cursor: String?,
            limit: Int,
        ): CreativeDesignPendingPage {
            pendingCalls += PageCall(cursor, limit)
            pendingFailure?.let { throw it }
            val index = if (cursor == null) 0 else 1
            return pendingPages[minOf(index, pendingPages.lastIndex)]
        }

        override suspend fun bindRetained(
            binding: DesignTargetBinding,
            expectedRevision: Long,
            opID: String,
            assetID: String,
            displayName: String?,
        ): DesignStateProjection {
            retained += RetainedCall(binding, expectedRevision, opID, assetID)
            retainedFailure?.let { throw it }
            return projection(binding.target, retainedRevision, retainedWire)
        }

        override suspend fun stage(
            source: Uri,
            sessionToken: String,
        ): StagedDesignPayload = throw UnsupportedOperationException("stage is platform IO")

        override suspend fun importStaged(
            binding: DesignTargetBinding,
            expectedRevision: Long,
            opID: String,
            payload: StagedDesignPayload,
            displayName: String?,
        ): CreativeDesignImportReceipt {
            imports += ImportCall(binding, expectedRevision, opID, payload)
            importFailure?.let { throw it }
            return CreativeDesignImportReceipt(
                state = projection(binding.target, importRevision, "firstResultBound"),
                asset = CreativeDesignAsset(
                    assetID = UUID.randomUUID().toString(),
                    displayName = displayName ?: "material.png",
                    kind = "image",
                    format = payload.format,
                    byteCount = payload.byteCount,
                    contentSHA256 = payload.sha256,
                    updatedAt = now,
                    selectable = true,
                ),
                imported = true,
            )
        }

        override fun discardStaged(token: String) {
            discarded += token
        }
    }

    private class FakeSessions : DesignSessionProvider {
        var acquired = 0

        override fun acquire(request: DesignSessionRequest): DesignWorkflowController {
            acquired += 1
            throw UnsupportedOperationException("workflow sheet is a Compose gate")
        }

        override fun release(controller: DesignWorkflowController) = Unit
    }

    private fun controller(host: FakeHost, sessions: DesignSessionProvider = FakeSessions()):
        CreativeDesignEntryController {
        val ids = ArrayDeque(
            List(16) { UUID.randomUUID().toString() },
        )
        return CreativeDesignEntryController(
            host = host,
            sessions = sessions,
            scope = CoroutineScope(Dispatchers.Unconfined),
            newSessionToken = { CreativeSessionTokens.newToken() },
            newOperationID = { ids.removeFirst() },
            now = { now },
        )
    }

    @Test
    fun createRequestUsesExplicitKindAndAFreshIdentityNotAGrant() {
        val host = FakeHost()
        host.assetPage = CreativeDesignAssetPage(
            assets = listOf(asset("png", "poster.png"), asset("pdf", "brief.pdf")),
            nextCursor = null,
        )
        val controller = controller(host)
        controller.selectKind(DesignContentType.IMAGE)
        controller.updateBrief("Family poster")
        controller.createRequest()

        assertEquals(1, host.binds.size)
        val bind = host.binds.single()
        assertEquals(DesignTargetKind.CREATIVE_DOCUMENT, bind.binding.target.kind)
        assertEquals("creative-library", bind.binding.target.ownerID)
        assertEquals(DesignContentType.IMAGE, bind.binding.target.requestedOutputKind)
        assertNull(bind.expectedRevision)
        assertTrue(bind.binding.storage is CreativeStorageLayer.AppOwned)
        assertEquals(CreativeOriginContext.STANDALONE, bind.binding.origin?.kind)
        assertTrue(CreativeSessionTokens.isValid(bind.binding.sessionToken))
        assertNotEquals(bind.binding.sessionToken, bind.binding.target.sourceID)
        assertEquals(bind.binding.target.sourceID, UUID.fromString(bind.binding.target.sourceID).toString())

        assertEquals(1, host.begins.size)
        assertEquals(bind.binding, host.begins.single().first)
        assertEquals("Family poster", host.begins.single().third.goal)
        assertEquals(1L, host.begins.single().second)

        val active = controller.active
        assertNotNull(active)
        val resolved = active!!
        assertEquals(2L, resolved.ownerRevision)
        assertEquals(CreativeDesignRequestState.AWAITING_FIRST_RESULT, resolved.requestState)

        assertEquals(2, controller.assets.size)
        assertTrue(controller.assets.first { it.asset.format == "png" }.matchesRequestedKind)
        assertFalse(controller.assets.first { it.asset.format == "pdf" }.matchesRequestedKind)
        assertEquals(24, host.assetCalls.last().limit)
        assertNull(controller.failure)
    }

    @Test
    fun createRetryReusesTheSameRequestIdentityAndBindOperation() {
        val host = FakeHost()
        host.bindFailure = CreativeException("designUnavailable", "transportUnknown", true)
        val controller = controller(host)
        controller.createRequest()
        assertNotNull(controller.failure)
        assertEquals(1, host.binds.size)

        host.bindFailure = null
        controller.createRequest()
        assertEquals(2, host.binds.size)
        assertEquals(host.binds[0].binding, host.binds[1].binding)
        assertEquals(host.binds[0].opID, host.binds[1].opID)
        assertNotNull(controller.active)
    }

    @Test
    fun retainedBindKeepsAStableOperationIdAcrossATransportRetry() {
        val host = FakeHost()
        host.assetPage = CreativeDesignAssetPage(
            assets = listOf(asset("png", "poster.png")),
            nextCursor = null,
        )
        val controller = controller(host)
        controller.selectKind(DesignContentType.IMAGE)
        controller.createRequest()
        val material = controller.assets.single()
        val sourceID = controller.active!!.binding.target.sourceID

        host.retainedFailure = CreativeException("designUnavailable", "transportUnknown", true)
        controller.chooseRetained(material)
        assertEquals(1, host.retained.size)
        assertNotNull(controller.failure)
        assertTrue(host.retained[0].opID.startsWith("bind-$sourceID-"))
        assertEquals(material.asset.assetID, host.retained[0].assetID)
        assertEquals(1L, host.retained[0].expectedRevision)

        host.retainedFailure = null
        controller.chooseRetained(material)
        assertEquals(2, host.retained.size)
        assertEquals(host.retained[0].opID, host.retained[1].opID)
        assertEquals(1L, host.retained[1].expectedRevision)
        assertEquals(
            CreativeDesignRequestState.FIRST_RESULT_BOUND,
            controller.active!!.requestState,
        )
        assertEquals("poster.png", controller.active!!.boundAssetName)
        assertEquals("png", controller.active!!.boundFormat)
    }

    @Test
    fun importRetryUsesTheSameStagedPayloadAndOperationId() {
        val host = FakeHost()
        val controller = controller(host)
        controller.selectKind(DesignContentType.IMAGE)
        controller.createRequest()
        val payload = StagedDesignPayload(
            token = "staged-token",
            format = "png",
            byteCount = 2048L,
            sha256 = "d".repeat(64),
        )
        host.importFailure = CreativeException("designPayloadMissing", "stagedPayloadUnreadable", true)
        controller.importVerifiedStagedPayload(payload, "photo.png", "import-source-1")
        assertEquals(1, host.imports.size)
        assertNotNull(controller.failure)
        assertEquals("staged-token", controller.active!!.pendingImport?.payload?.token)

        host.importFailure = null
        controller.retryImport()
        assertEquals(2, host.imports.size)
        assertEquals("import-source-1", host.imports[0].opID)
        assertEquals(host.imports[0].opID, host.imports[1].opID)
        assertEquals("staged-token", host.imports[1].payload.token)
        assertEquals(1L, host.imports[1].expectedRevision)
        assertEquals(
            CreativeDesignRequestState.FIRST_RESULT_BOUND,
            controller.active!!.requestState,
        )
        assertNull(controller.active!!.pendingImport)
        assertEquals("photo.png", controller.active!!.boundAssetName)
    }

    @Test
    fun closingThePanelDiscardsTheUnreferencedStagedImport() {
        val host = FakeHost()
        val controller = controller(host)
        controller.selectKind(DesignContentType.IMAGE)
        controller.createRequest()
        val payload = StagedDesignPayload(
            token = "staged-close",
            format = "png",
            byteCount = 1024L,
            sha256 = "e".repeat(64),
        )
        host.importFailure = CreativeException("designPayloadMissing", "stagedPayloadUnreadable", true)
        controller.importVerifiedStagedPayload(payload, "photo.png", "import-close")
        controller.closePanel()
        assertNull(controller.active)
        assertTrue(host.discarded.contains("staged-close"))
    }

    @Test
    fun pendingReopenBindsTheExactFrozenTargetAndRevision() {
        val host = FakeHost()
        val target = DesignTargetIdentity(
            kind = DesignTargetKind.CREATIVE_DOCUMENT,
            ownerID = "creative-library",
            documentID = "",
            sourceID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            originConversationID = conversationID,
            requestedOutputKind = DesignContentType.PDF,
        )
        val request = CreativeDesignPendingRequest(
            targetKey = "f".repeat(64),
            ownerRevision = 7L,
            target = target,
            storage = CreativeStorageLayer.AppOwned,
            requestedOutputKind = DesignContentType.PDF,
            state = CreativeDesignRequestState.FIRST_RESULT_BOUND,
            boundResultID = UUID.randomUUID().toString(),
            boundFormat = "pdf",
            boundContentSHA256 = "a".repeat(64),
            originConversationID = conversationID,
            environmentID = null,
            updatedAt = now,
        )
        host.bindWire = "firstResultBound"
        host.bindRevision = 7L
        val controller = controller(host)
        controller.reopen(request)

        assertEquals(1, host.binds.size)
        assertEquals(7L, host.binds.single().expectedRevision)
        assertEquals(target, host.binds.single().binding.target)
        assertTrue(host.binds.single().binding.storage is CreativeStorageLayer.AppOwned)
        assertTrue(CreativeSessionTokens.isValid(host.binds.single().binding.sessionToken))
        assertEquals(CreativeDesignRequestState.FIRST_RESULT_BOUND, controller.active!!.requestState)
        assertEquals("pdf", controller.active!!.boundFormat)
        // Reopen must NOT mint a different request identity.
        assertEquals(target.sourceID, controller.active!!.binding.target.sourceID)
    }

    @Test
    fun pendingAndAssetsPagesAreBoundedAndCursorDisjoint() {
        val host = FakeHost()
        host.assetPage = CreativeDesignAssetPage(
            assets = listOf(asset("png", "one.png")),
            nextCursor = "cursor-2",
        )
        host.pendingPages = mutableListOf(
            CreativeDesignPendingPage(
                requests = listOf(pendingRequest("1111")),
                nextCursor = "cursor-2",
            ),
            CreativeDesignPendingPage(
                requests = listOf(pendingRequest("2222")),
                nextCursor = null,
            ),
        )
        val controller = controller(host)
        controller.refreshPending()
        assertEquals(1, controller.pending.size)
        assertTrue(controller.pendingHasMore)
        controller.loadMorePending()
        assertEquals(2, controller.pending.size)
        assertFalse(controller.pendingHasMore)
        assertEquals(2, host.pendingCalls.size)
        assertNull(host.pendingCalls[0].cursor)
        assertEquals("cursor-2", host.pendingCalls[1].cursor)
        assertEquals(24, host.pendingCalls[0].limit)
    }

    @Test
    fun inventoryUnavailableIsTypedRatherThanAnEmptyFakeList() {
        val host = FakeHost()
        host.assetFailure = CreativeException(
            "designTargetUnavailable",
            "creativeAssetInventoryRequiresAcceptedDatabase",
            retryable = false,
        )
        val controller = controller(host)
        controller.selectKind(DesignContentType.IMAGE)
        controller.createRequest()
        val failure = controller.assetsFailure
        assertNotNull(failure)
        assertEquals("creativeAssetInventoryRequiresAcceptedDatabase", failure!!.reason)
        assertTrue(controller.assets.isEmpty())
        assertNotNull(controller.active)
    }

    private fun pendingRequest(suffix: String) = CreativeDesignPendingRequest(
        targetKey = (suffix + "0".repeat(64)).take(64),
        ownerRevision = 3L,
        target = DesignTargetIdentity(
            kind = DesignTargetKind.CREATIVE_DOCUMENT,
            ownerID = "creative-library",
            documentID = "",
            sourceID = UUID.randomUUID().toString(),
            requestedOutputKind = DesignContentType.IMAGE,
        ),
        storage = CreativeStorageLayer.AppOwned,
        requestedOutputKind = DesignContentType.IMAGE,
        state = CreativeDesignRequestState.AWAITING_FIRST_RESULT,
        boundResultID = null,
        boundFormat = null,
        boundContentSHA256 = null,
        originConversationID = null,
        environmentID = null,
        updatedAt = now,
    )
}
