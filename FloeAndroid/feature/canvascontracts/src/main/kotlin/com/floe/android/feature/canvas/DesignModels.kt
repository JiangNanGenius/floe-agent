// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas

import kotlinx.serialization.json.JsonObject

/**
 * G09-R2 design DTOs.
 *
 * The shared Swift `DesignOwnerWorkflow`/`DesignCanvasService`/`DesignProject`
 * remains the ONE design authority. These are read projections plus request /
 * receipt DTOs; [DesignProjectProjection.rawProject] keeps the exact shared
 * project JSON (including unknown fields) so Kotlin never duplicates or
 * rewrites the canonical design store.
 *
 * A design target is an explicit identity. Storage, owner and source origin
 * are all explicit; an arbitrary absolute path is never a target, and the
 * canonical `Application Support` convenience roots are never used.
 */
enum class DesignContentType(val wire: String) {
    WEBPAGE("webpage"),
    PROTOTYPE("prototype"),
    PRESENTATION("presentation"),
    IMAGE("image"),
    VIDEO("video"),
    OFFICE_DOCUMENT("officeDocument"),
    NOTES("notes"),
    PDF("pdf"),
    CAD("cad"),
    COMPOSITION("composition"),
}

enum class DesignTargetKind(val wire: String) {
    CANVAS_NODE("canvasNode"),
    FILE_DOCUMENT("fileDocument"),
    CHAT_ATTACHMENT("chatAttachment"),
    CREATIVE_DOCUMENT("creativeDocument"),
}

enum class DesignWorkMode(val wire: String) {
    CREATE("create"),
    MODIFY("modify"),
    RESTRUCTURE("restructure"),
}

enum class DesignAdoptMode(val wire: String) {
    UPDATE_ORIGINAL("updateOriginal"),
    VARIANT("variant"),
}

/** Stable typed identity mirrored from the shared Swift `DesignTarget`. */
data class DesignTargetIdentity(
    val kind: DesignTargetKind,
    val ownerID: String,
    val documentID: String = "",
    val sourceID: String,
    val environmentID: String? = null,
    /** Frozen base-revision token; compared on every later mutation. */
    val revision: String? = null,
    /** Originating task, when the target came from chat. */
    val originConversationID: String? = null,
    /** Requested output kind for a not-yet-materialized creative target. */
    val requestedOutputKind: DesignContentType? = null,
)

/**
 * Explicit design binding. [storage] is a real storage layer; [origin] is the
 * real owner/source route when one exists and is provenance only. The bound
 * host supplies the accepted epoch separately. `sessionToken` is the exact
 * editor/session token, not a task or provider credential.
 */
data class DesignTargetBinding(
    val target: DesignTargetIdentity,
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext? = null,
    val sessionToken: String,
)

data class DesignBriefModel(
    val goal: String,
    val audience: String? = null,
    val constraints: List<String> = emptyList(),
    val createdAt: String,
)

/** Only explicitly set spec values; unknown DESIGN.md sections stay in rawProject. */
data class DesignSpecModel(
    val palette: List<String>? = null,
    val typography: String? = null,
    val layout: String? = null,
    val spacing: String? = null,
    val brandAssetRefs: List<String>? = null,
    val voice: String? = null,
    val prohibitions: List<String>? = null,
    val rawMarkdown: String? = null,
)

data class DesignFrozenRunModel(
    val operationID: String,
    val inputRevisionID: String? = null,
    val specSHA256: String? = null,
    val targetRevisionID: String? = null,
    val desiredFormat: String? = null,
    val workMode: DesignWorkMode? = null,
    val preservationDigest: String? = null,
    val frozenAt: String,
)

enum class DesignCandidateStatus(val wire: String) {
    PENDING("pending"),
    ADOPTED("adopted"),
    REJECTED("rejected"),
    SUPERSEDED("superseded"),
}

