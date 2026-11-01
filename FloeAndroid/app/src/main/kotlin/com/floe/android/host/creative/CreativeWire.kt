// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CanvasAssetReceipt
import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.CanvasAssetReferenceOperation
import com.floe.android.feature.canvas.CanvasConnection
import com.floe.android.feature.canvas.CanvasConversationBinding
import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasMutationReceipt
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasOperationResult
import com.floe.android.feature.canvas.CanvasPatch
import com.floe.android.feature.canvas.CanvasPatchOperation
import com.floe.android.feature.canvas.CanvasPatchRequest
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasProject
import com.floe.android.feature.canvas.CanvasProjectEnvelope
import com.floe.android.feature.canvas.CanvasProjectSummary
import com.floe.android.feature.canvas.CanvasRecoveryState
import com.floe.android.feature.canvas.CanvasSize
import com.floe.android.feature.canvas.CanvasStroke
import com.floe.android.feature.canvas.CanvasSyncSettings
import com.floe.android.feature.canvas.CanvasViewportEntry
import com.floe.android.feature.canvas.CanvasViewportState
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeLimits
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeServiceStatus
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.ImageFreehandContent
import com.floe.android.feature.workbench.ImageFreehandPoint
import com.floe.android.feature.workbench.ImageFreehandStroke
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerAdjustment
import com.floe.android.feature.workbench.ImageLayerTransform
import com.floe.android.feature.workbench.ImageTextContent
import com.floe.android.feature.workbench.ImageTextShadow
import com.floe.android.feature.workbench.MediaAssetMetadata
import com.floe.android.feature.workbench.MediaAssetReceipt
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaCanvas
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.MediaMutationReceipt
import com.floe.android.feature.workbench.MediaProject
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.MediaProjectReceipt
import com.floe.android.feature.workbench.MediaProjectSummary
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.OptionalUpdate
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Exact `floe.creative/5` wire projection. Hand-written on purpose: the
 * contract modules stay free of generated serializers, the native schema is
 * the closed vocabulary, and UUID-keyed Swift dictionaries are decoded from
 * their alternating-array form rather than assumed to be JSON objects.
 */
internal object CreativeWire {
    const val VERSION = 5
    const val SCHEMA = "floe.creative/5"

    private val json = Json { isLenient = false; ignoreUnknownKeys = true }

    // MARK: - Envelope

    fun request(
        operation: String,
        requestID: String,
        epoch: Long? = null,
        action: String? = null,
        payload: JsonObject? = null,
    ): JsonObject = buildJsonObject {
        put("version", VERSION)
        put("operation", operation)
        put("requestID", requestID)
        if (epoch != null) put("epoch", epoch)
        if (action != null) put("action", action)
        if (payload != null) put("payload", payload)
    }

    fun response(raw: String): JsonObject {
        val objectValue = try {
            json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw CreativeException("invalidCoreResponse", "malformedJSON")
        val version = objectValue.long("version")?.toInt() ?: 0
        if (version != VERSION) {
            val error = objectValue.string("error")
            if (version < VERSION || error == "unsupportedVersion") {
                throw CreativeException(
                    "needsCoreUpdate", "creativeBridgeV5Unsupported", retryable = false)
            }
            if (version > VERSION) {
                throw CreativeException(
                    "coreTooNew", "creativeBridgeVersionUnsupported", retryable = false)
            }
            throw CreativeException("invalidCoreResponse", "missingVersion")
        }
        if (objectValue.bool("ok") != true) {
            throw CreativeException(
                code = objectValue.string("error") ?: "unknownError",
                reason = objectValue.string("reason"),
                retryable = objectValue.bool("retryable") ?: false,
            )
        }
        return objectValue
    }

    fun handshakeState(response: JsonObject): CreativeServiceStatus {
        if (response.string("schema") != SCHEMA) {
            throw CreativeException("needsCoreUpdate", "creativeSchemaMismatch")
        }
        val actions = response.array("actions")?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()
        if (!actions.contains("canvas.patch") || !actions.contains("media.project.apply")) {
            throw CreativeException("needsCoreUpdate", "creativeActionsMissing")
        }
        return CreativeServiceStatus(
            availability = com.floe.android.feature.canvas.CreativeAvailability.Available,
            boundEpoch = null,
            schema = SCHEMA,
            actions = actions,
            requestMaxBytes = response.int("requestMaxBytes") ?: 0,
            responseMaxBytes = response.int("responseMaxBytes") ?: 0,
            canvasSchemaVersion = response.int("canvasSchemaVersion") ?: 0,
            mediaSchemaVersion = response.int("mediaSchemaVersion") ?: 0,
        )
    }

    // MARK: - Storage layer

    fun encodeOrigin(origin: CreativeOriginContext): JsonObject = buildJsonObject {
        put("kind", origin.kind)
        origin.ownerID?.let { put("ownerID", it) }
        origin.environmentID?.let { put("environmentID", it) }
    }

    fun decodeClosed(value: JsonObject): Boolean = value.bool("closed") ?: false

    fun encodeStorage(layer: CreativeStorageLayer): JsonObject = when (layer) {
        CreativeStorageLayer.AppOwned -> buildJsonObject { put("kind", "appOwned") }
        is CreativeStorageLayer.Workspace -> buildJsonObject {
            put("kind", "workspace")
            put("workspaceID", layer.workspaceID)
        }
    }

    fun decodeStorage(value: JsonElement?): CreativeStorageLayer {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "missingStorage")
        return when (objectValue.string("kind")) {
            "appOwned" -> CreativeStorageLayer.AppOwned
            "workspace" -> CreativeStorageLayer.Workspace(
                objectValue.string("workspaceID")
                    ?: throw CreativeException("invalidResponse", "missingWorkspaceID"))
            else -> throw CreativeException("invalidResponse", "invalidStorageKind")
        }
    }

