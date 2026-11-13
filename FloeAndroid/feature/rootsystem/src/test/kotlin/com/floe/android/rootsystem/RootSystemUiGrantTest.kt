// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

import com.floe.android.rootsystem.policy.GrantRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RootSystemUiGrantTest {

    private val now = System.currentTimeMillis()

    private fun uiGrant(
        operations: Set<SystemOperation> = setOf(
            SystemOperation.UI_OBSERVE,
            SystemOperation.UI_ACT,
            SystemOperation.UI_SCREENSHOT,
            SystemOperation.UI_CANCEL,
        ),
        targets: Set<String> = setOf("com.example.target"),
        screen: Boolean = true,
        screenshot: Boolean = true,
        scopes: List<ScopeRoot> = emptyList(),
    ) = GrantRequest(
        grantId = "ui-grant",
        taskId = "task",
        runId = "run",
        epoch = 7L,
        expiresAtMillis = now + 60_000,
        scopes = scopes,
        operations = operations,
        packageManagementAllowed = false,
        uiTargets = targets,
        uiScreenAllowed = screen,
        uiScreenshotAllowed = screenshot,
    )

    @Test fun uiOnlyGrantNeedsNoFilesystemScopeAndNoManagementCeiling() {
        val request = uiGrant()
        assertTrue(request.isWellFormed())
    }

    @Test fun uiGrantRequiresSelectedTargetsAndTheScreenCeiling() {
        assertFalse(uiGrant(targets = emptySet()).isWellFormed())
        assertFalse(uiGrant(screen = false).isWellFormed())
        assertFalse(uiGrant(screenshot = false).isWellFormed())
    }

    @Test fun emptyScopesCannotCarryFilesystemOperations() {
        val request = uiGrant(operations = setOf(SystemOperation.FILE_READ)).copy(
            uiTargets = emptySet(),
            uiScreenAllowed = false,
            uiScreenshotAllowed = false,
        )
        assertFalse(request.isWellFormed())
    }

    @Test fun registryAcceptsUiOnlyGrantAndReturnsOnlyUiTargets() {
        val registry = GrantRegistry(clock = { now })
        val request = uiGrant()
        val registration = registry.register(request)
        assertTrue(registration is GrantRegistry.Registration.Ok)
        val claim = OperationClaim(
            taskId = "task", runId = "run", epoch = 7L,
            grantId = "ui-grant", requestId = "r1",
        )
        assertEquals(setOf("com.example.target"), registry.uiTargets(claim))
        assertTrue(registry.uiScreenAllowed(claim))
        assertTrue(registry.uiScreenshotAllowed(claim))
        assertTrue(
            registry.check(claim, SystemOperation.UI_OBSERVE, null, write = false) is
                GrantRegistry.Verdict.Ok,
        )
    }

    @Test fun uiActionVocabularyIsClosed() {
        assertNotNull(UiAction.fromWire("click"))
        assertNotNull(UiAction.fromWire("setText"))
        assertNotNull(UiAction.fromWire("launch"))
        assertEquals(null, UiAction.fromWire("rawTap"))
        assertEquals(null, UiAction.fromWire("shell"))
    }
}
