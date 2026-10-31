// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GrantRegistryTest {

    private var now = 1_000_000L
    private val registry = GrantRegistry(clock = { now })

    private fun request(
        id: String = "grant-1",
        task: String = "task-1",
        run: String = "run-1",
        epoch: Long = 7,
        expiresIn: Long = 60_000,
        ops: Set<SystemOperation> = setOf(
            SystemOperation.FILE_READ,
            SystemOperation.FILE_WRITE,
            SystemOperation.FILE_LIST,
            SystemOperation.FILE_DELETE,
            SystemOperation.PROCESS_QUERY,
        ),
        management: Boolean = false,
    ) = GrantRequest(
        grantId = id,
        taskId = task,
        runId = run,
        epoch = epoch,
        expiresAtMillis = now + expiresIn,
        scopes = listOf(
            ScopeRoot("download", "/sdcard/Download/Floe", true),
            ScopeRoot("readonly", "/sdcard/Download/Floe-read", false),
        ),
        operations = ops,
        packageManagementAllowed = management,
    )

    private fun claim(
        id: String = "grant-1",
        task: String = "task-1",
        run: String = "run-1",
        epoch: Long = 7,
        requestId: String = "request-1",
    ) = OperationClaim(task, run, epoch, id, requestId)

    @Test
    fun registeredGrantAcceptsMatchingClaimAndOperation() {
        assertTrue(registry.register(request()) is GrantRegistry.Registration.Ok)
        assertEquals(GrantRegistry.Verdict.Ok, registry.check(claim(), SystemOperation.FILE_READ, "download", false))
        assertEquals(GrantRegistry.Verdict.Ok, registry.check(claim(), SystemOperation.FILE_WRITE, "download", true))
        assertEquals(
            "scope_read_only",
            (registry.check(claim(), SystemOperation.FILE_WRITE, "readonly", true) as GrantRegistry.Verdict.Rejected).code,
        )
        assertEquals(
            "operation",
            (registry.check(claim(), SystemOperation.NETWORK_DIAGNOSTICS, null, false) as GrantRegistry.Verdict.Rejected).code,
        )
    }

    @Test
    fun wrongTaskRunEpochOrGrantIsRejected() {
        registry.register(request())
        assertEquals(
            "task",
            (registry.check(claim(task = "other"), SystemOperation.FILE_READ, "download", false) as GrantRegistry.Verdict.Rejected).code,
        )
        assertEquals(
            "run",
            (registry.check(claim(run = "other"), SystemOperation.FILE_READ, "download", false) as GrantRegistry.Verdict.Rejected).code,
        )
        assertEquals(
            "epoch",
            (registry.check(claim(epoch = 8), SystemOperation.FILE_READ, "download", false) as GrantRegistry.Verdict.Rejected).code,
        )
        assertEquals(
            "grant_unknown",
            (registry.check(claim(id = "other"), SystemOperation.FILE_READ, "download", false) as GrantRegistry.Verdict.Rejected).code,
        )
        assertEquals(
            "scope_unknown",
            (registry.check(claim(), SystemOperation.FILE_READ, "missing", false) as GrantRegistry.Verdict.Rejected).code,
        )
    }

    @Test
    fun expiryRevocationCancellationAndFencingAreEnforced() {
        registry.register(request())
        now += 60_000
        assertEquals(
            "expired",
            (registry.check(claim(), SystemOperation.FILE_READ, "download", false) as GrantRegistry.Verdict.Rejected).code,
        )

        now = 1_000_000L
        registry.register(request(id = "grant-2"))
        assertTrue(registry.revoke("grant-2"))
        assertEquals(
            "revoked",
            (registry.check(claim(id = "grant-2"), SystemOperation.FILE_READ, "download", false) as GrantRegistry.Verdict.Rejected).code,
        )

        registry.register(request(id = "grant-3"))
        registry.cancel("cancel-me")
        assertEquals(
            "cancelled",
            (registry.check(claim(id = "grant-3", requestId = "cancel-me"), SystemOperation.FILE_READ, "download", false) as GrantRegistry.Verdict.Rejected).code,
        )

        registry.register(request(id = "grant-4"))
        registry.fenceAll()
        assertTrue(registry.activeGrantCount() == 0)
        assertEquals(
            "grant_unknown",
            (registry.check(claim(id = "grant-4"), SystemOperation.FILE_READ, "download", false) as GrantRegistry.Verdict.Rejected).code,
        )
    }

    @Test
    fun invalidOrDuplicateGrantsAreRejectedWithoutSelfGrant() {
        assertEquals(
            "grant_lifetime",
            (registry.register(request(expiresIn = 7 * 60 * 60 * 1000L)) as GrantRegistry.Registration.Rejected).code,
        )
        assertEquals(
            "grant_expired",
            (registry.register(request(expiresIn = 0)) as GrantRegistry.Registration.Rejected).code,
        )
        assertEquals(
            "grant_shape",
            (registry.register(request(task = "")) as GrantRegistry.Registration.Rejected).code,
        )
        assertEquals(
            "grant_management_shape",
            (registry.register(request(ops = setOf(SystemOperation.FILE_READ), management = true)) as GrantRegistry.Registration.Rejected).code,
        )
        registry.register(request())
        assertEquals(
            "grant_duplicate",
            (registry.register(request()) as GrantRegistry.Registration.Rejected).code,
        )
        assertEquals(
            "grant_management_shape",
            (registry.register(request(id = "g2", management = true)) as GrantRegistry.Registration.Rejected).code,
        )
        assertEquals(
            "scope_duplicate",
            (registry.register(
                request(id = "g3").copy(
                    scopes = listOf(
                        ScopeRoot("dup", "/sdcard/A", true),
                        ScopeRoot("dup", "/sdcard/B", true),
                    ),
                ),
            ) as GrantRegistry.Registration.Rejected).code,
        )
    }

    @Test
    fun packageManagementNeedsExplicitGrantFlag() {
        registry.register(
            request(
                ops = setOf(SystemOperation.PACKAGE_FORCE_STOP),
                management = true,
            ),
        )
        assertEquals(
            GrantRegistry.Verdict.Ok,
            registry.check(claim(), SystemOperation.PACKAGE_FORCE_STOP, null, true),
        )
        registry.register(
            request(id = "g2", ops = setOf(SystemOperation.PACKAGE_FORCE_STOP), management = false),
        )
        assertEquals(
            "management",
            (registry.check(claim(id = "g2"), SystemOperation.PACKAGE_FORCE_STOP, null, true) as GrantRegistry.Verdict.Rejected).code,
        )
    }

    @Test
    fun explicitScopePolicyKeepsBroadAndFloePrivateGrantsOut() {
        val packages = setOf("com.floe.agent.full")
        fun validate(scope: ScopeRoot): String? =
            PathPolicy.validateScopeBase(scope.path, packages, scope.writable)

        assertEquals(
            "scope_forbidden",
            (registry.register(
                request(id = "g-broad").copy(scopes = listOf(ScopeRoot("broad", "/data", true))),
                ::validate,
            ) as GrantRegistry.Registration.Rejected).code,
        )
        assertEquals(
            "scope_read_only",
            (registry.register(
                request(id = "g-writable-system").copy(
                    scopes = listOf(ScopeRoot("system", "/system/app", true)),
                ),
                ::validate,
            ) as GrantRegistry.Registration.Rejected).code,
        )
        assertEquals(
            "scope_floe_private",
            (registry.register(
                request(id = "g-own").copy(
                    scopes = listOf(
                        ScopeRoot("own", "/data/user/0/com.floe.agent.full", true),
                    ),
                ),
                ::validate,
            ) as GrantRegistry.Registration.Rejected).code,
        )
        assertTrue(
            registry.register(
                request(id = "g-system-readable").copy(
                    scopes = listOf(ScopeRoot("system", "/system/app", false)),
                ),
                ::validate,
            ) is GrantRegistry.Registration.Ok,
        )
        assertTrue(
            registry.register(
                request(id = "g-other-app").copy(
                    scopes = listOf(ScopeRoot("other", "/data/user/0/com.other.app", true)),
                ),
                ::validate,
            ) is GrantRegistry.Registration.Ok,
        )
        assertTrue(
            registry.register(
                request(id = "g-shared").copy(
                    scopes = listOf(ScopeRoot("shared", "/sdcard/Download/Floe", true)),
                ),
                ::validate,
            ) is GrantRegistry.Registration.Ok,
        )
    }

    @Test
    fun hostPolicyRejectsTheSiblingRuntimeScopeButKeepsOtherAppsUseful() {
        val packages = FloePackageFamily.protectedPackages(setOf("com.floe.agent.full"))
        fun validate(scope: ScopeRoot): String? =
            PathPolicy.validateScopeBase(scope.path, packages, scope.writable)

        for (path in listOf(
            "/data/user/0/com.floe.agent.runtime.full",
            "/data/user_de/10/com.floe.agent.runtime.full.dev",
            "/data/data/com.floe.agent.runtime",
            "/storage/emulated/0/Android/data/com.floe.agent.runtime.full",
        )) {
            assertEquals(
                path,
                "scope_floe_private",
                (registry.register(
                    request(id = "g-runtime-$path").copy(
                        scopes = listOf(ScopeRoot("runtime", path, true)),
                    ),
                    ::validate,
                ) as GrantRegistry.Registration.Rejected).code,
            )
        }

        assertTrue(
            registry.register(
                request(id = "g-runtime-other-app").copy(
                    scopes = listOf(ScopeRoot("other", "/data/user/0/com.other.app", true)),
                ),
                ::validate,
            ) is GrantRegistry.Registration.Ok,
        )
        assertTrue(
            registry.register(
                request(id = "g-runtime-system").copy(
                    scopes = listOf(ScopeRoot("system", "/system/app", false)),
                ),
                ::validate,
            ) is GrantRegistry.Registration.Ok,
        )
    }
}
