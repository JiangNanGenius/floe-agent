// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.DesignTargetIdentity
import com.floe.android.feature.canvas.DesignTargetKind
import java.util.UUID

/**
 * Real target identity resolution for the App design entries.
 *
 * Every binding is built from an ACTUAL user selection already owned by the
 * App (Canvas editor session, workspace document request, or a retained
 * creative asset). Nothing here invents a project, a task, an environment,
 * a root path or a permission; [DesignTargetIdentity.sourceID] is an identity,
 * never an authority.
 */
internal object DesignTargetResolver {

    fun canvasBinding(
        canvasID: String,
        documentID: String,
        nodeID: String,
        sessionToken: String,
    ): DesignTargetBinding {
        requireUuid(canvasID, "canvasID")
        requireUuid(documentID, "documentID")
        requireUuid(nodeID, "nodeID")
        requireSessionToken(sessionToken)
        return DesignTargetBinding(
            target = DesignTargetIdentity(
                kind = DesignTargetKind.CANVAS_NODE,
                ownerID = canvasID,
                documentID = documentID,
                sourceID = nodeID,
            ),
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext(
                kind = CreativeOriginContext.CANVAS,
                ownerID = canvasID,
            ),
            sessionToken = sessionToken,
        )
    }

    fun chatAttachmentBinding(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        sessionToken: String,
    ): DesignTargetBinding {
        requireUuid(conversationID, "conversationID")
        requireUuid(messageID, "messageID")
        requireUuid(attachmentID, "attachmentID")
        requireSessionToken(sessionToken)
        return DesignTargetBinding(
            target = DesignTargetIdentity(
                kind = DesignTargetKind.CHAT_ATTACHMENT,
                ownerID = conversationID,
                documentID = messageID,
                sourceID = attachmentID,
                originConversationID = conversationID,
            ),
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext(
                kind = CreativeOriginContext.CHAT,
                ownerID = conversationID,
            ),
            sessionToken = sessionToken,
        )
    }

    fun workspaceFileBinding(
        workspaceID: String,
        relativePath: String,
        sessionToken: String,
    ): DesignTargetBinding {
        requireUuid(workspaceID, "workspaceID")
        requireRelativePath(relativePath)
        requireSessionToken(sessionToken)
        return DesignTargetBinding(
            target = DesignTargetIdentity(
                kind = DesignTargetKind.FILE_DOCUMENT,
                ownerID = workspaceID,
                documentID = "",
                sourceID = relativePath,
            ),
            storage = CreativeStorageLayer.Workspace(workspaceID),
            origin = CreativeOriginContext(
                kind = CreativeOriginContext.WORKSPACE,
                ownerID = workspaceID,
            ),
            sessionToken = sessionToken,
        )
    }

    /**
     * Creative target for a REAL retained asset and an explicit user-requested
     * output kind. The owner is the stable creative-library surface (the iOS
     * public identity), the source is the retained asset UUID, and the origin
     * conversation is set only when the request belongs to an existing task.
     * No caller may pass a media project ID as a creative-document alias.
     */
    fun creativeBinding(
        ownerID: String = CREATIVE_LIBRARY_OWNER,
        assetID: String,
        requestedOutputKind: DesignContentType,
        originConversationID: String?,
        sessionToken: String,
    ): DesignTargetBinding {
        requireRelativeToken(ownerID, "ownerID")
        requireUuid(assetID, "assetID")
        originConversationID?.let { requireUuid(it, "originConversationID") }
        requireSessionToken(sessionToken)
        return DesignTargetBinding(
            target = DesignTargetIdentity(
                kind = DesignTargetKind.CREATIVE_DOCUMENT,
                ownerID = ownerID,
                documentID = "",
                sourceID = assetID,
                originConversationID = originConversationID,
                requestedOutputKind = requestedOutputKind,
            ),
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext(kind = CreativeOriginContext.STANDALONE),
            sessionToken = sessionToken,
        )
    }