    // MARK: - Canvas encode

    fun encodeCanvasPatch(request: CanvasPatchRequest): JsonObject = buildJsonObject {
        put("canvasID", request.canvasID)
        put("expectedRevision", request.expectedRevision)
        put("sessionToken", request.sessionToken)
        put("opID", request.opID)
        put("patch", encodeCanvasPatchBody(request.patch))
    }

    private fun encodeCanvasPatchBody(patch: CanvasPatch): JsonObject = buildJsonObject {
        put("canvasID", patch.canvasID)
        put("documentID", patch.documentID)
        put("expectedRevision", patch.expectedRevision)
        putJsonArray("operations") { patch.operations.forEach { add(encodeCanvasOperation(it)) } }
    }

    private fun encodeCanvasOperation(value: CanvasPatchOperation): JsonObject = buildJsonObject {
        put("id", value.id)
        put("kind", value.kind)
        nullable("nodeID", value.nodeID)
        value.nodeIDs?.let { ids -> putJsonArray("nodeIDs") { ids.forEach { add(JsonPrimitive(it)) } } }
        nullable("nodeKind", value.nodeKind)
        nullable("text", value.text)
        value.position?.let { put("position", encodePoint(it)) }
        value.size?.let { put("size", encodeSize(it)) }
        value.rotation?.let { put("rotation", it) }
        value.isLocked?.let { put("isLocked", it) }
        nullable("shape", value.shape)
        value.asset?.let { put("asset", encodeCanvasAsset(it)) }
        nullable("generationJobID", value.generationJobID)
        nullable("createdByRunID", value.createdByRunID)
        value.metadata?.let { metadata ->
            putJsonObject("metadata") { metadata.forEach { (key, item) -> put(key, item) } }
        }
        value.removedMetadataKeys?.let { keys ->
            putJsonArray("removedMetadataKeys") { keys.forEach { add(JsonPrimitive(it)) } }
        }
        nullable("sourceNodeID", value.sourceNodeID)
        nullable("destinationNodeID", value.destinationNodeID)
        nullable("connectionID", value.connectionID)
        nullable("connectionKind", value.connectionKind)
        nullable("sourcePort", value.sourcePort)
        nullable("destinationPort", value.destinationPort)
        nullable("label", value.label)
        nullable("arrangement", value.arrangement)
    }

    private fun encodePoint(value: CanvasPoint): JsonObject = buildJsonObject {
        put("x", value.x); put("y", value.y)
    }

    private fun encodeSize(value: CanvasSize): JsonObject = buildJsonObject {
        put("width", value.width); put("height", value.height)
    }

    private fun encodeCanvasAsset(value: CanvasAssetReference): JsonObject = buildJsonObject {
        put("id", value.id)
        nullable("contentHash", value.contentHash)
        nullable("localRelativePath", value.localRelativePath)
        nullable("cloudRecordName", value.cloudRecordName)
        nullable("mimeType", value.mimeType)
        value.byteCount?.let { put("byteCount", it) }
        nullable("sourceURL", value.sourceURL)
        nullable("license", value.license)
    }

    // MARK: - Canvas decode

    fun decodeCanvasSummary(value: JsonElement): CanvasProjectSummary {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasSummary")
        return CanvasProjectSummary(
            id = objectValue.string("id") ?: throw CreativeException("invalidResponse", "missingCanvasID"),
            name = objectValue.string("name").orEmpty(),
            revision = objectValue.long("revision") ?: 0,
            updatedAt = objectValue.string("updatedAt").orEmpty(),
            schemaVersion = objectValue.int("schemaVersion") ?: 0,
            documentCount = objectValue.int("documentCount") ?: 0,
            corrupt = objectValue.bool("corrupt") ?: false,
            writable = objectValue.bool("writable") ?: false,
        )
    }

    fun decodeCanvasEnvelope(value: JsonElement): CanvasProjectEnvelope {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasEnvelope")
        return CanvasProjectEnvelope(
            project = decodeCanvasProject(
                objectValue.objectValue("project")
                    ?: throw CreativeException("invalidResponse", "missingCanvasProject")),
            assetsBasePath = objectValue.string("assetsBasePath").orEmpty(),
            writable = objectValue.bool("writable") ?: false,
            recoveryWarnings = objectValue.strings("recoveryWarnings"),
        )
    }

