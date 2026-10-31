// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FloePackageFamilyTest {

    private val appFull = setOf("com.floe.agent.full")
    private val runtimeFull = setOf("com.floe.agent.runtime.full")

    @Test
    fun shippedChannelsContainTheRealParentAndSiblingRuntimeIds() {
        assertEquals("com.floe.agent", FloePackageFamily.PARENT_PACKAGE)
        assertEquals(
            setOf(
                "com.floe.agent",
                "com.floe.agent.dev",
                "com.floe.agent.full",
                "com.floe.agent.full.dev",
                "com.floe.agent.runtime",
                "com.floe.agent.runtime.dev",
                "com.floe.agent.runtime.full",
                "com.floe.agent.runtime.full.dev",
            ),
            FloePackageFamily.SHIPPED_PACKAGES,
        )
    }

    @Test
    fun hostingPackageAloneWouldMissTheSiblingRuntime() {
        // The actual bug: the runtime is "com.floe.agent.runtime.full", not
        // "com.floe.agent.full.runtime".
        assertFalse("com.floe.agent.runtime.full".startsWith("com.floe.agent.full."))
        assertFalse("com.floe.agent.runtime.full.dev".startsWith("com.floe.agent.full."))

        // The resolver covers both siblings in both directions.
        assertTrue(FloePackageFamily.contains("com.floe.agent.runtime.full", appFull))
        assertTrue(FloePackageFamily.contains("com.floe.agent.runtime.full.dev", appFull))
        assertTrue(FloePackageFamily.contains("com.floe.agent.full", runtimeFull))
        assertTrue(FloePackageFamily.contains("com.floe.agent.full.dev", runtimeFull))
    }

    @Test
    fun resolverAlwaysKeepsTheStableParentAndTheSuppliedPackage() {
        val roots = FloePackageFamily.protectedPackages(appFull)
        assertTrue(FloePackageFamily.PARENT_PACKAGE in roots)
        assertTrue("com.floe.agent.full" in roots)

        for (own in listOf(
            appFull,
            runtimeFull,
            setOf("com.floe.agent"),
            setOf("com.floe.agent.dev"),
            emptySet(),
        )) {
            for (shipped in FloePackageFamily.SHIPPED_PACKAGES) {
                assertTrue("$own -> $shipped", FloePackageFamily.contains(shipped, own))
            }
        }
    }

    @Test
    fun malformedOwnPackagesNeverDisplaceTheStableParent() {
        assertEquals(
            setOf("com.floe.agent", "com.floe.agent.full"),
            FloePackageFamily.protectedPackages(
                setOf("", "not a package", "a", " com.floe.agent.full "),
            ),
        )
    }

    @Test
    fun unrelatedPackagesAreNotProtectedAndBoundariesAreSeparatorAware() {
        assertFalse(FloePackageFamily.contains("", appFull))
        assertFalse(FloePackageFamily.contains("com.floe.agentx", appFull))
        assertFalse(FloePackageFamily.contains("com.floe.agents", appFull))
        assertFalse(FloePackageFamily.contains("com.example.notes", appFull))
        assertTrue(FloePackageFamily.contains("com.floe.agent", appFull))
        assertTrue(FloePackageFamily.contains("com.floe.agent.runtime", appFull))
        assertFalse(FloePackageFamily.isWithinRoots("com.floe.agent.full", emptySet()))
    }
}
