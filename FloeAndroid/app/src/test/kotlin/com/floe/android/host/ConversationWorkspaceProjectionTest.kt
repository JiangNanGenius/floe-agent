// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Additive `conversation.get.workspace` projection regression (workspace-core
 * batch 2026-10-23, job-d54a914f83a54585).
 *
 * Authored NOTRUN — source-authored only; no compile/run claim here. Main
 * runs the focused JVM filter named in SOURCE_READY.json.
 *
 * Source proof: `RuntimeFacadeConversations.get(conversationID:)` projects
 * the REAL durable ownership binding through the ORIGINAL WorkspaceStore
 * authority (ownership row -> workspace row) as the additive `workspace`
 * member; an unbound header (production `conversation.create` binds no
 * workspace; a temporary session owns no durable row) answers JSON null.
 * The pre-fix `ThreadProjectionBuilder.build()` pinned
 * `projects = emptyList(), boundWorkspaceId = null` unconditionally, so the
 * composer chip showed "No workspace" and the sidebar "No projects yet" even
 * after the first real launch committed a private-task workspace row. These
 * tests pin the honest decoder + builder against core-shaped replies.
 */
class ConversationWorkspaceProjectionTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val workspaceId = "77777777-7777-4777-8777-777777777777"

    private fun replyJson(workspaceMember: String): String =
        """{"conversationID":"$conversationId","title":"Task",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
            """"version":"digest-9"},""" +
            """"runs":[{"runID":"33333333-3333-4333-8333-333333333333",""" +
            """"state":"completed","modelName":"QA","startedAt":"2026-10-23T01:00:00.000Z"}],""" +
            """"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"},""" +
            """"workspace":$workspaceMember}"""

    private fun decode(workspaceMember: String) =
        ConversationWire.decodeSessionReply(
            Json.parseToJsonElement(replyJson(workspaceMember)).jsonObject)!!

    /** JSON null (the honest unbound) decodes to a null binding — never an
     * empty object reinterpretation, never a guessed workspace. */
    @Test
    fun nullMemberDecodesToHonestUnbound() {
        val reply = decode("null")
        assertNull(reply.workspace)
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(reply)
        val state = builder.build()
        assertTrue("an unbound thread projects NO workspaces", state.projects.isEmpty())
        assertNull("a null binding never fakes an id", state.boundWorkspaceId)
    }

    /** A legacy reply WITHOUT the additive member is the same honest
     * unbound (forward-compatible decode, never a synthesized binding). */
    @Test
    fun absentMemberDecodesToHonestUnbound() {
        val legacy = """{"conversationID":"$conversationId","title":"Task",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
            """"version":"digest-9"},"runs":[],"pendingInputs":[],""" +
            """"taskPolicy":{"resolvedApprovalMode":"ask"}}"""
        val reply = ConversationWire.decodeSessionReply(
            Json.parseToJsonElement(legacy).jsonObject)!!
        assertNull(reply.workspace)
    }

    /** The REAL durable binding travels to the thread state as exactly ONE
     * project entry and the matching bound id (the composer chip's name now
     * comes from the store's row, and `applyHostSnapshot`'s selectedProjectId
     * gate sees the same identity). */
    @Test
    fun boundRowProjectsExactlyOneEntryAndBoundId() {
        val reply = decode(
            """{"workspaceID":"$workspaceId","name":"Readiness probe","kind":"privateTask"}""")
        val workspace = reply.workspace!!
        assertEquals(workspaceId, workspace.id)
        assertEquals("Readiness probe", workspace.name)
        assertEquals("privateTask", workspace.kind)
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(reply)
        val state = builder.build()
        assertEquals(listOf(workspaceId), state.projects.map { it.id })
        assertEquals("Readiness probe", state.projects.single().name)
        assertEquals(workspaceId, state.boundWorkspaceId)
    }

    /** A partial foreign object (no real identity, or no persisted name)
     * decodes to null — the App shows the honest unbound instead of binding
     * a guessed workspace (same strict rule as the plan/goal summaries). */
    @Test
    fun malformedObjectsDecodeToNull() {
        assertNull(decode("""{"name":"no identity"}""").workspace)
        assertNull(decode("""{"workspaceID":"$workspaceId"}""").workspace)
        assertNull(decode("""{}""").workspace)
    }

    /** The CURRENT page is the whole truth: a refreshed reply without the
     * binding CLEARS it (a moved/deleted ownership row is never shadow-
     * projected from an older page). */
    @Test
    fun refreshedUnboundPageClearsEarlierBinding() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(
            """{"workspaceID":"$workspaceId","name":"Old","kind":"privateTask"}"""))
        assertEquals(workspaceId, builder.build().boundWorkspaceId)
        builder.applySession(decode("null"))
        assertNull(builder.build().boundWorkspaceId)
        assertTrue(builder.build().projects.isEmpty())
    }

    /** A name beyond the wire bound is clipped by the decoder (the native
     * row is already written trimmed; the guard keeps a legacy row from
     * widening the chip label unboundedly). */
    @Test
    fun longNameIsBoundedByTheDecoder() {
        val long = "字".repeat(200)
        val reply = decode(
            """{"workspaceID":"$workspaceId","name":"$long","kind":"privateTask"}""")
        assertEquals(120, reply.workspace!!.name.length)
    }
}
