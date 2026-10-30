// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.terminalsessions

/**
 * G07.3A — the pure, bounded terminal-tab state machine used by the App host.
 *
 * This is deliberately NOT a second session authority: the native G04 domain
 * still owns every PTY session, process, workspace lease and settlement. The
 * registry only remembers which of those sessions the pane currently shows and
 * what local (never-durable) presentation label the user gave it. It is a
 * plain in-memory class with no Android, coroutine, I/O or native calls, so
 * every transition below is directly testable.
 *
 * Identity: a tab is keyed by the NATIVE-issued session identity (the engine
 * session id, which is also the G04 `sessionToken`). Before the native open
 * reply exists, the tab lives under [TerminalTabID.Pending] with a local
 * request id; only [adopt] can replace it with the real identity. A late reply
 * for a cancelled/fenced tab can therefore never adopt a different session.
 *
 * Capacity: at most [MAX_TABS] tabs per conversation (matching the engine's
 * two interactive role slots plus one bounded surface allowance for a run
 * session). [newTab] refuses beyond it instead of growing unbounded.
 */
internal object TerminalTabLimits {
    const val MAX_TABS = 2
    const val MAX_TITLE_CHARS = 40
    const val DEFAULT_TITLE = "Terminal"
}

/** One tab as the pane sees it. [sessionID] is the native identity, null only
 *  while a pending open has not been adopted. */
internal data class TerminalTabView(
    val tabID: String,
    val sessionID: String?,
    val conversationID: String,
    val title: String,
    val phase: String,
    val purpose: String,
    val selected: Boolean,
    val pending: Boolean,
) {
    /** A pending reservation is NOT a native session: it never counts as a
     *  live tab (no live dot, no attach, no live-file identity). */
    val isLive: Boolean
        get() = !pending && (phase == "starting" || phase == "running" || phase == "waitingOutput")
}

internal class TerminalTabRegistry {
    private data class Tab(
        var tabID: String,
        var sessionID: String?,
        val conversationID: String,
        var title: String,
        var phase: String,
        var purpose: String,
        var pendingRequestID: String?,
    )

    private val tabs = LinkedHashMap<String, Tab>() // tabID -> tab (insertion order = strip order)
    private val selected = HashMap<String, String>() // conversationID -> tabID
    /** Conversations that have owned at least one REAL native tab. Closing
     *  every tab is then an honest empty terminal, never a fall-back to the
     *  pre-tab conversation singleton (which still names a removed session). */
    private val nativeTabHistory = HashSet<String>()

    @Synchronized
    fun tabsFor(conversationID: String): List<TerminalTabView> {
        val current = selected[conversationID]
        return tabs.values.filter { it.conversationID == conversationID }.map { tab ->
            TerminalTabView(
                tabID = tab.tabID,
                sessionID = tab.sessionID,
                conversationID = tab.conversationID,
                title = tab.title,
                phase = tab.phase,
                purpose = tab.purpose,
                selected = tab.tabID == current,
                pending = tab.pendingRequestID != null,
            )
        }
    }

    @Synchronized
    fun current(conversationID: String): TerminalTabView? {
        val id = selected[conversationID] ?: return null
        val tab = tabs[id] ?: return null
        return tabsFor(conversationID).firstOrNull { it.tabID == tab.tabID }
    }

    @Synchronized
    fun find(sessionID: String): TerminalTabView? =
        tabs.values.firstOrNull { it.sessionID == sessionID }?.let { tab ->
            tabsFor(tab.conversationID).firstOrNull { it.tabID == tab.tabID }
        }

    /**
     * Reserves one pending tab for a dispatched open. The caller MUST either
     * [adopt] the native identity or [drop] the reservation; a refusal/timeout
     * never leaves a phantom live tab.
     */
    @Synchronized
    fun newTab(conversationID: String, requestID: String,
               title: String? = null, purpose: String = "interactive"): TerminalTabView? {
        if (tabs.values.count { it.conversationID == conversationID } >= TerminalTabLimits.MAX_TABS) return null
        if (tabs.values.any { it.pendingRequestID == requestID }) return null
        val ordinal = tabs.values.count { it.conversationID == conversationID } + 1
        val tab = Tab(
            tabID = pendingID(requestID),
            sessionID = null,
            conversationID = conversationID,
            title = sanitizeTitle(title) ?: "${TerminalTabLimits.DEFAULT_TITLE} $ordinal",
            phase = "starting",
            purpose = purpose,
            pendingRequestID = requestID,
        )
        tabs[tab.tabID] = tab
        // A brand-new conversation selects its first tab; an existing selection
        // stays put (a second tab is opened in the background, like a real tab
        // strip) and the pane can switch explicitly.
        selected.putIfAbsent(conversationID, tab.tabID)
        return findPending(requestID)
    }

