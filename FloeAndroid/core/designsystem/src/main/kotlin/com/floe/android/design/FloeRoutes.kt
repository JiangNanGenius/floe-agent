// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

/**
 * Information-architecture mirror of the locked iOS definitions
 * (`Shell/AppDestination.swift`, `Shell/AppRouter.swift`,
 * `Settings/SettingsRootView.swift`). Case order is the locked display
 * order — it must not be reordered without a product decision, mirroring the
 * iOS comment. Android G01 renders only part of this tree; the rest is
 * scaffolding for later goals with truthful availability.
 */

/** Workbench selections (iOS `WorkbenchSelection`). */
enum class WorkbenchSelection {
    OVERVIEW,      // Task Center
    NEW_TASK,      // new-task launchpad (workspaceID = null in G01)
    CONVERSATION,  // thread detail (G02)
}

/**
 * Anything selectable in the sidebar (iOS `SidebarSelection`). The visible
 * G01 sidebar exposes the fixed five rows; workspace/conversation payloads
 * arrive with the task runtime.
 */
sealed interface SidebarSelection {
    data class Workbench(val selection: WorkbenchSelection) : SidebarSelection
    data class More(val destination: MoreDestination) : SidebarSelection
    data class Workspace(val workspaceId: String) : SidebarSelection
    data class Conversation(val conversationId: String) : SidebarSelection
}

/** More destinations promoted to the sidebar (iOS `MoreDestination` order). */
enum class MoreDestination(val order: Int) {
    NOTES(0),
    CREATIVE(1),
    RUNS(2),
    SETUP_GUIDE(3),
    PROVIDERS(4),
    AUXILIARY_MODELS(5),
    SKILLS(6),
    MEMORY(7),
    SETTINGS(8),
    DIAGNOSTICS(9),
    NETWORK(10),
}

/** On-demand inspector contents (iOS `AppRouter.InspectorRoute.content`). */
enum class InspectorContent {
    PROGRESS,
    WORKSPACE_FILES,
    CHANGES,
    BROWSER,
    TERMINAL,
    CHILD_AGENTS,
    PERMISSIONS,
}

/** Inspector identity: content + owning conversation (id-per-recreation). */
data class InspectorRoute(val content: InspectorContent, val conversationId: String?)

/** Settings sheet sections. Order follows iOS `SettingsSection.visibleCases`,
 * pruned to what the Android foundation actually owns; no local-LLM or
 * Apple-platform rows are mirrored onto Android. G02 appends the settings
 * destinations the App host binds (integrations, memory & personalization,
 * usage, privacy, web search) — additive only, the G01 order is preserved. */
enum class FloeSettingsSection {
    GENERAL,
    PROVIDERS,   // cloud model configuration state (G02 wires persistence)
    SKILLS,      // Skills & connectors (G02 integrations destination)
    MEMORY,      // Memories, personalization, candidates & organize
    USAGE,       // token/run usage aggregates
    PRIVACY,     // summary, typed clears with trusted confirmation
    WEB_SEARCH,  // web-search provider metadata + secure credential editor
    DIAGNOSTICS, // real JNI handshake + debug-only component preview
}

/**
 * The sidebar's fixed five routes, locked to the iPad order:
 * New Task, Task Center, Notes, Creative, Plugins.
 */
val fixedSidebarRoutes: List<SidebarSelection> = listOf(
    SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK),
    SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW),
    SidebarSelection.More(MoreDestination.NOTES),
    SidebarSelection.More(MoreDestination.CREATIVE),
    SidebarSelection.More(MoreDestination.SKILLS),
)