    fun decodeCanvasProject(value: JsonObject): CanvasProject = CanvasProject(
        id = value.string("id") ?: throw CreativeException("invalidResponse", "missingCanvasID"),
        schemaVersion = value.int("schemaVersion") ?: 7,
        workspaceID = value.string("workspaceID"),
        name = value.string("name").orEmpty(),
        documents = value.array("documents")?.map(::decodeCanvasDocument).orEmpty(),
        selectedDocumentID = value.string("selectedDocumentID").orEmpty(),
        agentConversationID = value.string("agentConversationID"),
        assistantSessions = value.array("assistantSessions")?.map(::decodeCanvasAssistant).orEmpty(),
        selectedAssistantSessionID = value.string("selectedAssistantSessionID"),
        agentConversationIDsByDocument = decodeConversationBindings(
            value["agentConversationIDsByDocument"]),
        viewports = decodeViewports(value["viewports"]),
        revision = value.long("revision") ?: 0,
        sync = (value.objectValue("sync")?.let(::decodeCanvasSync)) ?: CanvasSyncSettings(),
        designProjectAuthority = value.objectValue("designProjectAuthority"),
        createdAt = value.string("createdAt").orEmpty(),
        updatedAt = value.string("updatedAt").orEmpty(),
    )

    private fun decodeCanvasDocument(value: JsonElement): CanvasDocument {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasDocument")
        return CanvasDocument(
            id = objectValue.string("id") ?: throw CreativeException("invalidResponse", "missingDocumentID"),
            name = objectValue.string("name").orEmpty(),
            nodes = objectValue.array("nodes")?.map(::decodeCanvasNode).orEmpty(),
            connections = objectValue.array("connections")?.map(::decodeCanvasConnection).orEmpty(),
            strokes = objectValue.array("strokes")?.map(::decodeCanvasStroke).orEmpty(),
            pencilDrawingData = objectValue.string("pencilDrawingData"),
            backgroundStyle = objectValue.string("backgroundStyle"),
            createdAt = objectValue.string("createdAt").orEmpty(),
            updatedAt = objectValue.string("updatedAt").orEmpty(),
        )
    }

    private fun decodeCanvasNode(value: JsonElement): CanvasNode {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasNode")
        return CanvasNode(
            id = objectValue.string("id") ?: throw CreativeException("invalidResponse", "missingNodeID"),
            kind = objectValue.string("kind") ?: "text",
            title = objectValue.string("title"),
            text = objectValue.string("text").orEmpty(),
            position = objectValue.objectValue("position")?.let(::decodePoint) ?: CanvasPoint(0.0, 0.0),
            size = objectValue.objectValue("size")?.let(::decodeSize) ?: CanvasSize(0.0, 0.0),
            rotation = objectValue.double("rotation") ?: 0.0,
            zIndex = objectValue.int("zIndex") ?: 0,
            isLocked = objectValue.bool("isLocked") ?: false,
            groupID = objectValue.string("groupID"),
            shape = objectValue.string("shape"),
            asset = objectValue.objectValue("asset")?.let(::decodeCanvasAsset),
            generationJobID = objectValue.string("generationJobID"),
            scene3D = objectValue.objectValue("scene3D"),
            sourceURLs = objectValue.strings("sourceURLs"),
            createdByRunID = objectValue.string("createdByRunID"),
            metadata = objectValue.objectValue("metadata")?.stringMap().orEmpty(),
        )
    }

    private fun decodeCanvasConnection(value: JsonElement): CanvasConnection {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasConnection")
        return CanvasConnection(
            id = objectValue.string("id") ?: throw CreativeException("invalidResponse", "missingConnectionID"),
            sourceNodeID = objectValue.string("sourceNodeID").orEmpty(),
            destinationNodeID = objectValue.string("destinationNodeID").orEmpty(),
            kind = objectValue.string("kind") ?: "arrow",
            label = objectValue.string("label"),
            sourcePort = objectValue.string("sourcePort"),
            destinationPort = objectValue.string("destinationPort"),
        )
    }

    private fun decodeCanvasStroke(value: JsonElement): CanvasStroke {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasStroke")
        return CanvasStroke(
            id = objectValue.string("id") ?: throw CreativeException("invalidResponse", "missingStrokeID"),
            points = objectValue.array("points")?.map {
                val point = it as? JsonObject ?: return@map CanvasPoint(0.0, 0.0)
                decodePoint(point)
            }.orEmpty(),
            width = objectValue.double("width") ?: 3.0,
            color = objectValue.string("color") ?: "primary",
            isEraser = objectValue.bool("isEraser") ?: false,
        )
    }

    private fun decodeCanvasAssistant(value: JsonElement): com.floe.android.feature.canvas.CanvasAssistantSession {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasAssistant")
        return com.floe.android.feature.canvas.CanvasAssistantSession(
            id = objectValue.string("id").orEmpty(),
            conversationID = objectValue.string("conversationID").orEmpty(),
            title = objectValue.string("title").orEmpty(),
            createdAt = objectValue.string("createdAt").orEmpty(),
            updatedAt = objectValue.string("updatedAt").orEmpty(),
        )
    }

