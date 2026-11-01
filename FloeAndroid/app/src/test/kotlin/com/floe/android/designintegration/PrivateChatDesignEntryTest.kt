// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignTargetKind
import com.floe.android.feature.canvas.ui.design.DesignSessionProvider
import com.floe.android.feature.canvas.ui.design.DesignSessionRequest
import com.floe.android.feature.canvas.ui.design.DesignWorkflowController
import com.floe.android.feature.conversation.AttachmentDesignRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-authored private-chat attachment entry tests (NOT RUN here).
 *
 * The real persisted conversation/message/attachment identity is the only
 * source; a temporary, retired or foreign holder is denied before any session
 * is created, and a late callback from conversation A can never bind a design
 * session over conversation B.
 */
class PrivateChatDesignEntryTest {
    private val conversationID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val messageID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val attachmentID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    private val request = AttachmentDesignRequest(
        conversationId = conversationID,
        messageId = messageID,
        attachmentId = attachmentID,
        displayName = "Sketch.png",
        isImage = true,
    )

    private class CountingSessions : DesignSessionProvider {
        var acquired = 0
        override fun acquire(request: DesignSessionRequest): DesignWorkflowController {
            acquired += 1
            throw UnsupportedOperationException("must not create a controller in these cases")
        }

        override fun release(controller: DesignWorkflowController) = Unit
    }

    @Test
    fun onlyTheLiveNonTemporarySameConversationIsEligible() {
        assertTrue(
            PrivateChatDesignEntry.isEligible(request, conversationID, false, false),
        )
        assertFalse(
            PrivateChatDesignEntry.isEligible(request, conversationID, true, false),
        )
        assertFalse(
            PrivateChatDesignEntry.isEligible(request, conversationID, null, false),
        )
        assertFalse(
            PrivateChatDesignEntry.isEligible(request, conversationID, false, true),
        )
        assertFalse(
            PrivateChatDesignEntry.isEligible(
                request, "dddddddd-dddd-4ddd-8ddd-dddddddddddd", false, false),
        )
    }

    @Test
    fun bindingCarriesTheExactPersistedIdentityAndAFreshEditorToken() {
        val token = CreativeSessionTokens.newToken()
        val binding = PrivateChatDesignEntry.binding(request, token)!!
        assertEquals(DesignTargetKind.CHAT_ATTACHMENT, binding.target.kind)
        assertEquals(conversationID, binding.target.ownerID)
        assertEquals(messageID, binding.target.documentID)
        assertEquals(attachmentID, binding.target.sourceID)
        assertEquals(conversationID, binding.target.originConversationID)
        assertTrue(binding.storage is CreativeStorageLayer.AppOwned)
        assertEquals(CreativeOriginContext.CHAT, binding.origin?.kind)
        assertEquals(conversationID, binding.origin?.ownerID)
        assertEquals(token, binding.sessionToken)
        assertTrue(CreativeSessionTokens.isValid(binding.sessionToken))
    }

    @Test
    fun saveableIdentityKeepsTheExactIdsAndOneEditorToken() {
        val identity = PrivateChatDesignEntry.identity(request)
        assertEquals(request, identity.request())
        assertTrue(CreativeSessionTokens.isValid(identity.sessionToken))
        assertEquals(identity, PrivateChatDesignEntry.identity(request).copy(
            sessionToken = identity.sessionToken,
        ))
    }

    @Test
    fun invalidPersistedIdentityIsRefusedBeforeAnySession() {
        val token = CreativeSessionTokens.newToken()
        assertNull(PrivateChatDesignEntry.binding(request.copy(attachmentId = "not-a-uuid"), token))
        assertNull(PrivateChatDesignEntry.binding(request.copy(messageId = ""), token))
        assertNull(PrivateChatDesignEntry.binding(request.copy(conversationId = ""), token))
    }

    @Test
    fun temporaryChatNeverCreatesASession() {
        val sessions = CountingSessions()
        val opened = PrivateChatDesignEntry.open(
            sessions = sessions,
            request = request,
            title = "Sketch.png",
            kindLabel = "Chat attachment",
            isCurrent = { false },
        )
        assertNull(opened)
        assertEquals(0, sessions.acquired)
    }

    @Test
    fun lateCallbackAfterTheHolderChangedFencesTheOldConversation() {
        val sessions = CountingSessions()
        var checks = 0
        val opened = PrivateChatDesignEntry.open(
            sessions = sessions,
            request = request,
            title = "Sketch.png",
            kindLabel = "Chat attachment",
            // First check passes; the holder changes before the session is
            // acquired, so the second check must refuse.
            isCurrent = { checks++ == 0 },
        )
        assertNull(opened)
        assertEquals(0, sessions.acquired)
    }
}