/** Mirrors the shared `DesignCandidate`; ids and timestamps stay wire strings. */
data class DesignCandidateModel(
    val id: String,
    val artifactID: String,
    val baseRevisionID: String,
    val proposedRevisionID: String,
    val feedbackIDs: List<String> = emptyList(),
    val summary: String,
    val diff: List<String> = emptyList(),
    val status: DesignCandidateStatus = DesignCandidateStatus.PENDING,
    val createdAt: String,
    val resolvedAt: String? = null,
    val variantArtifactID: String? = null,
    val originConversationID: String? = null,
    val originEnvironmentID: String? = null,
    val proposalOperationID: String? = null,
    val proposalFingerprint: String? = null,
    val workMode: DesignWorkMode? = null,
    val preservationDigest: String? = null,
)

/**
 * Read projection of one shared `DesignOwnerEnvelope`/`DesignProject`.
 * `rawProject` is the exact shared-project JSON and is never re-encoded from
 * these typed fields; unknown parts survive round-trip.
 */
data class DesignProjectProjection(
    val contentType: DesignContentType,
    val brief: DesignBriefModel? = null,
    val spec: DesignSpecModel? = null,
    val candidates: List<DesignCandidateModel> = emptyList(),
    val frozenRun: DesignFrozenRunModel? = null,
    /** Opaque creative-start metadata; preserved, not re-modeled here. */
    val creativeRequest: JsonObject? = null,
    val appliedOperationIDs: List<String> = emptyList(),
    val createdAt: String,
    val updatedAt: String,
    val rawProject: JsonObject,
)

data class DesignStateProjection(
    val target: DesignTargetIdentity,
    val ownerRevision: Long,
    val schemaVersion: Int,
    val project: DesignProjectProjection,
    /** Opaque verified first-result provenance, when present. */
    val creativeFirstResultProvenance: JsonObject? = null,
    val writable: Boolean,
    val warnings: List<String> = emptyList(),
    val availableActions: List<String> = emptyList(),
)

data class DesignBindRequest(
    val binding: DesignTargetBinding,
    /** nil = create the owner envelope only when absent. */
    val expectedRevision: Long? = null,
    val opID: String,
)

data class DesignBriefRequest(
    val binding: DesignTargetBinding,
    val expectedRevision: Long,
    val opID: String,
    val brief: DesignBriefModel,
)

data class DesignSpecRequest(
    val binding: DesignTargetBinding,
    val expectedRevision: Long,
    val opID: String,
    val spec: DesignSpecModel,
)

data class DesignFreezeRequest(
    val binding: DesignTargetBinding,
    val expectedRevision: Long,
    val opID: String,
    val inputRevisionID: String? = null,
    val specSHA256: String? = null,
    val targetRevisionID: String? = null,
    val desiredFormat: String? = null,
    val workMode: DesignWorkMode? = null,
    val preservationDigest: String? = null,
)

data class DesignFreezeReceipt(
    val target: DesignTargetIdentity,
    val ownerRevision: Long,
    val operationID: String,
    val frozenRun: DesignFrozenRunModel,
    val idempotent: Boolean,
)

/** Staged immutable payload; bytes never travel in the bridge JSON. */
data class StagedDesignPayload(
    val token: String,
    val format: String,
    val byteCount: Long,
    val sha256: String,
)

data class DesignProposalRequest(
    val binding: DesignTargetBinding,
    val expectedRevision: Long,
    val opID: String,
    val artifactID: String,
    val baseRevisionID: String? = null,
    val payload: StagedDesignPayload,
    val summary: String,
    val diff: List<String> = emptyList(),
    val feedbackIDs: List<String> = emptyList(),
    /** Frozen run context; a restructure still needs trusted confirmation. */
    val workMode: DesignWorkMode? = null,
    val desiredFormat: String? = null,
    val preservationDigest: String? = null,
)

data class DesignProposalResult(
    val state: DesignStateProjection,
    val candidate: DesignCandidateModel,
    /** Relative token under the owner payload store. */
    val payloadRelativePath: String,
    val replayed: Boolean,
)

