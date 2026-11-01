// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

/**
 * The real Floe package family that Root file and package-management policy
 * must never expose or stop.
 *
 * The App and the embedded Linux runtime component are sibling applicationIds,
 * not a parent and a `<package>.runtime` child. The shipped combinations are
 * composed from the base applicationId plus the distribution and debug
 * suffixes declared by `app/build.gradle.kts` and `runtimeapp/build.gradle.kts`:
 *
 * | channel | App | runtime |
 * | --- | --- | --- |
 * | Play release | com.floe.agent | com.floe.agent.runtime |
 * | Play debug | com.floe.agent.dev | com.floe.agent.runtime.dev |
 * | Full release | com.floe.agent.full | com.floe.agent.runtime.full |
 * | Full debug | com.floe.agent.full.dev | com.floe.agent.runtime.full.dev |
 *
 * These are also the four channels listed by
 * `core/runtimeipc/.../RuntimePackages.kt`. Because the runtime package does
 * not start with the hosting App package, a prefix check against the App
 * package alone misses it; the stable [PARENT_PACKAGE] root covers both
 * siblings for every channel and build type.
 *
 * The package actually hosting the Root service is supplied by the verified
 * server identity / host configuration, never by a model argument. It is
 * unioned with the stable parent instead of replacing it.
 */
object FloePackageFamily {

    const val PARENT_PACKAGE = "com.floe.agent"

    /** Every App/runtime applicationId currently shipped by the project. */
    val SHIPPED_PACKAGES: Set<String> = linkedSetOf(
        PARENT_PACKAGE,
        "$PARENT_PACKAGE.dev",
        "$PARENT_PACKAGE.full",
        "$PARENT_PACKAGE.full.dev",
        "$PARENT_PACKAGE.runtime",
        "$PARENT_PACKAGE.runtime.dev",
        "$PARENT_PACKAGE.runtime.full",
        "$PARENT_PACKAGE.runtime.full.dev",
    )

    /**
     * Resolves the protected package roots for [ownPackages]. The stable parent
     * is always present; syntactically invalid entries are dropped so a
     * malformed host field can never displace the Floe boundary.
     */
    fun protectedPackages(ownPackages: Set<String>): Set<String> {
        val roots = LinkedHashSet<String>(ownPackages.size + 1)
        roots.add(PARENT_PACKAGE)
        for (raw in ownPackages) {
            val candidate = raw.trim()
            if (isPackageId(candidate)) roots.add(candidate)
        }
        return roots
    }

    /**
     * True when [packageName] is the stable Floe parent, one of its
     * descendants (including the sibling runtime package), or an explicitly
     * supplied own package/descendant.
     */
    fun contains(packageName: String, ownPackages: Set<String>): Boolean =
        isWithinRoots(packageName, protectedPackages(ownPackages))

    /** Prefix test over already-resolved protected roots, separator-aware. */
    fun isWithinRoots(packageName: String, protectedRoots: Set<String>): Boolean {
        if (packageName.isEmpty()) return false
        return protectedRoots.any { root ->
            root.isNotEmpty() && (packageName == root || packageName.startsWith("$root."))
        }
    }

    private fun isPackageId(value: String): Boolean =
        value.length in 3..255 && PACKAGE_ID.matches(value)

    private val PACKAGE_ID = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")
}