    private fun decodeCanvasSync(value: JsonObject): CanvasSyncSettings = CanvasSyncSettings(
        isEnabled = value.bool("isEnabled") ?: true,
        revision = value.long("revision") ?: 0,
        lastSyncedAt = value.string("lastSyncedAt"),
        pendingReleaseBytes = value.long("pendingReleaseBytes") ?: 0,
    )

    private fun decodeViewports(value: JsonElement?): List<CanvasViewportEntry> = when (value) {
        is JsonArray -> buildList {
            var index = 0
            while (index + 1 < value.size) {
                val key = (value[index] as? JsonPrimitive)?.content ?: break
                val viewport = decodeViewport(value[index + 1])
                add(CanvasViewportEntry(key, viewport))
                index += 2
            }
        }
        // Defensive only: older/host fixtures may use an object. The native
        // encoder always emits the alternating array.
        is JsonObject -> value.mapNotNull { (key, item) ->
            runCatching { CanvasViewportEntry(key, decodeViewport(item)) }.getOrNull()
        }
        else -> emptyList()
    }

    private fun decodeViewport(value: JsonElement): CanvasViewportState {
        val objectValue = value as? JsonObject ?: return CanvasViewportState()
        return CanvasViewportState(
            center = objectValue.objectValue("center")?.let(::decodePoint) ?: CanvasPoint(0.0, 0.0),
            scale = objectValue.double("scale") ?: 1.0,
        )
    }

    private fun decodeConversationBindings(value: JsonElement?): List<CanvasConversationBinding> =
        when (value) {
            is JsonArray -> buildList {
                var index = 0
                while (index + 1 < value.size) {
                    val key = (value[index] as? JsonPrimitive)?.content ?: break
                    val conversation = (value[index + 1] as? JsonPrimitive)?.content ?: break
                    add(CanvasConversationBinding(key, conversation))
                    index += 2
                }
            }
            is JsonObject -> value.mapNotNull { (key, item) ->
                val conversation = (item as? JsonPrimitive)?.content ?: return@mapNotNull null
                CanvasConversationBinding(key, conversation)
            }
            else -> emptyList()
        }

    private fun decodePoint(value: JsonObject): CanvasPoint = CanvasPoint(
        x = value.double("x") ?: 0.0, y = value.double("y") ?: 0.0)

    private fun decodeSize(value: JsonObject): CanvasSize = CanvasSize(
        width = value.double("width") ?: 0.0, height = value.double("height") ?: 0.0)

    private fun decodeCanvasAsset(value: JsonObject): CanvasAssetReference = CanvasAssetReference(
        id = value.string("id") ?: throw CreativeException("invalidResponse", "missingAssetID"),
        contentHash = value.string("contentHash"),
        localRelativePath = value.string("localRelativePath"),
        cloudRecordName = value.string("cloudRecordName"),
        mimeType = value.string("mimeType"),
        byteCount = value.long("byteCount"),
        sourceURL = value.string("sourceURL"),
        license = value.string("license"),
    )

    fun decodeCanvasResult(value: JsonElement): CanvasOperationResult {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasResult")
        return CanvasOperationResult(
            canvasID = objectValue.string("canvasID").orEmpty(),
            documentID = objectValue.string("documentID"),
            previousRevision = objectValue.long("previousRevision") ?: 0,
            revision = objectValue.long("revision") ?: 0,
            changedNodeIDs = objectValue.strings("changedNodeIDs"),
            changedConnectionIDs = objectValue.strings("changedConnectionIDs"),
            undoToken = objectValue.string("undoToken"),
            opID = objectValue.string("opID").orEmpty(),
            idempotent = objectValue.bool("idempotent") ?: false,
        )
    }

    fun decodeCanvasMutation(value: JsonElement): CanvasMutationReceipt {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidCanvasMutation")
        return CanvasMutationReceipt(
            canvasID = objectValue.string("canvasID").orEmpty(),
            name = objectValue.string("name"),
            revision = objectValue.long("revision") ?: 0,
            deleted = objectValue.bool("deleted") ?: false,
            opID = objectValue.string("opID").orEmpty(),
            idempotent = objectValue.bool("idempotent") ?: false,
        )
    }

    fun decodeCanvasAssetReceipt(value: JsonElement): CanvasAssetReceipt {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidAssetReceipt")
        return CanvasAssetReceipt(
            asset = decodeCanvasAsset(
                objectValue.objectValue("asset")
                    ?: throw CreativeException("invalidResponse", "missingAsset")),
            deduplicated = objectValue.bool("deduplicated") ?: false,
            opID = objectValue.string("opID").orEmpty(),
            idempotent = objectValue.bool("idempotent") ?: false,
        )
    }

