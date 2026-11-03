// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.ui.design.DesignSessionProvider
import com.floe.android.feature.canvas.ui.design.DesignSessionRequest
import com.floe.android.feature.canvas.ui.design.DesignTargetDescriptor
import com.floe.android.feature.canvas.ui.design.DesignWorkflowController
import com.floe.android.feature.conversation.AttachmentDesignRequest

/** One App-owned private-chat design session bound to a real attachment row. */
internal data class ChatDesignSession(
    val binding: DesignTargetBinding,
    val controller: DesignWorkflowController,
)

/**
 * Saveable identity of one private-chat design session.
 *
 * It contains only the REAL persisted conversation/message/attachment ids
 * projected by the conversation feature plus the App editor token. It survives
 * rotation so the retained controller can be re-acquired; it does not survive
 * process death (the retained design map is RAM-only by contract).
 */
internal data class ChatDesignIdentity(
    val conversationId: String,
    val messageId: String,
    val attachmentId: String,
    val displayName: String,
    val isImage: Boolean,
    val sessionToken: String,
) {
    fun request(): AttachmentDesignRequest = AttachmentDesignRequest(
        conversationId = conversationId,
        messageId = messageId,
        attachmentId = attachmentId,
        displayName = displayName,
        isImage = isImage,
    )
}

/**
 * Private-chat attachment design entry.
 *
 * The source of identity is the REAL persisted conversation/message/attachment
 * selection projected by the conversation feature, not message text or a model
 * payload. [DesignTargetResolver.chatAttachmentBinding] validates the UUIDs and
 * a fresh editor session token is minted once per session; the native chat
 * owner resolves the attachment row (application-support storage only) and
 * re-verifies its bytes.
 *
 * Temporary chats are denied here as well as hidden by the feature: there is
 * no persistent Design/staging/keep surface in a temporary session.
 * [isCurrent] is evaluated BOTH when the action is requested and immediately
 * before the retained controller is created, so a late callback from
 * conversation A can never open a design session over conversation B.
 */
internal object PrivateChatDesignEntry {
    fun identity(request: AttachmentDesignRequest): ChatDesignIdentity = ChatDesignIdentity(
        conversationId = request.conversationId,
        messageId = request.messageId,
        attachmentId = request.attachmentId,
        displayName = request.displayName,
        isImage = request.isImage,
        sessionToken = CreativeSessionTokens.newToken(),
    )

    fun open(
        sessions: DesignSessionProvider,
        request: AttachmentDesignRequest,
        title: String,
        kindLabel: String,
        isCurrent: () -> Boolean,
    ): ChatDesignSession? = reopen(
        sessions = sessions,
        identity = identity(request),
        title = title,
        kindLabel = kindLabel,
        isCurrent = isCurrent,
    )

    /** Re-acquire the retained controller for this exact saved identity. */
    fun reopen(
        sessions: DesignSessionProvider,
        identity: ChatDesignIdentity,
        title: String,
        kindLabel: String,
        isCurrent: () -> Boolean,
    ): ChatDesignSession? {
        if (!isCurrent()) return null
        val request = identity.request()
        val targetBinding = binding(request, identity.sessionToken) ?: return null
        if (!isCurrent()) return null
        val controller = runCatching {
            sessions.acquire(
                DesignSessionRequest(
                    binding = targetBinding,
                    descriptor = DesignTargetDescriptor(
                        title = title.ifBlank { identity.displayName },
                        kindLabel = kindLabel,
                        expectedRevision = null,
                    ),
                ),
            )
        }.getOrNull() ?: return null
        return ChatDesignSession(binding = targetBinding, controller = controller)
    }

    /**
     * Exact persisted-identity binding, or null for an invalid id (the native
     * owner would refuse it too). The session token is an App editor token,
     * never a task/attachment id and never a grant.
     */
    internal fun binding(
        request: AttachmentDesignRequest,
        sessionToken: String,
    ): DesignTargetBinding? = runCatching {
        DesignTargetResolver.chatAttachmentBinding(
            conversationID = request.conversationId,
            messageID = request.messageId,
            attachmentID = request.attachmentId,
            sessionToken = sessionToken,
        )
    }.getOrNull()

    /** True only for the exact live, non-temporary conversation holder. */
    fun isEligible(
        request: AttachmentDesignRequest,
        holderConversationId: String,
        holderIsTemporary: Boolean?,
        holderRetired: Boolean,
    ): Boolean =
        !holderRetired &&
            holderIsTemporary == false &&
            holderConversationId == request.conversationId
}
