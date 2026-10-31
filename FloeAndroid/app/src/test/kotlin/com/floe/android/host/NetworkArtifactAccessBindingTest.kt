// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.host.networkartifact.NetworkArtifactCaller
import com.floe.android.host.networkartifact.NetworkArtifactPrincipal
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkArtifactAccessBindingTest {
    private val task = "64b601d7-a611-45f0-8d68-18403247437e"
    private val otherTask = "79685129-40ac-4607-9568-470db3d7b55c"
    private val artifact = "53d6f67d-9a52-40d9-a818-590f99199662"
    private val caller = NetworkArtifactCaller(
        taskID = task,
        runID = "773dbdfe-0683-4542-94ce-8d51c81bd8cd",
        epoch = 7L,
        workspaceFingerprint = "a".repeat(64),
    )
    private val global = NetworkArtifactPrincipal(
        artifactID = artifact, ownerTaskId = null,
        ownerWorkspaceId = null, agentReadable = true,
    )

    @Test fun sharedResourceDoesNotDependOnAnOpenedUIHolder() {
        assertTrue(networkArtifactAccessFor { 7L }.canRead(global, caller))
    }

    @Test fun opaqueIdDoesNotGrantAccessWithoutExplicitExposure() {
        assertFalse(networkArtifactAccessFor { 7L }.canRead(
            global.copy(agentReadable = false), caller,
        ))
    }

    @Test fun taskOwnedResourceRejectsAnotherTask() {
        val access = networkArtifactAccessFor { 7L }
        val owned = global.copy(ownerTaskId = task)
        assertTrue(access.canRead(owned, caller))
        assertFalse(access.canRead(owned, caller.copy(taskID = otherTask)))
    }

    @Test fun projectRestrictionIsRequiredEvenWhenTaskOwnerMatches() {
        val owned = global.copy(ownerTaskId = task, ownerWorkspaceId = "a".repeat(64))
        val access = networkArtifactAccessFor { 7L }
        assertTrue(access.canRead(owned, caller))
        assertFalse(access.canRead(owned, caller.copy(workspaceFingerprint = null)))
        assertFalse(access.canRead(owned, caller.copy(workspaceFingerprint = "b".repeat(64))))
    }

    @Test fun retiredEpochAndAnUnboundRootRefusePreviouslySharedArtifact() {
        var epoch: Long? = 7L
        val access = networkArtifactAccessFor { epoch }
        assertTrue(access.canRead(global, caller))
        epoch = 8L
        assertFalse(access.canRead(global, caller))
        epoch = null
        assertFalse(access.canRead(global, caller))
    }

    @Test fun malformedPrincipalsAndResourceOwnershipAreNotAccepted() {
        val access = networkArtifactAccessFor { 7L }
        assertFalse(access.canRead(global, caller.copy(taskID = "1-1-1-1-1")))
        assertFalse(access.canRead(global, caller.copy(runID = "00000000-0000-0000-0000-000000000000")))
        assertFalse(access.canRead(global.copy(artifactID = "../report"), caller))
        assertFalse(access.canRead(global.copy(ownerTaskId = "broken"), caller))
        assertFalse(access.canRead(global.copy(ownerWorkspaceId = "not-a-fingerprint"), caller))
    }
}