    fun decodeRecovery(value: JsonElement): CanvasRecoveryState {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidRecoveryState")
        return CanvasRecoveryState(
            canvasID = objectValue.string("canvasID").orEmpty(),
            pendingOperations = objectValue.int("pendingOperations")
                ?: objectValue.int("pending") ?: 0,
            appliedOperations = objectValue.int("appliedOperations")
                ?: objectValue.int("applied") ?: 0,
            warnings = objectValue.strings("warnings"),
        )
    }

    // MARK: - Media encode

    fun encodeMediaCommand(command: MediaEditCommand): JsonObject = when (command) {
        is MediaEditCommand.AddAsset -> buildJsonObject {
            put("type", "addAsset")
            put("asset", encodeMediaAsset(command.asset))
        }
        is MediaEditCommand.RelinkAsset -> buildJsonObject {
            put("type", "relinkAsset")
            put("assetID", command.assetID)
            put("relativePath", command.relativePath)
        }
        is MediaEditCommand.SetCanvas -> buildJsonObject {
            put("type", "setCanvas")
            put("width", command.width)
            put("height", command.height)
            command.frameRate?.let { put("frameRate", it) }
        }
        is MediaEditCommand.AddImageLayer -> buildJsonObject {
            put("type", "addImageLayer")
            put("layer", encodeImageLayer(command.layer))
        }
        is MediaEditCommand.UpdateLayer -> buildJsonObject {
            put("type", "updateLayer")
            put("id", command.id)
            command.transform?.let { put("transform", encodeTransform(it)) }
            command.opacity?.let { put("opacity", it) }
            command.isHidden?.let { put("isHidden", it) }
            command.isLocked?.let { put("isLocked", it) }
            command.adjustment?.let { put("adjustment", encodeAdjustment(it)) }
            command.text?.let { put("text", encodeTextContent(it)) }
            put("crop", encodeOptionalUpdate(command.crop) { encodeRect(it) })
        }
        is MediaEditCommand.ReorderLayers -> buildJsonObject {
            put("type", "reorderLayers")
            putJsonArray("orderedIDs") {
                command.orderedIDs.forEach { add(JsonPrimitive(it)) }
            }
        }
        is MediaEditCommand.MoveLayer -> buildJsonObject {
            put("type", "moveLayer"); put("id", command.id); put("toIndex", command.toIndex)
        }
        is MediaEditCommand.RemoveLayer -> buildJsonObject {
            put("type", "removeLayer"); put("id", command.id)
        }
        is MediaEditCommand.DuplicateLayer -> buildJsonObject {
            put("type", "duplicateLayer"); put("id", command.id)
            command.name?.let { put("name", it) }
        }
        is MediaEditCommand.AddFreehandStroke -> buildJsonObject {
            put("type", "addFreehandStroke"); put("id", command.id)
            put("stroke", encodeFreehandStroke(command.stroke))
        }
        is MediaEditCommand.SetCanvasAdjustment -> buildJsonObject {
            put("type", "setCanvasAdjustment")
            put("adjustment", encodeAdjustment(command.adjustment))
        }
        is MediaEditCommand.SetImageSelection -> buildJsonObject {
            put("type", "setImageSelection")
            put("selection", command.selection ?: JsonNull)
        }
        is MediaEditCommand.FlipLayer -> buildJsonObject {
            put("type", "flipLayer"); put("id", command.id)
            put("horizontal", command.horizontal)
        }
        is MediaEditCommand.ClearLayerMask -> buildJsonObject {
            put("type", "clearLayerMask"); put("id", command.id)
        }
        is MediaEditCommand.SetLayerSelectionMask -> buildJsonObject {
            put("type", "setLayerSelectionMask"); put("id", command.id)
            put("selection", encodeOptionalUpdate(command.selection) { it })
        }
    }

    private fun encodeMediaAsset(value: MediaAssetReference): JsonObject = buildJsonObject {
        put("id", value.id)
        put("kind", value.kind)
        put("relativePath", value.relativePath)
        put("originalName", value.originalName)
        value.byteCount?.let { put("byteCount", it) }
        nullable("contentHash", value.contentHash)
        value.metadata?.let { put("metadata", encodeAssetMetadata(it)) }
    }

    private fun encodeAssetMetadata(value: MediaAssetMetadata): JsonObject = buildJsonObject {
        value.width?.let { put("width", it) }
        value.height?.let { put("height", it) }
        value.durationSeconds?.let { put("durationSeconds", it) }
        value.frameRate?.let { put("frameRate", it) }
        value.audioTracks?.let { put("audioTracks", it) }
        value.rotationDegrees?.let { put("rotationDegrees", it) }
        value.hasAlpha?.let { put("hasAlpha", it) }
    }

    private fun encodeImageLayer(value: ImageLayer): JsonObject = buildJsonObject {
        put("id", value.id)
        put("kind", value.kind)
        put("name", value.name)
        nullable("assetID", value.assetID)
        put("transform", encodeTransform(value.transform))
        put("opacity", value.opacity)
        put("isHidden", value.isHidden)
        put("isLocked", value.isLocked)
        value.text?.let { put("text", encodeTextContent(it)) }
        value.freehand?.let { put("freehand", encodeFreehandContent(it)) }
        value.crop?.let { put("crop", encodeRect(it)) }
        value.mask?.let { put("mask", it) }
        value.selectionMask?.let { put("selectionMask", it) }
        nullable("fillColorHex", value.fillColorHex)
        put("adjustment", encodeAdjustment(value.adjustment))
    }

