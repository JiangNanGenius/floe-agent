// SPDX-License-Identifier: MPL-2.0
//
// Innermost-first back stack for the Skills/MCP flow. The iOS hierarchy is
// Skills hub → Connectors → MCP servers → MCP editor, with the skill sheets
// (creator / finder / install review / upgrade) presented above the hub.
// "Back closes innermost sheet → editor → MCP list → connectors → hub →
// settings" (the base hub never pops; the host's settings sheet regains
// control instead — the same contract as the provider flow).

package com.floe.android.feature.integrations

import androidx.compose.runtime.mutableStateListOf

/** Panes owned by this module, innermost-last. */
enum class IntegrationsPane {
    /** Root segmented hub inside the settings detail column (stack base). */
    SKILLS_HUB,

    /** Connectors hub (⇄ ConnectorsView). */
    CONNECTORS,

    /** MCP server list (⇄ MCPServersView). */
    MCP_SERVERS,

    /** MCP add/edit form sheet (⇄ MCPServerEditor). Key = editorId. */
    MCP_EDITOR,

    /** Skill Creator sheet (⇄ SkillCreatorSheet). Key = formId. */
    SKILL_CREATOR,

    /** Skill Finder sheet (⇄ SkillFinderSheet). Key = formId. */
    SKILL_FINDER,

    /** Folder-import sheet (staged opaque reference; Android surface for
     * ⇄ the fileImporter step). Key = formId. */
    SKILL_IMPORT,

    /** Install review sheet (⇄ SkillInstallReviewSheet). Key = reviewId. */
    INSTALL_REVIEW,

    /** GitHub upgrade sheet (⇄ SkillGitHubUpgradeSheet). Key = skillId. */
    UPGRADE_REVIEW,
}

/** A stack entry keyed by pane + a caller-visible key. */
data class IntegrationsPaneEntry(val pane: IntegrationsPane, val key: String)

/**
 * Pure navigation state. The session holder owns one instance so config
 * changes keep the same innermost-first order; no Compose APIs here so the
 * ordering is unit-testable without a device.
 */
class IntegrationsNavStack {

    private val entries =
        mutableStateListOf(IntegrationsPaneEntry(IntegrationsPane.SKILLS_HUB, "hub"))

    /** Snapshot for the destination to render panes base→top. */
    fun snapshot(): List<IntegrationsPaneEntry> = entries.toList()

    val top: IntegrationsPaneEntry get() = entries.last()

    val depth: Int get() = entries.size

    fun contains(pane: IntegrationsPane): Boolean = entries.any { it.pane == pane }

    fun entryFor(pane: IntegrationsPane): IntegrationsPaneEntry? =
        entries.lastOrNull { it.pane == pane }

    /** Push ignores duplicates of the same pane+key. */
    fun push(pane: IntegrationsPane, key: String) {
        if (entries.any { it.pane == pane && it.key == key }) return
        entries.add(IntegrationsPaneEntry(pane, key))
    }

    /** Pop the top pane only; the base hub never pops. */
    fun back(): Boolean {
        if (entries.size <= 1) return false
        entries.removeAt(entries.lastIndex)
        return true
    }

    /** Close a named pane only when it is on top (explicit Cancel/Done). */
    fun closeTopIf(pane: IntegrationsPane, key: String): Boolean {
        if (entries.lastOrNull() == IntegrationsPaneEntry(pane, key)) {
            entries.removeAt(entries.lastIndex)
            return true
        }
        return false
    }

    /** Hard-close everything above the hub (leaving settings). */
    fun resetToBase() {
        entries.clear()
        entries.add(IntegrationsPaneEntry(IntegrationsPane.SKILLS_HUB, "hub"))
    }
}
