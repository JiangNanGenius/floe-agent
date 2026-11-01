// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignTargetKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Source-authored target identity tests (NOT RUN).
 *
 * These prove the App builds design bindings only from explicit selections:
 * UUID-shaped Canvas/workspace identities, safe relative workspace references,
 * a real creative asset UUID and an explicit requested output kind. They do
 * not claim a native/UI/device result.
 */
class DesignTargetResolverTest {
    private val workspaceID = "11111111-1111-4111-8111-111111111111"
    private val canvasID = "22222222-2222-4222-8222-222222222222"
    private val documentID = "33333333-3333-4333-8333-333333333333"
    private val nodeID = "44444444-4444-4444-8444-444444444444"
    private val assetID = "55555555-5555-4555-8555-555555555555"
    private val taskID = "66666666-6666-4666-8666-666666666666"
    private val session = "12345678-1234-4234-8234-123456789012"

    @Test
    fun canvasBindingUsesTheRealEditorIdentity() {
        val binding = DesignTargetResolver.canvasBinding(
            canvasID = canvasID,
            documentID = documentID,
            nodeID = nodeID,
            sessionToken = session,
        )
        assertEquals(DesignTargetKind.CANVAS_NODE, binding.target.kind)
        assertEquals(canvasID, binding.target.ownerID)
        assertEquals(documentID, binding.target.documentID)
        assertEquals(nodeID, binding.target.sourceID)
        assertEquals(CreativeStorageLayer.AppOwned, binding.storage)
        DesignTargetResolver.validate(binding)
    }

    @Test
    fun canvasBindingRefusesNonUuidAndForeignSession() {
        assertRefused {
            DesignTargetResolver.canvasBinding(
                canvasID = "not-a-uuid",
                documentID = documentID,
                nodeID = nodeID,
                sessionToken = session,
            )
        }
        assertRefused {
            DesignTargetResolver.canvasBinding(
                canvasID = canvasID,
                documentID = documentID,
                nodeID = nodeID,
                sessionToken = "bad session",
            )
        }
    }

    @Test
    fun chatBindingUsesTheExactConversationMessageAndAttachment() {
        val messageID = "88888888-8888-4888-8888-888888888888"
        val binding = DesignTargetResolver.chatAttachmentBinding(
            conversationID = taskID,
            messageID = messageID,
            attachmentID = assetID,
            sessionToken = session,
        )
        assertEquals(DesignTargetKind.CHAT_ATTACHMENT, binding.target.kind)
        assertEquals(taskID, binding.target.ownerID)
        assertEquals(messageID, binding.target.documentID)
        assertEquals(assetID, binding.target.sourceID)
        assertEquals(taskID, binding.target.originConversationID)
        DesignTargetResolver.validate(binding)
    }

    @Test
    fun workspaceBindingNamesTheExactWorkspaceAndSafeRelativePath() {
        val binding = DesignTargetResolver.workspaceFileBinding(
            workspaceID = workspaceID,
            relativePath = "docs/design.md",
            sessionToken = session,
        )
        assertEquals(DesignTargetKind.FILE_DOCUMENT, binding.target.kind)
        assertEquals(workspaceID, binding.target.ownerID)
        assertEquals("docs/design.md", binding.target.sourceID)
        assertTrue(binding.storage is CreativeStorageLayer.Workspace)
        DesignTargetResolver.validate(binding)
    }

    @Test
    fun workspaceBindingRefusesTraversalAbsoluteAndEmptySegments() {
        listOf("../secret", "/etc/passwd", "a//b", "a/./b", "a\\b", "").forEach { path ->
            assertRefused {
                DesignTargetResolver.workspaceFileBinding(
                    workspaceID = workspaceID,
                    relativePath = path,
                    sessionToken = session,
                )
            }
        }
    }

    @Test
    fun workspaceValidateRefusesMismatchedStorageWorkspace() {
        val binding = DesignTargetResolver.workspaceFileBinding(
            workspaceID = workspaceID,
            relativePath = "docs/design.md",
            sessionToken = session,
        )
        assertRefused {
            DesignTargetResolver.validate(
                binding.copy(storage = CreativeStorageLayer.Workspace(
                    "77777777-7777-4777-8777-777777777777")),
            )
        }
        assertRefused {
            DesignTargetResolver.validate(binding.copy(storage = CreativeStorageLayer.AppOwned))
        }
    }

    @Test
    fun creativeBindingRequiresRetainedAssetUuidAndExplicitOutputKind() {
        val binding = DesignTargetResolver.creativeBinding(
            assetID = assetID,
            requestedOutputKind = DesignContentType.IMAGE,
            originConversationID = taskID,
            sessionToken = session,
        )
        assertEquals(DesignTargetKind.CREATIVE_DOCUMENT, binding.target.kind)
        assertEquals(DesignTargetResolver.CREATIVE_LIBRARY_OWNER, binding.target.ownerID)
        assertEquals(assetID, binding.target.sourceID)
        assertEquals(DesignContentType.IMAGE, binding.target.requestedOutputKind)
        assertEquals(taskID, binding.target.originConversationID)
        DesignTargetResolver.validate(binding)
    }

    @Test
    fun creativeBindingRefusesAProjectIdOrPathAsOwnerOrSource() {
        assertRefused {
            DesignTargetResolver.creativeBinding(
                ownerID = "../creative-library",
                assetID = assetID,
                requestedOutputKind = DesignContentType.IMAGE,
                originConversationID = null,
                sessionToken = session,
            )
        }
        assertRefused {
            DesignTargetResolver.creativeBinding(
                assetID = "/data/projects/1",
                requestedOutputKind = DesignContentType.IMAGE,
                originConversationID = null,
                sessionToken = session,
            )
        }
    }

    @Test
    fun documentSessionTokenIsStableForTheExactRequestAndChangesWithPath() {
        val one = DesignTargetResolver.documentSessionToken(
            taskID, workspaceID, "docs/one.md", 9L)
        val again = DesignTargetResolver.documentSessionToken(
            taskID, workspaceID, "docs/one.md", 9L)
        val other = DesignTargetResolver.documentSessionToken(
            taskID, workspaceID, "docs/two.md", 9L)
        assertEquals(one, again)
        assertNotEquals(one, other)
        assertTrue(one.matches(Regex("[0-9a-f-]{36}")))
    }

    @Test
    fun targetKeyIncludesTheExactEditorSession() {
        val binding = DesignTargetResolver.canvasBinding(
            canvasID, documentID, nodeID, session)
        val otherSession = DesignTargetResolver.canvasBinding(
            canvasID, documentID, nodeID, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        assertNotEquals(
            DesignTargetResolver.targetKey(binding),
            DesignTargetResolver.targetKey(otherSession),
        )
    }

    private fun assertRefused(block: () -> Unit) {
        try {
            block()
            fail("expected a typed design target refusal")
        } catch (_: CreativeException) {
            // Expected.
        }
    }
}
