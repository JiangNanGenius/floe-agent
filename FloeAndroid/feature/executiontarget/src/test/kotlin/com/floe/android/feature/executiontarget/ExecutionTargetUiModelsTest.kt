// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.executiontarget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecutionTargetUiModelsTest {
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
