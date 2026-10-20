// SPDX-License-Identifier: MPL-2.0
//
// Explicit bound-workspace projection tests (Main's async-launch addendum #2):
// applyHostSnapshot must initialize/update the locked composer selection from
// ThreadUiState.boundWorkspaceId ONLY — never from projects.firstOrNull().
// Repository AGENTS forbid silently choosing the first project: the host's
// binding is authoritative, null is an honest unbound display, an unknown id
// cannot masquerade as a real workspace, and the send must never silently
// claim a different workspace than the binding. List ORDER is deliberately
// varied to prove no positional fallback exists.

package com.floe.android.feature.conversation

import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationWorkspaceBindingTest {

    private fun holderWith(
        projects: List<ProjectOptionUi>,
        binding: String?,
    ): Pair<RecordingHost, ConversationFlowHolder> {
        val host = RecordingHost()
        val h = ConversationFlowHolder(host, "conv-1")
        h.applyHostSnapshot(
            threadState(
                h.session,
                projects = projects,
                boundWorkspaceId = binding,
            ),
        )
        return host to h
    }

    @Test
    fun bindingSelectsTheBoundProjectRegardlessOfListOrder() {
        val projects = listOf(ProjectOptionUi("p-beta", "Beta"), ProjectOptionUi("p-alpha", "Alpha"))
        val (_, boundToAlpha) = holderWith(projects, binding = "p-alpha")
        assertEquals("p-alpha", boundToAlpha.selectedProjectId.value)

        val projectsReversed = listOf(ProjectOptionUi("p-alpha", "Alpha"), ProjectOptionUi("p-beta", "Beta"))
        val (_, boundToBeta) = holderWith(projectsReversed, binding = "p-beta")
        assertEquals("p-beta", boundToBeta.selectedProjectId.value)
    }

    @Test
    fun nullBindingStaysHonestUnboundAndNeverPicksTheFirstProject() {
        val projects = listOf(ProjectOptionUi("p-first", "First"), ProjectOptionUi("p-second", "Second"))
        val (host, unbound) = holderWith(projects, binding = null)
        assertEquals(null, unbound.selectedProjectId.value)

        // The launch carries the honest null: no silent workspace claim.
        unbound.onDraftChange(TextFieldValue("hello"))
        unbound.send()
        val launch = host.lastArgs("startRun")!![0] as RunLaunchRequest
        assertEquals(null, launch.workspaceId)
    }

    @Test
    fun unknownBindingIdDegradesToUnboundNotToArbitraryRow() {
        val (_, ghostBound) = holderWith(
            listOf(ProjectOptionUi("p-real", "Real")),
            binding = "p-ghost",
        )
        assertEquals(null, ghostBound.selectedProjectId.value)
    }

    @Test
    fun everyProjectionUpdateFollowsTheHostBindingExactly() {
        val host = RecordingHost()
        val h = ConversationFlowHolder(host, "conv-1")
        val projects = listOf(ProjectOptionUi("p-1", "One"), ProjectOptionUi("p-2", "Two"))

        h.applyHostSnapshot(threadState(h.session, projects = projects, boundWorkspaceId = "p-2"))
        assertEquals("p-2", h.selectedProjectId.value)

        // Ownership LOCKED to another task: a later authoritative binding
        // update is obeyed (host moves the task via its own flow).
        h.applyHostSnapshot(threadState(h.session, projects = projects, boundWorkspaceId = "p-1"))
        assertEquals("p-1", h.selectedProjectId.value)

        // The host unbinds: presentation must not keep asserting p-1.
        h.applyHostSnapshot(threadState(h.session, projects = projects, boundWorkspaceId = null))
        assertEquals(null, h.selectedProjectId.value)

        // Send after unbind honestly carries a null workspaceId.
        h.onDraftChange(TextFieldValue("next prompt"))
        h.send()
        val launch = host.lastArgs("startRun")!![0] as RunLaunchRequest
        assertEquals(null, launch.workspaceId)
    }

    @Test
    fun sendUsesTheBoundWorkspaceNeverTheFirstListRow() {
        val host = RecordingHost()
        val h = ConversationFlowHolder(host, "conv-1")
        val projects = listOf(ProjectOptionUi("p-first", "First"), ProjectOptionUi("p-chosen", "Chosen"))
        h.applyHostSnapshot(threadState(h.session, projects = projects, boundWorkspaceId = "p-chosen"))
        h.onDraftChange(TextFieldValue("work please"))

        h.send()

        val launch = host.lastArgs("startRun")!![0] as RunLaunchRequest
        assertEquals("p-chosen", launch.workspaceId)
    }
}
