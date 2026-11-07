// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

/** Form projection only. Native ownership, revision and permission checks
 * remain authoritative when a definition is saved or dispatched. */
internal object TaskScheduleEditorPolicy {
    fun initialApprovalMode(savedMode: String?, globalAgentMode: String?): String =
        savedMode ?: if (globalAgentMode == "approvalModel") "automatic" else "ask"

    fun modelLabel(model: TaskScheduleModelChoice): String =
        listOf(model.displayName, model.providerName).filter { it.isNotBlank() }
            .distinct().joinToString(" · ")

    /** Match the existing G073ScheduleEnvironmentOwnership suggestion gate.
     * An unavailable saved target is retained by the draft, never replaced
     * by one of these suggestions. The host re-reads authority before save. */
    fun eligibleEnvironments(
        environments: List<TaskScheduleEnvironmentChoice>,
        workspaceID: String?,
    ): List<TaskScheduleEnvironmentChoice> = if (workspaceID.isNullOrBlank()) emptyList() else
        environments.filter {
            it.id.isNotBlank() && it.kind == "project" &&
                it.ownerID?.equals(workspaceID, ignoreCase = true) == true &&
                it.state == "active" && !it.requiresRebuild && it.executionBackend == "linuxPRoot"
        }

    fun environmentAfterWorkspaceChange(
        previousWorkspaceID: String?, nextWorkspaceID: String?, environmentID: String?,
    ): String? = if (previousWorkspaceID?.equals(nextWorkspaceID, ignoreCase = true) == true ||
        previousWorkspaceID == null && nextWorkspaceID == null) environmentID else null

    fun environmentLabels(
        environments: List<TaskScheduleEnvironmentChoice>, fallback: String,
    ): Map<String, String> {
        val labels = environments.sortedBy { it.id }.map { row ->
            row.id to row.name.takeIf { it.isNotBlank() && !it.equals(row.id, ignoreCase = true) }
                .orEmpty().ifEmpty { fallback }
        }
        val counts = labels.groupingBy { it.second }.eachCount()
        val seen = mutableMapOf<String, Int>()
        return labels.associate { (id, label) ->
            val ordinal = (seen[label] ?: 0) + 1
            seen[label] = ordinal
            id to if (counts.getValue(label) > 1) label + " · " + ordinal else label
        }
    }
}