data class DesignAdoptRequest(
    val binding: DesignTargetBinding,
    val expectedRevision: Long,
    val opID: String,
    val candidateID: String,
    val mode: DesignAdoptMode,
)

data class DesignRejectRequest(
    val binding: DesignTargetBinding,
    val expectedRevision: Long,
    val opID: String,
    val candidateID: String,
    val reason: String? = null,
)

data class DesignCompareRequest(
    val binding: DesignTargetBinding,
    val candidateID: String,
)

data class DesignComparison(
    val candidateID: String,
    val baseSHA256: String,
    val proposedSHA256: String,
    val changed: Boolean,
    val diff: List<String> = emptyList(),
    /** True when the diff is bounded/incomplete; never present it as complete. */
    val diffTruncated: Boolean = false,
    val diffNote: String? = null,
    val status: DesignCandidateStatus,
)

data class DesignRestoreRequest(
    val binding: DesignTargetBinding,
    val expectedRevision: Long,
    val opID: String,
    val revisionID: String,
)

enum class DesignDeliveryState(val wire: String) {
    NOT_REQUIRED("notRequired"),
    DELIVERED("delivered"),
    PENDING("pending"),
}

data class DesignDelivery(
    val state: DesignDeliveryState,
    val reason: String? = null,
)

enum class DesignPublicationState(val wire: String) {
    NOT_REQUIRED("notRequired"),
    PUBLISHED("published"),
    PENDING("pending"),
}

/** True destination receipt for an immutable owner; pending is never success. */
data class DesignPublication(
    val state: DesignPublicationState,
    val identifier: String? = null,
    val destination: String? = null,
    val contentSHA256: String? = null,
    val reason: String? = null,
)

data class DesignDecisionResult(
    val state: DesignStateProjection,
    val candidateID: String,
    val operationID: String,
    val idempotent: Boolean,
    val committedRevisionToken: String? = null,
    val delivery: DesignDelivery,
    val publication: DesignPublication,
)

data class DesignDecisionReceipt(
    val state: DesignStateProjection,
    val candidateID: String,
    val operationID: String,
    val idempotent: Boolean,
)

data class DesignPreviewRequest(
    val binding: DesignTargetBinding,
    val candidateID: String? = null,
    val revisionID: String? = null,
    val maxBytes: Int = DesignWireLimits.MAX_PREVIEW_BYTES,
)

data class DesignPreviewReceipt(
    val target: DesignTargetIdentity,
    val ownerRevision: Long,
    val candidateID: String? = null,
    val revisionID: String? = null,
    val format: String,
    /** Native-issued trusted root; never a recorded design/project path. */
    val rootPath: String,
    /** Trusted relative path; never inline bytes and never a success string. */
    val relativePath: String,
    val byteCount: Long,
    val sha256: String,
    val width: Int? = null,
    val height: Int? = null,
    val createdAt: String,
)

data class DesignExportRequest(
    val binding: DesignTargetBinding,
    val candidateID: String? = null,
    val revisionID: String? = null,
    val format: String,
    val suggestedFileName: String? = null,
)

data class DesignExportReceipt(
    val target: DesignTargetIdentity,
    val ownerRevision: Long,
    val candidateID: String? = null,
    val revisionID: String? = null,
    val format: String,
    /** Native-issued trusted root; never a recorded design/project path. */
    val rootPath: String,
    /** Trusted relative path under the explicit owner/export root. */
    val relativePath: String,
    val byteCount: Long,
    val sha256: String,
    val createdAt: String,
)

data class DesignHostStatus(
    val bound: Boolean,
    val epoch: Long? = null,
    val rootFingerprint: String? = null,
    val availableTargetKinds: List<String> = emptyList(),
    val targetKindReasons: Map<String, String> = emptyMap(),
    val availableActions: List<String> = emptyList(),
    val maxProposalBytes: Long = DesignWireLimits.MAX_DESIGN_SOURCE_BYTES,
    val maxPreviewBytes: Int = DesignWireLimits.MAX_PREVIEW_BYTES,
)