    /** Replaces a pending tab's local id with the native session identity. */
    @Synchronized
    fun adopt(requestID: String, sessionID: String, phase: String = "starting"): TerminalTabView? {
        if (sessionID.isEmpty()) return null
        val tab = tabs.values.firstOrNull { it.pendingRequestID == requestID } ?: return null
        if (tabs.containsKey(sessionID) && sessionID != tab.tabID) return null
        val oldID = tab.tabID
        tabs.remove(oldID)
        tab.tabID = sessionID
        tab.sessionID = sessionID
        tab.phase = phase
        // The native identity is now the ONLY key: a repeated/duplicate
        // adoption for the old request must find no pending reservation.
        tab.pendingRequestID = null
        tabs[sessionID] = tab
        nativeTabHistory.add(tab.conversationID)
        if (selected[tab.conversationID] == oldID) selected[tab.conversationID] = sessionID
        return find(sessionID)
    }

    /** Removes a pending reservation that never became a live session. */
    @Synchronized
    fun drop(requestID: String): TerminalTabView? {
        val tab = tabs.values.firstOrNull { it.pendingRequestID == requestID } ?: return null
        tabs.remove(tab.tabID)
        if (selected[tab.conversationID] == tab.tabID) {
            val next = tabs.values.firstOrNull { it.conversationID == tab.conversationID }
            if (next == null) selected.remove(tab.conversationID) else selected[tab.conversationID] = next.tabID
        }
        return TerminalTabView(tab.tabID, null, tab.conversationID, tab.title, "closed",
            tab.purpose, false, false)
    }

    @Synchronized
    fun updatePhase(sessionID: String, phase: String): TerminalTabView? {
        val tab = tabs.values.firstOrNull { it.sessionID == sessionID } ?: return null
        if (tab.phase != phase) tab.phase = phase
        return find(sessionID)
    }

    @Synchronized
    fun rename(sessionID: String, title: String): TerminalTabView? {
        val tab = tabs.values.firstOrNull { it.sessionID == sessionID } ?: return null
        val clean = sanitizeTitle(title) ?: return null
        tab.title = clean
        return find(sessionID)
    }

    @Synchronized
    fun select(conversationID: String, tabID: String): TerminalTabView? {
        val tab = tabs[tabID]?.takeIf { it.conversationID == conversationID } ?: return null
        selected[conversationID] = tab.tabID
        // A pending tab has no sessionID, so `find(sessionID)` cannot address
        // it; resolve by the actual tab key instead. Selecting a pending tab
        // is a truthful selection (the pane then shows its disabled surface),
        // never a fall-back to another live PTY.
        return tabsFor(conversationID).firstOrNull { it.tabID == tab.tabID }
    }

    /**
     * Removes a settled tab (native terminal or explicit close). Returns the
     * tab that should now be selected, or null when none remains. The selection
     * moves to the next live tab, then the nearest remaining tab, never to a
     * different conversation.
     */
    @Synchronized
    fun close(sessionID: String): TerminalTabView? {
        val tab = tabs.values.firstOrNull { it.sessionID == sessionID } ?: return null
        tabs.remove(tab.tabID)
        if (selected[tab.conversationID] == tab.tabID) {
            val next = tabs.values.firstOrNull { it.conversationID == tab.conversationID && it.isLiveForSelection() }
                ?: tabs.values.firstOrNull { it.conversationID == tab.conversationID }
            if (next == null) selected.remove(tab.conversationID)
            else selected[tab.conversationID] = next.tabID
        }
        return current(tab.conversationID)
    }

    @Synchronized
    fun selectedSessionID(conversationID: String): String? {
        val id = selected[conversationID] ?: return null
        return tabs[id]?.sessionID
    }

    @Synchronized
    fun isEmpty(conversationID: String): Boolean =
        tabs.values.none { it.conversationID == conversationID }

    /** True once this conversation has owned at least one REAL native tab.
     *  A pending reservation that never adopted does not count. */
    @Synchronized
    fun hasNativeTabHistory(conversationID: String): Boolean =
        nativeTabHistory.contains(conversationID)

    /** Root retirement: every tab is a closed projection; sessions settle
     *  natively through the ordinary close/retire path, not here. The tab-era
     *  history is cleared with the retired generation, so a fresh Root may
     *  use the first-start compatibility path again. */
    @Synchronized
    fun clear() {
        tabs.clear()
        selected.clear()
        nativeTabHistory.clear()
    }

    private fun findPending(requestID: String): TerminalTabView? {
        val tab = tabs.values.firstOrNull { it.pendingRequestID == requestID } ?: return null
        return tabsFor(tab.conversationID).firstOrNull { it.tabID == tab.tabID }
    }

    private fun Tab.isLiveForSelection(): Boolean =
        pendingRequestID == null &&
            (phase == "starting" || phase == "running" || phase == "waitingOutput")

    private fun pendingID(requestID: String): String = "pending:" + requestID.take(48)

    private fun sanitizeTitle(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        val cleaned = trimmed.filter { character ->
            character.code in 0x20..0x7e || character.code in 0x4e00..0x9fff
        }
        return cleaned.take(TerminalTabLimits.MAX_TITLE_CHARS).takeIf { it.isNotEmpty() }
    }
}
