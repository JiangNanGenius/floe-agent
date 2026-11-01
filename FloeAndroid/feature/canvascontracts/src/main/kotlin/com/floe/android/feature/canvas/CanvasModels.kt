// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas

import kotlinx.serialization.json.JsonObject

/**
 * Canvas schema-7 project projection.
 *
 * Field names are the exact `floe.creative/5` wire names. UUID-keyed Swift
 * dictionaries are transported as alternating arrays:
 * `viewports = [documentID, viewportState, ...]` and
 * `agentConversationIDsByDocument = [documentID, conversationID, ...]`.
 * A JSON object is NOT accepted for those two fields.
 */
data class CanvasPoint(val x: Double, val y: Double)

data class CanvasSize(val width: Double, val height: Double)

data class CanvasViewportState(
    val center: CanvasPoint = CanvasPoint(0.0, 0.0),
    val scale: Double = 1.0,
)

/** One entry of the alternating `viewports` wire array. */
data class CanvasViewportEntry(
    val documentID: String,
    val viewport: CanvasViewportState,
)

/** One entry of the alternating `agentConversationIDsByDocument` wire array. */
data class CanvasConversationBinding(
    val documentID: String,
    val conversationID: String,
)

data class CanvasAssetReference(
    val id: String,
    val contentHash: String? = null,
    val localRelativePath: String? = null,
    val cloudRecordName: String? = null,
    val mimeType: String? = null,
    val byteCount: Long? = null,
    val sourceURL: String? = null,
    val license: String? = null,
)

data class CanvasNode(
    val id: String,
    val kind: String,
    val title: String? = null,
    val text: String = "",
    val position: CanvasPoint,
    val size: CanvasSize,
    val rotation: Double = 0.0,
    val zIndex: Int = 0,
    val isLocked: Boolean = false,
    val groupID: String? = null,
    val shape: String? = null,
    val asset: CanvasAssetReference? = null,
    val generationJobID: String? = null,
    /** Opaque 3D scene; R1 edits only basic 2D nodes and preserves this. */
    val scene3D: JsonObject? = null,
    val sourceURLs: List<String> = emptyList(),
    val createdByRunID: String? = null,
    val metadata: Map<String, String> = emptyMap(),
)

data class CanvasConnection(
    val id: String,
    val sourceNodeID: String,
    val destinationNodeID: String,
    val kind: String = "arrow",
    val label: String? = null,
    val sourcePort: String? = null,
    val destinationPort: String? = null,
)

data class CanvasStroke(
    val id: String,
    val points: List<CanvasPoint>,
    val width: Double = 3.0,
    val color: String = "primary",
    val isEraser: Boolean = false,
)

data class CanvasDocument(
    val id: String,
    val name: String,
    val nodes: List<CanvasNode> = emptyList(),
    val connections: List<CanvasConnection> = emptyList(),
    val strokes: List<CanvasStroke> = emptyList(),
    /** Swift `Data` is base64 on the wire. */
    val pencilDrawingData: String? = null,
    val backgroundStyle: String? = "grid",
    val createdAt: String,
    val updatedAt: String,
)

data class CanvasAssistantSession(
    val id: String,
    val conversationID: String,
    val title: String,
    val createdAt: String,
    val updatedAt: String,
)

data class CanvasSyncSettings(
    val isEnabled: Boolean = true,
    val revision: Long = 0,
    val lastSyncedAt: String? = null,
    val pendingReleaseBytes: Long = 0,
)

data class CanvasProject(
    val id: String,
    val schemaVersion: Int = 7,
    /** Logical link only; canvas files are always app-owned. */
    val workspaceID: String? = null,
    val name: String,
    val documents: List<CanvasDocument>,
    val selectedDocumentID: String,
    val agentConversationID: String? = null,
    val assistantSessions: List<CanvasAssistantSession> = emptyList(),
    val selectedAssistantSessionID: String? = null,
    val agentConversationIDsByDocument: List<CanvasConversationBinding> = emptyList(),
    val viewports: List<CanvasViewportEntry> = emptyList(),
    val revision: Long,
    val sync: CanvasSyncSettings = CanvasSyncSettings(),
    /** Preserved opaque CAD/design metadata; R1 never edits it. */
    val designProjectAuthority: JsonObject? = null,
    val createdAt: String,
    val updatedAt: String,
)

data class CanvasProjectSummary(
    val id: String,
    val name: String,
    val revision: Long,
    val updatedAt: String,
    val schemaVersion: Int,
    val documentCount: Int,
    val corrupt: Boolean,
    val writable: Boolean,
)

data class CanvasProjectEnvelope(
    val project: CanvasProject,
    /** Read-only trusted Materials directory; never accepted as a write path. */
    val assetsBasePath: String,
    val writable: Boolean,
    val recoveryWarnings: List<String> = emptyList(),
)

data class CanvasPatchOperation(
    val id: String,
    val kind: String,
    val nodeID: String? = null,
    val nodeIDs: List<String>? = null,
    val nodeKind: String? = null,
    val text: String? = null,
    val position: CanvasPoint? = null,
    val size: CanvasSize? = null,
    val rotation: Double? = null,
    val isLocked: Boolean? = null,
    val shape: String? = null,
    val asset: CanvasAssetReference? = null,
    val generationJobID: String? = null,
    val createdByRunID: String? = null,
    val metadata: Map<String, String>? = null,
    val removedMetadataKeys: List<String>? = null,
    val sourceNodeID: String? = null,
    val destinationNodeID: String? = null,
    val connectionID: String? = null,
    val connectionKind: String? = null,
    val sourcePort: String? = null,
    val destinationPort: String? = null,
    val label: String? = null,
    val arrangement: String? = null,
)

data class CanvasPatch(
    val canvasID: String,
    val documentID: String,
    val expectedRevision: Long,
    val operations: List<CanvasPatchOperation>,
)

data class CanvasPatchRequest(
    val canvasID: String,
    val expectedRevision: Long,
    val sessionToken: String,
    val opID: String,
    val patch: CanvasPatch,
)

data class CanvasOperationResult(
    val canvasID: String,
    val documentID: String?,
    val previousRevision: Long,
    val revision: Long,
    val changedNodeIDs: List<String>,
    val changedConnectionIDs: List<String>,
    val undoToken: String?,
    val opID: String,
    val idempotent: Boolean,
)

data class CanvasMutationReceipt(
    val canvasID: String,
    val name: String?,
    val revision: Long,
    val deleted: Boolean,
    val opID: String,
    val idempotent: Boolean,
)

data class CanvasAssetReferenceOperation(
    val opID: String,
    val assetID: String,
    val delta: Int,
)

data class CanvasRecoveryState(
    val canvasID: String,
    val pendingOperations: Int,
    val appliedOperations: Int,
    val warnings: List<String> = emptyList(),
)

data class CanvasAssetReceipt(
    val asset: CanvasAssetReference,
    val deduplicated: Boolean,
    val opID: String,
    val idempotent: Boolean,
)

fun CanvasProject.viewport(documentID: String): CanvasViewportState? =
    viewports.firstOrNull { it.documentID == documentID }?.viewport

fun CanvasProject.conversationID(documentID: String): String? =
    agentConversationIDsByDocument.firstOrNull { it.documentID == documentID }?.conversationID

fun CanvasDocument.node(id: String): CanvasNode? = nodes.firstOrNull { it.id == id }
