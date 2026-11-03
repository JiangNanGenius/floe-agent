// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Device-observed regression (Samsung candidate04 code27, alpha24): an
 * explicitly project-owned new task lost its ownership because the Home
 * missing-selection effect dropped the picker selection whenever the
 * settled project list did not contain the chosen id — including when the
 * list command had FAILED, where an empty/stale projection must never
 * demote the explicit choice. These tests pin the pure retention policy:
 * the selection clears ONLY after a genuinely successful durable list that
 * omits the project (the existing stale-id protection); a failed or
 * in-flight list retains it, and the native pre-first-run `project.assign`
 * remains the fail-closed authority for a stale id.
 *
 * Authored NOTRUN — Main runs the focused JVM filter.
 */
class ProjectSelectionRetentionHostTest {

    private val projectId = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"

    private fun row(id: String = projectId): ProjectRowUi = ProjectRowUi(
        id = id,
        name = "AndroidFinalQA",
        revision = "2026-11-03T00:00:00.000Z",
        createdAt = "2026-11-03T00:00:00.000Z",
        updatedAt = "2026-11-03T00:00:00.000Z",
        taskCount = 0,
    )

    private fun state(
        loading: Boolean = false,
        errorCode: String? = null,
        projects: List<ProjectRowUi> = emptyList(),
    ) = ProjectUiState(loading = loading, projects = projects, errorCode = errorCode)

    @Test
    fun successfulListContainingTheProjectKeepsTheExplicitSelection() {
        val value = HomeLaunchpadHost.shouldClearMissingProjectSelection(
            state(projects = listOf(row())),
            selectedProjectId = projectId,
        )
        assertFalse(value)
    }

    @Test
    fun successfulListThatOmitsTheProjectClearsTheSelection() {
        // Stale-id protection is preserved: a genuinely loaded durable list
        // without the chosen project must drop it.
        val empty = HomeLaunchpadHost.shouldClearMissingProjectSelection(
            state(projects = emptyList()),
            selectedProjectId = projectId,
        )
        assertTrue(empty)
        val othersOnly = HomeLaunchpadHost.shouldClearMissingProjectSelection(
            state(projects = listOf(row("FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"))),
            selectedProjectId = projectId,
        )
        assertTrue(othersOnly)
    }

    @Test
    fun failedListRetainsTheExplicitSelection() {
        // The device regression: the list command failed (typed errorCode)
        // and the effect used to clear the explicit choice anyway.
        for (code in listOf("runtime_unavailable", "timeout", "malformed")) {
            val value = HomeLaunchpadHost.shouldClearMissingProjectSelection(
                state(errorCode = code),
                selectedProjectId = projectId,
            )
            assertFalse("errorCode=$code must retain the selection", value)
        }
    }

    @Test
    fun inFlightListRetainsTheExplicitSelection() {
        val value = HomeLaunchpadHost.shouldClearMissingProjectSelection(
            state(loading = true),
            selectedProjectId = projectId,
        )
        assertFalse(value)
    }

    @Test
    fun noHostStateOrNoSelectionNeverClears() {
        assertFalse(
            HomeLaunchpadHost.shouldClearMissingProjectSelection(null, projectId),
        )
        assertFalse(
            HomeLaunchpadHost.shouldClearMissingProjectSelection(state(), null),
        )
        assertFalse(
            HomeLaunchpadHost.shouldClearMissingProjectSelection(state(), "  "),
        )
    }
}