    private fun encodeTransform(value: ImageLayerTransform): JsonObject = buildJsonObject {
        put("centerX", value.centerX)
        put("centerY", value.centerY)
        put("scale", value.scale)
        put("rotationDegrees", value.rotationDegrees)
        value.flipX?.let { put("flipX", it) }
        value.flipY?.let { put("flipY", it) }
    }

    private fun encodeAdjustment(value: ImageLayerAdjustment): JsonObject = buildJsonObject {
        value.saturation?.let { put("saturation", it) }
        value.contrast?.let { put("contrast", it) }
        value.brightness?.let { put("brightness", it) }
        value.exposureEV?.let { put("exposureEV", it) }
        value.blurRadius?.let { put("blurRadius", it) }
        value.sharpenRadius?.let { put("sharpenRadius", it) }
        value.temperature?.let { put("temperature", it) }
        value.hueDegrees?.let { put("hueDegrees", it) }
        value.levels?.let { put("levels", it) }
        value.mosaicBlockSize?.let { put("mosaicBlockSize", it) }
        value.filterID?.let { put("filterID", it) }
    }

    private fun encodeTextContent(value: ImageTextContent): JsonObject = buildJsonObject {
        put("text", value.text)
        put("fontSize", value.fontSize)
        put("colorHex", value.colorHex)
        value.fontName?.let { put("fontName", it) }
        value.tracking?.let { put("tracking", it) }
        value.leading?.let { put("leading", it) }
        value.alignment?.let { put("alignment", it) }
        value.strokeColorHex?.let { put("strokeColorHex", it) }
        value.strokeWidth?.let { put("strokeWidth", it) }
        value.shadow?.let {
            put("shadow", buildJsonObject {
                put("colorHex", it.colorHex); put("blur", it.blur)
                put("offsetX", it.offsetX); put("offsetY", it.offsetY)
            })
        }
    }

    private fun encodeFreehandContent(value: ImageFreehandContent): JsonObject = buildJsonObject {
        putJsonArray("strokes") { value.strokes.forEach { add(encodeFreehandStroke(it)) } }
    }

    private fun encodeFreehandStroke(value: ImageFreehandStroke): JsonObject = buildJsonObject {
        putJsonArray("points") {
            value.points.forEach { point ->
                add(buildJsonObject {
                    put("x", point.x); put("y", point.y)
                    point.pressure?.let { put("pressure", it) }
                })
            }
        }
        put("width", value.width)
        put("colorHex", value.colorHex)
        value.hardness?.let { put("hardness", it) }
        value.opacity?.let { put("opacity", it) }
    }

    private fun encodeRect(value: NormalizedRect): JsonObject = buildJsonObject {
        put("x", value.x); put("y", value.y)
        put("width", value.width); put("height", value.height)
    }

    private fun <T> encodeOptionalUpdate(
        update: OptionalUpdate<T>,
        encode: (T) -> JsonObject,
    ): JsonObject = when (update) {
        OptionalUpdate.Unchanged -> buildJsonObject { put("state", "unchanged") }
        OptionalUpdate.Clear -> buildJsonObject { put("state", "clear") }
        is OptionalUpdate.Set -> buildJsonObject {
            put("state", "set")
            put("value", encode(update.value))
        }
    }

    // MARK: - Media decode

    fun decodeMediaSummary(value: JsonElement): MediaProjectSummary {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidMediaSummary")
        return MediaProjectSummary(
            id = objectValue.string("id") ?: throw CreativeException("invalidResponse", "missingProjectID"),
            name = objectValue.string("name").orEmpty(),
            kind = objectValue.string("kind") ?: "image",
            revision = objectValue.long("revision") ?: 0,
            updatedAt = objectValue.string("updatedAt").orEmpty(),
            ownerKind = objectValue.string("ownerKind").orEmpty(),
            ownerID = objectValue.string("ownerID"),
            environmentID = objectValue.string("environmentID"),
            assetCount = objectValue.int("assetCount") ?: 0,
            layerCount = objectValue.int("layerCount") ?: 0,
            corrupt = objectValue.bool("corrupt") ?: false,
            writable = objectValue.bool("writable") ?: false,
            provenanceWarning = objectValue.bool("provenanceWarning") ?: false,
        )
    }

    fun decodeMediaEnvelope(value: JsonElement): MediaProjectEnvelope {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidMediaEnvelope")
        return MediaProjectEnvelope(
            project = decodeMediaProject(
                objectValue.objectValue("project")
                    ?: throw CreativeException("invalidResponse", "missingMediaProject")),
            mediaRootPath = objectValue.string("mediaRootPath").orEmpty(),
            storage = decodeStorage(objectValue["storage"]),
            writable = objectValue.bool("writable") ?: false,
            warnings = objectValue.strings("warnings"),
        )
    }

