// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.terminalsessions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G07.3A authored regression for the pane's ONE addressable target.
 *
 * The retained device failure is a pending second tab whose click fell back to
 * the live first PTY: input typed while tab 2 was pending reached session A.
 * These assertions pin the pure selection rule the pane now consumes:
 *  * a pending tab is never addressable and never borrows A's engine/screen;
 *  * the legacy conversation projection is used ONLY when no tab exists;
 *  * late adoption makes exactly the adopted session addressable.
 */
class TerminalPaneTargetTest {

    private fun liveTab(registry: TerminalTabRegistry, conversation: String,
                        request: String, session: String): TerminalTabView {
        registry.newTab(conversation, request)
        return requireNotNull(registry.adopt(request, session))
    }

    @Test
    fun `no tabs is the only legacy conversation fallback`() {
        val target = terminalPaneTarget(emptyList())
        assertNull(target.sessionID)
        assertFalse(target.pending)
        assertTrue(target.legacyConversation)
    }

    @Test
    fun `a selected pending tab is never addressable and never borrows the live tab`() {
        val registry = TerminalTabRegistry()
        val first = liveTab(registry, "conv-1", "req-a", "session-A")
        assertTrue(first.selected)
        val pending = registry.newTab("conv-1", "req-b")
        requireNotNull(pending)
        // The user explicitly selects the still-pending second tab.
        val selectedPending = requireNotNull(registry.select("conv-1", pending.tabID))
        assertNull(selectedPending.sessionID)
        assertTrue(selectedPending.selected)
        assertFalse(selectedPending.isLive)

        val target = terminalPaneTarget(registry.tabsFor("conv-1"))
        assertNull("a pending tab must not resolve to A", target.sessionID)
        assertTrue(target.pending)
        assertFalse("tabs exist, so the legacy conversation projection is OFF",
            target.legacyConversation)
        // A is still a real tab with its own identity; it is simply not shown.
        assertEquals("session-A", registry.find("session-A")?.sessionID)
        assertEquals("session-A", registry.tabsFor("conv-1").first().sessionID)
    }

    @Test
    fun `a selected live tab resolves to exactly its own session`() {
        val registry = TerminalTabRegistry()
        liveTab(registry, "conv-1", "req-a", "session-A")
        val second = liveTab(registry, "conv-1", "req-b", "session-B")
        registry.select("conv-1", second.tabID)
        val target = terminalPaneTarget(registry.tabsFor("conv-1"))
        assertEquals("session-B", target.sessionID)
        assertFalse(target.pending)
        assertFalse(target.legacyConversation)
    }

    @Test
    fun `late adoption makes only the adopted session addressable`() {
        val registry = TerminalTabRegistry()
        liveTab(registry, "conv-1", "req-a", "session-A")
        val pending = requireNotNull(registry.newTab("conv-1", "req-b"))
        registry.select("conv-1", pending.tabID)
        assertTrue(terminalPaneTarget(registry.tabsFor("conv-1")).pending)

        val adopted = requireNotNull(registry.adopt("req-b", "session-B"))
        assertFalse(adopted.pending)
        assertTrue("selection follows the adopted identity", adopted.selected)
        val target = terminalPaneTarget(registry.tabsFor("conv-1"))
        assertEquals("session-B", target.sessionID)
        assertFalse(target.pending)
        assertFalse(target.legacyConversation)
    }

    @Test
    fun `a refused pending drop returns selection to the surviving live tab`() {
        val registry = TerminalTabRegistry()
        liveTab(registry, "conv-1", "req-a", "session-A")
        val pending = requireNotNull(registry.newTab("conv-1", "req-b"))
        registry.select("conv-1", pending.tabID)
        assertTrue(requireNotNull(registry.drop("req-b")).tabID.startsWith("pending:"))
        val target = terminalPaneTarget(registry.tabsFor("conv-1"))
        assertEquals("session-A", target.sessionID)
        assertFalse(target.pending)
    }
}
