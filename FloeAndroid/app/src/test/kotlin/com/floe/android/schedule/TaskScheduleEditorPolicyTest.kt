// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import org.junit.Assert.*
import org.junit.Test

class TaskScheduleEditorPolicyTest {
    private val project = "11111111-1111-4111-8111-111111111ABC"
    private fun environment(id: String = "target") = TaskScheduleEnvironmentChoice(
        id, id, kind = "project", ownerID = project.lowercase(), executionBackend = "linuxPRoot",
    )

    @Test fun newDraftUsesConfiguredGlobalModeWithoutInventingFullAccess() {
        assertEquals("automatic", TaskScheduleEditorPolicy.initialApprovalMode(null, "approvalModel"))
        for (mode in listOf(null, "human", "unknown", "fullAccess"))
            assertEquals("ask", TaskScheduleEditorPolicy.initialApprovalMode(null, mode))
    }

    @Test fun editingAlwaysPreservesTheExplicitSavedPolicy() {
        for (saved in listOf("ask", "automatic", "fullAccess")) {
            assertEquals(saved, TaskScheduleEditorPolicy.initialApprovalMode(saved, "approvalModel"))
            assertEquals(saved, TaskScheduleEditorPolicy.initialApprovalMode(saved, "human"))
        }
    }

    @Test fun offersOnlyActiveOwnedProjectLinuxTargets() {
        val valid = environment()
        val rows = listOf(valid, valid.copy(id = "other", ownerID = "other-project"),
            valid.copy(id = "session", kind = "session"), valid.copy(id = "shared", kind = "shared"),
            valid.copy(id = "stopped", state = "stopped"), valid.copy(id = "rebuild", requiresRebuild = true),
            valid.copy(id = "native", executionBackend = "native"), valid.copy(id = "missing", executionBackend = null))
        assertEquals(listOf(valid), TaskScheduleEditorPolicy.eligibleEnvironments(rows, project))
        assertTrue(TaskScheduleEditorPolicy.eligibleEnvironments(rows, null).isEmpty())
    }

    @Test fun projectChangeClearsOnlyTheOldProjectsExplicitTarget() {
        assertEquals("target", TaskScheduleEditorPolicy.environmentAfterWorkspaceChange(project, project.lowercase(), "target"))
        assertNull(TaskScheduleEditorPolicy.environmentAfterWorkspaceChange(project, "other-project", "target"))
        assertNull(TaskScheduleEditorPolicy.environmentAfterWorkspaceChange(project, null, "target"))
    }

    @Test fun sameNamedModelsKeepTheirIdsAndExposeTheirProvider() {
        val first = TaskScheduleModelChoice("model-a", "provider-a", "same-name", "Plan")
        val second = TaskScheduleModelChoice("model-b", "provider-b", "same-name", "Metered")
        assertNotEquals(TaskScheduleEditorPolicy.modelLabel(first), TaskScheduleEditorPolicy.modelLabel(second))
        assertEquals("model-a", first.id)
        assertEquals("model-b", second.id)
    }

    @Test fun unnamedEnvironmentsHaveStableDistinctLabelsWithoutChangingIds() {
        val rows = listOf(environment("target-b"), environment("target-a"))
        val labels = TaskScheduleEditorPolicy.environmentLabels(rows, "Project Linux")
        assertEquals(setOf("target-a", "target-b"), labels.keys)
        assertEquals(2, labels.values.toSet().size)
        assertEquals(labels, TaskScheduleEditorPolicy.environmentLabels(rows.reversed(), "Project Linux"))
        assertTrue(labels.values.none { it.startsWith("target-") })
    }
}
