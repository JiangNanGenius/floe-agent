// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.executiontarget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecutionTargetUiModelsTest {
    private fun snapshot(target: C02TargetUi? = null, local: List<C02LocalEnvironmentUi>) =
        C02TargetSnapshotUi(
            taskID = "task", target = target, migration = null,
            remoteExecutionAllowed = false, hasUsableLocalEnvironment = true,
            canCreateInitialTarget = target == null, localEnvironments = local, remoteHosts = emptyList(),
        )

    private fun target(environment: String) = C02TargetUi(
        taskID = "task", revision = 1, kind = "localLinux", environmentID = environment,
        projectID = "project", workspaceID = "workspace", rootEpoch = 7,
        provenance = "adoptedExistingEnvironment", remoteHostID = null, remoteOS = null,
        remoteArchitecture = null, remoteGeneration = null,
    )

    @Test
    fun currentSessionStaysVisibleAlongsideNewProjectGraphics() {
        val state = snapshot(target("session"), listOf(
            C02LocalEnvironmentUi("session", null, "session", "active", false),
            C02LocalEnvironmentUi("project", null, "project", "active", false),
        ))
        val choices = ExecutionLocationChoices.available(state)
        assertEquals(listOf("project", "session"), choices.map { it.environmentID })
        assertTrue(choices.last().isCurrent)
        assertFalse(choices.first().isCurrent)
        assertEquals("local:session", ExecutionLocationChoices.initialKey(state))
    }

    @Test
    fun missingPinDoesNotSelectAnotherEnvironment() {
        val state = snapshot(target("missing"), listOf(
            C02LocalEnvironmentUi("project", null, "project", "active", false),
        ))
        assertEquals("local:missing", ExecutionLocationChoices.initialKey(state))
        assertFalse(ExecutionLocationChoices.available(state).any { it.isCurrent })
    }

    @Test
    fun newTaskUsesSessionThenProjectWithoutHidingAmbiguousSessions() {
        val sessions = listOf(
            C02LocalEnvironmentUi("a", null, "session", "active", false),
            C02LocalEnvironmentUi("b", null, "session", "active", false),
        )
        assertEquals("", ExecutionLocationChoices.initialKey(snapshot(local = sessions)))
        val project = C02LocalEnvironmentUi("p", null, "project", "active", false)
        assertEquals("", ExecutionLocationChoices.initialKey(snapshot(local = sessions + project)))
        assertEquals("local:a", ExecutionLocationChoices.initialKey(snapshot(local = sessions.take(1) + project)))
        assertEquals("local:p", ExecutionLocationChoices.initialKey(snapshot(local = listOf(project))))
    }

    @Test
    fun stoppedRebuildOrUnknownLocationsCannotBecomeDestinations() {
        val state = snapshot(local = listOf(
            C02LocalEnvironmentUi("stopped", null, "project", "stopped", false),
            C02LocalEnvironmentUi("rebuild", null, "project", "active", true),
            C02LocalEnvironmentUi("other", null, "base", "active", false),
        ))
        assertTrue(ExecutionLocationChoices.available(state).isEmpty())
        assertEquals("", ExecutionLocationChoices.initialKey(state))
    }

    @Test
    fun liveWorkSummaryCountsEveryOwnedKind() {
        assertFalse(C02WorkUi(0, 0, 0, 0, 0, 0, 0, 0L).hasLiveWork)
        assertTrue(C02WorkUi(1, 0, 0, 0, 0, 0, 0, 0L).hasLiveWork)
        assertTrue(C02WorkUi(0, 0, 0, 0, 1, 0, 0, 0L).hasLiveWork)
        assertTrue(C02WorkUi(0, 0, 0, 0, 0, 1, 0, 0L).hasLiveWork)
    }

    @Test
    fun stateExposesThePinnedTargetAndActiveMigration() {
        val target = C02TargetUi(
            taskID = "task", revision = 2, kind = "localLinux",
            environmentID = "env", projectID = null, workspaceID = "workspace",
            rootEpoch = 7, provenance = "explicitUserSelection",
            remoteHostID = null, remoteOS = null,
            remoteArchitecture = null, remoteGeneration = null,
        )
        val migration = C02MigrationUi(
            id = "migration", taskID = "task", phase = "draining", revision = 2,
            cancellationRequested = false,
            affectedWork = C02WorkUi(0, 0, 0, 0, 0, 0, 0, 0L),
            source = target,
            destination = target.copy(revision = 3, environmentID = "env-b", provenance = "migrated"),
            failureCode = null, drainReceipt = null,
        )
        val state = ExecutionTargetUiState(
            loading = false, taskID = "task",
            snapshot = C02TargetSnapshotUi(
                taskID = "task", target = target, migration = migration,
                remoteExecutionAllowed = false, hasUsableLocalEnvironment = true,
                canCreateInitialTarget = false, localEnvironments = emptyList(),
                remoteHosts = emptyList(),
            ),
        )
        assertEquals(target, state.currentTarget)
        assertEquals("draining", state.activeMigration?.phase)
        assertEquals(3L, state.activeMigration?.destination?.revision)
    }
}