/** Closed action vocabulary; [mutation] marks owner-revision-mutating calls. */
enum class DesignActionKind(
    val wire: String,
    val mutation: Boolean,
) {
    CANVAS_SNAPSHOT("design.canvas.snapshot", false),
    CANVAS_MUTATE("design.canvas.mutate", true),
    CANVAS_ADOPT("design.canvas.adopt", true),
    CANVAS_COMPARE("design.canvas.compare", false),
    CANVAS_RESTORE("design.canvas.restore", true),
    CANVAS_EXPORT("design.canvas.export", false),
    CANVAS_PREVIEW("design.canvas.preview", false),

    OWNER_STATE("design.owner.state", false),
    OWNER_BRIEF("design.owner.brief", true),
    OWNER_SPEC("design.owner.spec", true),
    OWNER_FREEZE("design.owner.freeze", true),
    OWNER_PROPOSE("design.owner.propose", true),
    OWNER_ADOPT("design.owner.adopt", true),
    OWNER_REJECT("design.owner.reject", true),
    OWNER_COMPARE("design.owner.compare", false),
    OWNER_RESTORE("design.owner.restore", true),
    OWNER_EXPORT("design.owner.export", false),
    OWNER_PREVIEW("design.owner.preview", false),
}

/**
 * Closed `floe.creative/6` design actions. `design.canvas.*` goes through the
 * existing Canvas repository CAS; `design.owner.*` uses the shared owner
 * workflow for file/chat/creative targets. No second design store.
 */
object DesignWireActions {
    val CANVAS: List<String> = DesignActionKind.entries
        .filter { it.name.startsWith("CANVAS_") }
        .map { it.wire }

    val OWNER: List<String> = DesignActionKind.entries
        .filter { it.name.startsWith("OWNER_") }
        .map { it.wire }

    val ALL: List<String> = CANVAS + OWNER
}

/**
 * Typed design failure codes surfaced through `CreativeException.code`.
 * `designPayloadTooLarge` and `designPreviewTooLarge` are explicit size
 * refusals; `designPublicationPending` is never success.
 */
object DesignWireErrors {
    const val DESIGN_TARGET_UNAVAILABLE = "designTargetUnavailable"
    const val DESIGN_CONFLICT = "designConflict"
    const val DESIGN_PUBLICATION_PENDING = "designPublicationPending"
    const val DESIGN_PREVIEW_TOO_LARGE = "designPreviewTooLarge"
    const val DESIGN_PAYLOAD_TOO_LARGE = "designPayloadTooLarge"
    const val DESIGN_CANDIDATE_NOT_FOUND = "candidateNotFound"
    const val DESIGN_PAYLOAD_MISSING = "designPayloadMissing"
    const val DESIGN_PUBLICATION_UNAVAILABLE = "designPublicationUnavailable"

    val ALL: Set<String> = setOf(
        DESIGN_TARGET_UNAVAILABLE, DESIGN_CONFLICT, DESIGN_PUBLICATION_PENDING,
        DESIGN_PREVIEW_TOO_LARGE, DESIGN_PAYLOAD_TOO_LARGE,
        DESIGN_CANDIDATE_NOT_FOUND, DESIGN_PAYLOAD_MISSING,
        DESIGN_PUBLICATION_UNAVAILABLE,
    )
}

object DesignWireLimits {
    const val REQUEST_BYTES = 65_536
    const val RESPONSE_BYTES = 16 * 1024 * 1024
    const val CANVAS_JSON_BYTES = 15 * 1024 * 1024
    const val MAX_PREVIEW_BYTES = 8 * 1024 * 1024
    const val MAX_DESIGN_SOURCE_BYTES = 64L * 1024 * 1024
}