    fun decodeMediaProject(value: JsonObject): MediaProject = MediaProject(
        id = value.string("id") ?: throw CreativeException("invalidResponse", "missingProjectID"),
        schemaVersion = value.int("schemaVersion") ?: 1,
        kind = value.string("kind") ?: "image",
        name = value.string("name").orEmpty(),
        createdAt = value.string("createdAt").orEmpty(),
        updatedAt = value.string("updatedAt").orEmpty(),
        revision = value.long("revision") ?: 0,
        canvas = value.objectValue("canvas")?.let {
            MediaCanvas(
                width = it.int("width") ?: 0,
                height = it.int("height") ?: 0,
                frameRate = it.double("frameRate"))
        },
        assets = value.array("assets")?.map(::decodeMediaAsset).orEmpty(),
        sourceAssetID = value.string("sourceAssetID"),
        imageLayers = value.array("imageLayers")?.map(::decodeImageLayer).orEmpty(),
        canvasAdjustment = value.objectValue("canvasAdjustment")
            ?.let(::decodeAdjustment) ?: ImageLayerAdjustment(),
        videoTimeline = value.objectValue("videoTimeline"),
        lastImageExport = value.objectValue("lastImageExport"),
        lastVideoExport = value.objectValue("lastVideoExport"),
        ownerKind = value.string("ownerKind") ?: "standalone",
        ownerID = value.string("ownerID"),
        environmentID = value.string("environmentID"),
        taskWorkspacePath = value.string("taskWorkspacePath"),
        unknownOperations = value.array("unknownOperations")
            ?.mapNotNull { it as? JsonObject }.orEmpty(),
        recoveryWarnings = value.strings("recoveryWarnings"),
        canUndo = value.array("undoHistory")?.isNotEmpty() == true,
        canRedo = value.array("redoHistory")?.isNotEmpty() == true,
        parentProjectID = value.string("parentProjectID"),
        imageSelection = value.objectValue("imageSelection"),
    )

    private fun decodeMediaAsset(value: JsonElement): MediaAssetReference {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidMediaAsset")
        return MediaAssetReference(
            id = objectValue.string("id") ?: throw CreativeException("invalidResponse", "missingAssetID"),
            kind = objectValue.string("kind") ?: "image",
            relativePath = objectValue.string("relativePath").orEmpty(),
            originalName = objectValue.string("originalName").orEmpty(),
            byteCount = objectValue.long("byteCount"),
            contentHash = objectValue.string("contentHash"),
            metadata = objectValue.objectValue("metadata")?.let(::decodeAssetMetadata),
        )
    }

    private fun decodeAssetMetadata(value: JsonObject): MediaAssetMetadata = MediaAssetMetadata(
        width = value.int("width"),
        height = value.int("height"),
        durationSeconds = value.double("durationSeconds"),
        frameRate = value.double("frameRate"),
        audioTracks = value.int("audioTracks"),
        rotationDegrees = value.double("rotationDegrees"),
        hasAlpha = value.bool("hasAlpha"),
    )

    private fun decodeImageLayer(value: JsonElement): ImageLayer {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidImageLayer")
        return ImageLayer(
            id = objectValue.string("id") ?: throw CreativeException("invalidResponse", "missingLayerID"),
            kind = objectValue.string("kind") ?: "image",
            name = objectValue.string("name").orEmpty(),
            assetID = objectValue.string("assetID"),
            transform = objectValue.objectValue("transform")?.let(::decodeTransform)
                ?: ImageLayerTransform(),
            opacity = objectValue.double("opacity") ?: 1.0,
            isHidden = objectValue.bool("isHidden") ?: false,
            isLocked = objectValue.bool("isLocked") ?: false,
            text = objectValue.objectValue("text")?.let(::decodeTextContent),
            freehand = objectValue.objectValue("freehand")?.let(::decodeFreehandContent),
            crop = objectValue.objectValue("crop")?.let(::decodeRect),
            mask = objectValue.objectValue("mask"),
            selectionMask = objectValue.objectValue("selectionMask"),
            fillColorHex = objectValue.string("fillColorHex"),
            adjustment = objectValue.objectValue("adjustment")?.let(::decodeAdjustment)
                ?: ImageLayerAdjustment(),
        )
    }

    private fun decodeTransform(value: JsonObject): ImageLayerTransform = ImageLayerTransform(
        centerX = value.double("centerX") ?: 0.5,
        centerY = value.double("centerY") ?: 0.5,
        scale = value.double("scale") ?: 1.0,
        rotationDegrees = value.double("rotationDegrees") ?: 0.0,
        flipX = value.bool("flipX"),
        flipY = value.bool("flipY"),
    )

