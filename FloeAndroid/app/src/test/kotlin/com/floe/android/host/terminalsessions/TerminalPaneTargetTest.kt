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
        assertFalse("a conversation that never had a tab is not an empty tab-era pane",
            target.emptyAfterNativeTabs)
    }

    @Test
    fun `closing every native tab is an empty terminal not the legacy singleton`() {
        val registry = TerminalTabRegistry()
        liveTab(registry, "conv-1", "req-a", "session-A")
        liveTab(registry, "conv-1", "req-b", "session-B")
        assertTrue(registry.hasNativeTabHistory("conv-1"))
        requireNotNull(registry.close("session-A"))
        // Closing the final tab returns no successor; the empty state is the
        // truthful outcome, not another session.
        assertNull(registry.close("session-B"))
        assertTrue(registry.tabsFor("conv-1").isEmpty())

        val target = terminalPaneTarget(
            registry.tabsFor("conv-1"),
            hasNativeTabHistory = registry.hasNativeTabHistory("conv-1"),
        )
        assertNull("no removed session is addressable", target.sessionID)
        assertFalse(target.pending)
        assertFalse("the pre-tab conversation projection must never be resurrected",
            target.legacyConversation)
        assertTrue("the pane must show its truthful empty state",
            target.emptyAfterNativeTabs)
    }

    @Test
    fun `a refused pending open alone never marks the tab era`() {
        val registry = TerminalTabRegistry()
        val pending = requireNotNull(registry.newTab("conv-1", "req-refused"))
        registry.select("conv-1", pending.tabID)
        requireNotNull(registry.drop("req-refused"))
        assertFalse(registry.hasNativeTabHistory("conv-1"))
        val target = terminalPaneTarget(
            registry.tabsFor("conv-1"),
            hasNativeTabHistory = registry.hasNativeTabHistory("conv-1"),
        )
        assertTrue("no real native tab ever existed: first-start compatibility remains",
            target.legacyConversation)
        assertFalse(target.emptyAfterNativeTabs)
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
