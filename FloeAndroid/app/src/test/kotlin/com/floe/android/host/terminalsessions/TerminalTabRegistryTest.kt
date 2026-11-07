// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.terminalsessions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G07.3A authored regression: the bounded terminal-tab state machine.
 *
 * It is deliberately a pure JVM test: no Android, no native, no device. The
 * REAL PTY/session authority remains the native G04 domain; these assertions
 * pin only the presentation/identity rules the pane depends on:
 *  * two tabs, a third refused;
 *  * a pending open is never a live tab until the native identity is adopted;
 *  * a late/stale adoption cannot claim another tab's identity;
 *  * rename is local and bounded; close selects a survivor, never another
 *    conversation.
 */
class TerminalTabRegistryTest {

    @Test
    fun `GUI control retains capacity and identity without becoming a human tab`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "gui", paneVisible = false)
        assertTrue(registry.paneTabsFor("conv-1").isEmpty())
        val control = requireNotNull(registry.adopt("gui", "control"))
        assertFalse(control.paneVisible)
        assertNotNull(registry.find("control"))
        assertNull(registry.current("conv-1"))
        assertFalse(registry.hasNativeTabHistory("conv-1"))
        assertNull(registry.select("conv-1", "control"))
        val manual = requireNotNull(registry.newTab("conv-1", "human"))
        assertEquals("Terminal 1", manual.title)
        registry.adopt("human", "human-session")
        assertTrue(registry.hasNativeTabHistory("conv-1"))
        assertEquals(listOf("human-session"), registry.paneTabsFor("conv-1").map { it.sessionID })
        // Hiding a control PTY does not raise the real two-session limit.
        assertNull(registry.newTab("conv-1", "third"))
    }

    @Test
    fun `closing or dropping human tabs never selects the GUI control`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "gui", paneVisible = false)
        registry.adopt("gui", "control")
        registry.newTab("conv-1", "human")
        registry.adopt("human", "human-session")
        assertNull(registry.close("human-session"))
        assertNull(registry.selectedSessionID("conv-1"))
        assertNotNull(registry.find("control"))
        registry.newTab("conv-1", "replacement")
        registry.drop("replacement")
        assertNull(registry.current("conv-1"))
        assertNotNull(registry.find("control"))
    }

    @Test
    fun `two tabs are admitted and a third is refused before any native open`() {
        val registry = TerminalTabRegistry()
        val first = registry.newTab("conv-1", "req-1")
        val second = registry.newTab("conv-1", "req-2")
        assertNotNull(first)
        assertNotNull(second)
        assertNull(registry.newTab("conv-1", "req-3"))
        assertEquals(2, registry.tabsFor("conv-1").size)
        assertTrue(registry.tabsFor("conv-1").all { it.pending && it.sessionID == null })
        // The first tab is selected; opening a second does not steal focus.
        assertEquals("req-1", registry.current("conv-1")?.tabID?.removePrefix("pending:"))
    }

    @Test
    fun `replacement default title differs from the surviving tab without increasing the limit`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1")
        registry.adopt("req-1", "session-A")
        registry.newTab("conv-1", "req-2")
        val survivor = registry.adopt("req-2", "session-B")!!
        registry.updatePhase("session-A", "exited")
        registry.close("session-A")
        val replacement = registry.newTab("conv-1", "req-3")!!
        assertFalse(survivor.title == replacement.title)
        assertEquals(2, registry.tabsFor("conv-1").size)
        assertNull(registry.newTab("conv-1", "req-4"))
    }

    @Test
    fun `adopt replaces the pending identity exactly once`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1")
        val adopted = registry.adopt("req-1", "session-A")
        assertEquals("session-A", adopted?.sessionID)
        assertFalse(adopted?.pending ?: true)
        // A second adoption for the same request has no pending tab to claim.
        assertNull(registry.adopt("req-1", "session-B"))
        assertEquals(listOf("session-A"), registry.tabsFor("conv-1").mapNotNull { it.sessionID })
        // A pending tab that was already adopted cannot be dropped.
        assertNull(registry.drop("req-1"))
    }

    @Test
    fun `drop removes only the failed pending reservation`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1")
        registry.newTab("conv-1", "req-2")
        val dropped = registry.drop("req-2")
        assertNotNull(dropped)
        assertEquals(1, registry.tabsFor("conv-1").size)
        assertEquals(listOf("req-1"), registry.tabsFor("conv-1").map { it.tabID.removePrefix("pending:") })
    }

    @Test
    fun `two live tabs keep independent phases and a third phase update is ignored`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        registry.newTab("conv-1", "req-2").also { registry.adopt("req-2", "session-B") }
        registry.updatePhase("session-A", "running")
        registry.updatePhase("session-B", "waitingOutput")
        assertEquals("running", registry.find("session-A")?.phase)
        assertEquals("waitingOutput", registry.find("session-B")?.phase)
        assertNull(registry.updatePhase("session-unknown", "running"))
    }

    @Test
    fun `rename is local bounded and refuses a blank title`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        val renamed = registry.rename("session-A", "  Build logs  ")
        assertEquals("Build logs", renamed?.title)
        assertNull(registry.rename("session-A", "   "))
        val long = registry.rename("session-A", "x".repeat(200))
        assertEquals(TerminalTabLimits.MAX_TITLE_CHARS, long?.title?.length)
        // Rename never touches the native identity.
        assertEquals("session-A", registry.find("session-A")?.sessionID)
    }

    @Test
    fun `select switches the visible tab without touching any phase`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        registry.newTab("conv-1", "req-2").also { registry.adopt("req-2", "session-B") }
        registry.updatePhase("session-A", "running")
        registry.updatePhase("session-B", "running")
        val selected = registry.select("conv-1", "session-B")
        assertEquals("session-B", selected?.sessionID)
        assertEquals("session-A", registry.find("session-A")?.sessionID)
        assertEquals("running", registry.find("session-A")?.phase)
        // A tab from another conversation cannot be selected.
        assertNull(registry.select("conv-2", "session-B"))
    }

    @Test
    fun `a pending tab is selectable but never a live or addressable session`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        val pending = requireNotNull(registry.newTab("conv-1", "req-2"))
        val selected = requireNotNull(registry.select("conv-1", pending.tabID))
        assertNull("a pending tab has no native identity", selected.sessionID)
        assertTrue(selected.selected)
        assertTrue(selected.pending)
        assertFalse("a pending reservation must not show the live dot", selected.isLive)
        // Selection is truthful, yet no session is addressable for this
        // conversation while the reservation is pending.
        assertNull(registry.selectedSessionID("conv-1"))
        assertEquals("session-A", registry.find("session-A")?.sessionID)
        // Late adoption follows the selection to the real identity.
        val adopted = requireNotNull(registry.adopt("req-2", "session-B"))
        assertTrue(adopted.selected)
        assertTrue(adopted.isLive)
        assertEquals("session-B", registry.selectedSessionID("conv-1"))
    }

    @Test
    fun `closing the selected tab never treats a pending reservation as a live survivor`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        val pending = requireNotNull(registry.newTab("conv-1", "req-2"))
        registry.updatePhase("session-A", "running")
        registry.select("conv-1", "session-A")
        val survivor = registry.close("session-A")
        // Only the pending reservation remains. It is selected as the nearest
        // remaining tab, but it is NOT advertised as a live survivor.
        assertEquals(pending.tabID, survivor?.tabID)
        assertNull(survivor?.sessionID)
        assertFalse(survivor?.isLive ?: true)
    }

    @Test
    fun `closing the selected tab moves selection to a live survivor only`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        registry.newTab("conv-1", "req-2").also { registry.adopt("req-2", "session-B") }
        registry.select("conv-1", "session-A")
        registry.updatePhase("session-A", "running")
        registry.updatePhase("session-B", "running")

        val survivor = registry.close("session-A")
        assertEquals("session-B", survivor?.sessionID)
        assertEquals("session-B", registry.selectedSessionID("conv-1"))
        assertEquals(1, registry.tabsFor("conv-1").size)
        assertNull(registry.find("session-A"))
    }

    @Test
    fun `closing the last tab keeps tab-era history without resurrecting a session`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        assertTrue(registry.hasNativeTabHistory("conv-1"))
        registry.close("session-A")
        assertTrue(registry.isEmpty("conv-1"))
        assertNull(registry.selectedSessionID("conv-1"))
        assertTrue("the conversation owned a real tab; it is now an empty terminal",
            registry.hasNativeTabHistory("conv-1"))
        assertFalse("another conversation never inherits the history",
            registry.hasNativeTabHistory("conv-2"))
    }

    @Test
    fun `closing the last tab clears selection and never leaks to another conversation`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        registry.newTab("conv-2", "req-2").also { registry.adopt("req-2", "session-B") }
        registry.select("conv-2", "session-B")

        val empty = registry.close("session-A")
        assertNull(empty)
        assertNull(registry.selectedSessionID("conv-1"))
        assertEquals("session-B", registry.selectedSessionID("conv-2"))
        assertEquals(1, registry.tabsFor("conv-2").size)
    }

    @Test
    fun `retirement clears every projection without inventing sessions`() {
        val registry = TerminalTabRegistry()
        registry.newTab("conv-1", "req-1").also { registry.adopt("req-1", "session-A") }
        registry.newTab("conv-1", "req-2").also { registry.adopt("req-2", "session-B") }
        registry.clear()
        assertTrue(registry.tabsFor("conv-1").isEmpty())
        assertNull(registry.current("conv-1"))
        assertNull(registry.find("session-A"))
    }
}
