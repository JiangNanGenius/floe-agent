// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject
import org.json.JSONArray
import com.floe.android.rootsystem.policy.ProtectedTargets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regression for the closed batch argument shapes of the install and
 * uninstall tools: opaque staged ids / package names only, bounded batches,
 * order-preserving dedupe and a default user. A malformed batch fails whole
 * before any device effect.
 *
 * Authored only; Main runs it in the batched JVM set. No compile/run claim.
 */
class PackageBatchArgumentsTest {

    private fun JSONObject.putStrings(name: String, values: List<String>): JSONObject =
        put(name, JSONArray(values))

    @Test
    fun installParsesStagedIdsAndDefaultsUser() {
        val request = PackageBatchArguments.install(
            JSONObject().putStrings("stagedIds", listOf("stage:abcdef0123456789", "stage:fedcba9876543210")),
        )
        assertEquals(
            PackageBatchArguments.Request.Install(
                listOf("stage:abcdef0123456789", "stage:fedcba9876543210"),
                0,
            ),
            request,
        )
        val withUser = PackageBatchArguments.install(
            JSONObject()
                .putStrings("stagedIds", listOf("stage:abcdef0123456789"))
                .put("userId", 10),
        )
        assertEquals(
            PackageBatchArguments.Request.Install(listOf("stage:abcdef0123456789"), 10),
            withUser,
        )
    }

    @Test
    fun uninstallParsesPackageNamesAndRejectsBadShapes() {
        assertEquals(
            PackageBatchArguments.Request.Uninstall(listOf("com.example.one", "com.example.two"), 0),
            PackageBatchArguments.uninstall(
                JSONObject().putStrings("packages", listOf("com.example.one", "com.example.two")),
            ),
        )
        for (raw in listOf(
            JSONObject().putStrings("packages", listOf("com.example.one", "not a package")),
            JSONObject().putStrings("packages", emptyList<String>()),
            JSONObject().putStrings("packages", List(9) { "com.example.app$it" }),
            JSONObject(),
        )) {
            assertTrue(
                raw.toString(),
                PackageBatchArguments.uninstall(raw)
                    is PackageBatchArguments.Request.Invalid,
            )
        }
        // Shape parsing never grants authority. A valid protected identity
        // reaches the per-item service policy, so other batch items can run.
        val own = "com.floe.agent.full"
        assertEquals(
            PackageBatchArguments.Request.Uninstall(listOf(own), 0),
            PackageBatchArguments.uninstall(JSONObject().putStrings("packages", listOf(own))),
        )
        assertEquals("protected_target", ProtectedTargets.canManagePackage(
            packageName = own, userId = 0, ownPackages = setOf(own),
            allowed = true, operation = "uninstall",
        ))
    }

    @Test
    fun installRejectsNonStagedIdsAndDuplicatesCollapseInOrder() {
        assertTrue(
            PackageBatchArguments.install(
                JSONObject().putStrings("stagedIds", listOf("/sdcard/evil.apk")),
            ) is PackageBatchArguments.Request.Invalid,
        )
        assertTrue(
            PackageBatchArguments.install(
                JSONObject().putStrings("stagedIds", listOf("stage:bad id!")),
            ) is PackageBatchArguments.Request.Invalid,
        )
        assertEquals(
            PackageBatchArguments.Request.Install(listOf("stage:aaaa1111", "stage:bbbb2222"), 0),
            PackageBatchArguments.install(
                JSONObject().putStrings(
                    "stagedIds",
                    listOf("stage:aaaa1111", "stage:bbbb2222", "stage:aaaa1111"),
                ),
            ),
        )
    }

    @Test
    fun userIdMustBeNumericAndInRange() {
        for (userId in listOf(-1, 1000, "zero")) {
            val raw = JSONObject()
                .putStrings("stagedIds", listOf("stage:abcdef0123456789"))
                .put("userId", userId)
            assertTrue(
                userId.toString(),
                PackageBatchArguments.install(raw) is PackageBatchArguments.Request.Invalid,
            )
        }
    }

    @Test
    fun setEnabledParsesPackagesStateAndDefaultsUser() {
        assertEquals(
            PackageBatchArguments.Request.SetEnabled(
                listOf("com.example.one", "com.example.two"), 0, "disable-user"),
            PackageBatchArguments.setEnabled(
                JSONObject()
                    .putStrings("packages", listOf("com.example.one", "com.example.two"))
                    .put("state", "disable-user"),
            ),
        )
        for (raw in listOf(
            JSONObject().putStrings("packages", listOf("com.example.one")).put("state", "hide"),
            JSONObject().putStrings("packages", listOf("com.example.one")).put("state", ""),
            JSONObject().putStrings("packages", emptyList<String>()).put("state", "enable"),
            JSONObject().putStrings("packages", List(9) { "com.example.app$it" })
                .put("state", "enable"),
            JSONObject().putStrings("packages", listOf("com.example.one")),
            JSONObject(),
        )) {
            assertTrue(
                raw.toString(),
                PackageBatchArguments.setEnabled(raw)
                    is PackageBatchArguments.Request.Invalid,
            )
        }
    }

    @Test
    fun removeForUserAndRestoreParseLikeUninstall() {
        assertEquals(
            PackageBatchArguments.Request.RemoveForUser(listOf("com.example.sys"), 0),
            PackageBatchArguments.removeForUser(
                JSONObject().putStrings("packages", listOf("com.example.sys"))),
        )
        assertEquals(
            PackageBatchArguments.Request.Restore(listOf("com.example.sys"), 12),
            PackageBatchArguments.restore(
                JSONObject()
                    .putStrings("packages", listOf("com.example.sys"))
                    .put("userId", 12),
            ),
        )
        for (raw in listOf(
            JSONObject().putStrings("packages", listOf("not a package")),
            JSONObject().putStrings("packages", emptyList<String>()),
            JSONObject(),
        )) {
            assertTrue(
                raw.toString(),
                PackageBatchArguments.removeForUser(raw)
                    is PackageBatchArguments.Request.Invalid,
            )
            assertTrue(
                raw.toString(),
                PackageBatchArguments.restore(raw) is PackageBatchArguments.Request.Invalid,
            )
        }
        val own = "com.floe.agent.full"
        val raw = JSONObject().putStrings("packages", listOf(own))
        assertEquals(PackageBatchArguments.Request.RemoveForUser(listOf(own), 0),
            PackageBatchArguments.removeForUser(raw))
        assertEquals(PackageBatchArguments.Request.Restore(listOf(own), 0),
            PackageBatchArguments.restore(raw))
        for (operation in listOf("remove_for_user", "restore")) {
            assertEquals("protected_target", ProtectedTargets.canChangeAppState(
                packageName = own, userId = 0, ownPackages = setOf(own),
                allowed = true, operation = operation, systemPackage = true,
                currentRolePackages = emptySet(),
            ))
        }
    }
}