    fun validate(binding: DesignTargetBinding): DesignTargetBinding {
        requireSessionToken(binding.sessionToken)
        val target = binding.target
        when (target.kind) {
            DesignTargetKind.CANVAS_NODE -> {
                requireUuid(target.ownerID, "ownerID")
                requireUuid(target.documentID, "documentID")
                requireUuid(target.sourceID, "sourceID")
                requireTyped(
                    binding.storage == CreativeStorageLayer.AppOwned,
                    "canvasStorageMustBeAppOwned",
                )
            }
            DesignTargetKind.FILE_DOCUMENT -> {
                requireUuid(target.ownerID, "ownerID")
                requireTyped(
                    target.documentID.isEmpty(),
                    "fileDocumentHasNoDocumentLayer",
                )
                requireRelativePath(target.sourceID)
                val storage = binding.storage
                requireTyped(
                    storage is CreativeStorageLayer.Workspace,
                    "fileStorageMustNameItsExactWorkspace",
                )
                requireTyped(
                    storage is CreativeStorageLayer.Workspace &&
                        storage.workspaceID == target.ownerID,
                    "fileStorageWorkspaceMismatch",
                )
            }
            DesignTargetKind.CHAT_ATTACHMENT -> {
                requireUuid(target.ownerID, "ownerID")
                if (target.documentID.isNotEmpty()) {
                    requireUuid(target.documentID, "documentID")
                }
                requireUuid(target.sourceID, "sourceID")
                requireTyped(
                    binding.storage == CreativeStorageLayer.AppOwned,
                    "chatStorageMustBeAppOwned",
                )
            }
            DesignTargetKind.CREATIVE_DOCUMENT -> {
                requireRelativeToken(target.ownerID, "ownerID")
                requireTyped(
                    target.documentID.isEmpty(),
                    "creativeDocumentHasNoDocumentLayer",
                )
                requireUuid(target.sourceID, "sourceID")
                requireTyped(
                    binding.storage == CreativeStorageLayer.AppOwned,
                    "creativeStorageMustBeAppOwned",
                )
            }
        }
        return binding
    }

    private fun requireTyped(condition: Boolean, reason: String) {
        if (!condition) throw CreativeException("invalidRequest", reason)
    }

    /** Bounded, stable key for the App-owned retained-session map. */
    fun targetKey(binding: DesignTargetBinding): String {
        val target = binding.target
        return listOf(
            target.kind.wire,
            target.ownerID,
            target.documentID,
            target.sourceID,
            binding.sessionToken,
        ).joinToString("|")
    }

    /**
     * Deterministic editor token for a document request. It is derived only
     * from the already-owned request identity, so rotation reuses the same
     * token and a different document can never collide.
     */
    fun documentSessionToken(
        taskID: String,
        workspaceID: String,
        relativePath: String,
        requestToken: Long,
    ): String = UUID.nameUUIDFromBytes(
        (
            "floe.design.document|$taskID|$workspaceID|$relativePath|$requestToken"
            ).toByteArray(Charsets.UTF_8),
    ).toString()

    private fun requireUuid(value: String, field: String) {
        try {
            UUID.fromString(value)
        } catch (_: Throwable) {
            throw CreativeException("invalidRequest", "invalid${field.replaceFirstChar { it.uppercase() }}")
        }
    }

    private fun requireSessionToken(token: String) {
        if (!CreativeSessionTokens.isValid(token)) {
            throw CreativeException("invalidSession", "invalidSessionToken")
        }
    }

    private fun requireRelativePath(path: String) {
        val segments = path.split('/')
        if (path.isEmpty() || path.length > 512 || path.startsWith("/") ||
            path.contains('\\') || path.contains('\u0000') ||
            segments.any { it.isEmpty() || it == "." || it == ".." }
        ) {
            throw CreativeException("invalidRequest", "invalidDesignReference")
        }
    }

    private fun requireRelativeToken(value: String, field: String) {
        if (value.isEmpty() || value.length > 128 || value.startsWith(".") ||
            value.contains('/') || value.contains('\\') || value.contains('\u0000') ||
            value.any { it.code < 0x20 }
        ) {
            throw CreativeException("invalidRequest", "invalid$field")
        }
    }

    const val CREATIVE_LIBRARY_OWNER = "creative-library"
}