    private fun decodeAdjustment(value: JsonObject): ImageLayerAdjustment = ImageLayerAdjustment(
        saturation = value.double("saturation"),
        contrast = value.double("contrast"),
        brightness = value.double("brightness"),
        exposureEV = value.double("exposureEV"),
        blurRadius = value.double("blurRadius"),
        sharpenRadius = value.double("sharpenRadius"),
        temperature = value.double("temperature"),
        hueDegrees = value.double("hueDegrees"),
        levels = value.objectValue("levels"),
        mosaicBlockSize = value.int("mosaicBlockSize"),
        filterID = value.string("filterID"),
    )

    private fun decodeTextContent(value: JsonObject): ImageTextContent = ImageTextContent(
        text = value.string("text").orEmpty(),
        fontSize = value.double("fontSize") ?: 48.0,
        colorHex = value.string("colorHex") ?: "#000000",
        fontName = value.string("fontName"),
        tracking = value.double("tracking"),
        leading = value.double("leading"),
        alignment = value.string("alignment"),
        strokeColorHex = value.string("strokeColorHex"),
        strokeWidth = value.double("strokeWidth"),
        shadow = value.objectValue("shadow")?.let {
            ImageTextShadow(
                colorHex = it.string("colorHex") ?: "#00000080",
                blur = it.double("blur") ?: 4.0,
                offsetX = it.double("offsetX") ?: 2.0,
                offsetY = it.double("offsetY") ?: 2.0)
        },
    )

    private fun decodeFreehandContent(value: JsonObject): ImageFreehandContent =
        ImageFreehandContent(
            strokes = value.array("strokes")?.map { item ->
                val stroke = item as? JsonObject ?: return@map ImageFreehandStroke(emptyList())
                ImageFreehandStroke(
                    points = stroke.array("points")?.map { point ->
                        val p = point as? JsonObject ?: return@map ImageFreehandPoint(0.0, 0.0)
                        ImageFreehandPoint(
                            x = p.double("x") ?: 0.0, y = p.double("y") ?: 0.0,
                            pressure = p.double("pressure"))
                    }.orEmpty(),
                    width = stroke.double("width") ?: 4.0,
                    colorHex = stroke.string("colorHex") ?: "#000000",
                    hardness = stroke.double("hardness"),
                    opacity = stroke.double("opacity"),
                )
            }.orEmpty())

    private fun decodeRect(value: JsonObject): NormalizedRect = NormalizedRect(
        x = value.double("x") ?: 0.0, y = value.double("y") ?: 0.0,
        width = value.double("width") ?: 1.0, height = value.double("height") ?: 1.0)

    fun decodeMediaReceipt(value: JsonElement): MediaProjectReceipt {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidMediaReceipt")
        return MediaProjectReceipt(
            projectID = objectValue.string("projectID").orEmpty(),
            revision = objectValue.long("revision") ?: 0,
            canUndo = objectValue.bool("canUndo") ?: false,
            canRedo = objectValue.bool("canRedo") ?: false,
            opID = objectValue.string("opID").orEmpty(),
            idempotent = objectValue.bool("idempotent") ?: false,
        )
    }

    fun decodeMediaMutation(value: JsonElement): MediaMutationReceipt {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidMediaMutation")
        return MediaMutationReceipt(
            projectID = objectValue.string("projectID").orEmpty(),
            name = objectValue.string("name"),
            revision = objectValue.long("revision") ?: 0,
            deleted = objectValue.bool("deleted") ?: false,
            canUndo = objectValue.bool("canUndo") ?: false,
            canRedo = objectValue.bool("canRedo") ?: false,
            opID = objectValue.string("opID").orEmpty(),
            idempotent = objectValue.bool("idempotent") ?: false,
        )
    }

    fun decodeMediaAssetReceipt(value: JsonElement): MediaAssetReceipt {
        val objectValue = value as? JsonObject
            ?: throw CreativeException("invalidResponse", "invalidMediaAssetReceipt")
        return MediaAssetReceipt(
            projectID = objectValue.string("projectID").orEmpty(),
            asset = decodeMediaAsset(
                objectValue.objectValue("asset")
                    ?: throw CreativeException("invalidResponse", "missingMediaAsset")),
            revision = objectValue.long("revision") ?: 0,
            canUndo = objectValue.bool("canUndo") ?: false,
            canRedo = objectValue.bool("canRedo") ?: false,
            opID = objectValue.string("opID").orEmpty(),
            idempotent = objectValue.bool("idempotent") ?: false,
        )
    }

    // MARK: - Helpers

    fun newRequestID(): String = UUID.randomUUID().toString()

    private fun kotlinx.serialization.json.JsonObjectBuilder.nullable(
        key: String,
        value: String?,
    ) {
        if (value != null) put(key, value) else put(key, JsonNull)
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.doubleOrNull

    private fun JsonObject.objectValue(key: String): JsonObject? = this[key] as? JsonObject

    private fun JsonObject.array(key: String): JsonArray? = this[key] as? JsonArray

    private fun JsonObject.strings(key: String): List<String> =
        array(key)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()

    private fun JsonObject.stringMap(): Map<String, String> = entries.mapNotNull { (key, value) ->
        val string = (value as? JsonPrimitive)?.content ?: return@mapNotNull null
        key to string
    }.toMap()
}
