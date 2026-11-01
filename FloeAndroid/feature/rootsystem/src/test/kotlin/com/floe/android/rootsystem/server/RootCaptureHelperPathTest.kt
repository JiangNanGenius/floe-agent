// SPDX-License-Identifier: MPL-2.0
//
// Intended destination (Main): feature/rootsystem/src/test/kotlin/com/floe/android/rootsystem/server/RootCaptureHelperPathTest.kt
//
// Authored, NOT RUN by the C06 lifetime lane. This module's test source set is
// outside the lane's declared write scope, so the exact source is delivered
// here for Main to place and run with the focused rootsystem JVM tests.
package com.floe.android.rootsystem.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic policy regressions for the two remaining root-capture paths:
 * a shell-writable ancestor/symlink cannot hold the executable, and a package
 * update cannot mix the verified APK manifest with another code directory.
 */
class RootCaptureHelperPathTest {

    private fun directory(
        path: String,
        uid: Int = 0,
        gid: Int = 0,
        mode: Int = 0x1C0, // 0700
    ): RootCaptureHelper.PathFacts = RootCaptureHelper.PathFacts(
        path = path,
        directory = true,
        symlink = false,
        uid = uid,
        gid = gid,
        mode = mode,
    )

    @Test
    fun acceptsRootOwnedNonShellWritableAncestry() {
        val facts = listOf(
            directory("/", 0, 0, 0x1ED), // 0755
            directory("/data", 1000, 1000, 0x1F9), // 0771 system:system
            directory("/data/local", 0, 0, 0x1E9), // 0751 root:root
            directory("/data/local/floe-capture", 0, 0, 0x1C0), // 0700
        )
        assertNull(RootCaptureHelper.ancestryProblem(facts, requireRootOwnedLeaf = true))
    }

    @Test
    fun rejectsTheLegacyShellWritableTmpAncestor() {
        // /data/local/tmp is 0771 shell:shell on Android: a root-owned leaf
        // below it can be renamed by an ordinary adb/shell user.
        val facts = listOf(
            directory("/data", 1000, 1000, 0x1F9),
            directory("/data/local", 0, 0, 0x1E9),
            directory("/data/local/tmp", 2000, 2000, 0x1F9),
            directory("/data/local/tmp/floe/capture-helper", 0, 0, 0x1C0),
        )
        assertEquals(
            "helperShellWritable",
            RootCaptureHelper.ancestryProblem(facts, requireRootOwnedLeaf = true),
        )
    }

    @Test
    fun rejectsWorldWritableAncestor() {
        val facts = listOf(
            directory("/data/local", 0, 0, 0x1F9), // 0771 root:root
            directory("/data/local/floe-capture", 0, 0, 0x1C0),
        )
        // 0771 root:root is not shell group writable; world write is 0777.
        assertNull(RootCaptureHelper.ancestryProblem(facts, requireRootOwnedLeaf = true))
        val writable = listOf(
            directory("/data/local", 0, 0, 0x1FF), // 0777
            directory("/data/local/floe-capture", 0, 0, 0x1C0),
        )
        assertEquals(
            "helperWorldWritable",
            RootCaptureHelper.ancestryProblem(writable, requireRootOwnedLeaf = true),
        )
    }

    @Test
    fun rejectsSymlinkedOrUntrustedAncestor() {
        val symlink = listOf(
            directory("/data/local", 0, 0, 0x1E9),
            RootCaptureHelper.PathFacts(
                path = "/data/local/floe-capture",
                directory = true,
                symlink = true,
                uid = 0,
                gid = 0,
                mode = 0x1C0,
            ),
        )
        assertEquals(
            "helperSymlink",
            RootCaptureHelper.ancestryProblem(symlink, requireRootOwnedLeaf = true),
        )
        val foreign = listOf(
            directory("/data/local", 10_123, 10_123, 0x1E9),
            directory("/data/local/floe-capture", 0, 0, 0x1C0),
        )
        assertEquals(
            "helperOwner",
            RootCaptureHelper.ancestryProblem(foreign, requireRootOwnedLeaf = true),
        )
    }

    @Test
    fun rootOwnedLeafMustNotBeGroupWritable() {
        val facts = listOf(
            directory("/data/local", 0, 0, 0x1E9),
            directory("/data/local/floe-capture", 0, 0, 0x1F0), // 0760 root:root
        )
        assertEquals(
            "helperWritableByOthers",
            RootCaptureHelper.ancestryProblem(facts, requireRootOwnedLeaf = true),
        )
    }

    @Test
    fun helperExecutableMustLiveInsideTheVerifiedInstalledPackage() {
        val apk = "/data/app/~~a1b2==/com.floe.android.full-xYz/base.apk"
        assertTrue(
            RootCaptureHelper.nativeDirectoryInsidePackage(
                apk,
                "/data/app/~~a1b2==/com.floe.android.full-xYz/lib/arm64",
            ),
        )
        // Package update replaced the code directory: the old APK path and the
        // new package bytes must not be mixed.
        assertFalse(
            RootCaptureHelper.nativeDirectoryInsidePackage(
                apk,
                "/data/app/~~c3d4==/com.floe.android.full-AbC/lib/arm64",
            ),
        )
        // Sibling prefix confusion.
        assertFalse(
            RootCaptureHelper.nativeDirectoryInsidePackage(
                apk,
                "/data/app/~~a1b2==/com.floe.android.full-xYz-evil/lib/arm64",
            ),
        )
        // Package-manager-managed adoptable storage is still bound to its own
        // code directory.
        assertTrue(
            RootCaptureHelper.nativeDirectoryInsidePackage(
                "/mnt/expand/1234/app/com.floe.android.full-xYz/base.apk",
                "/mnt/expand/1234/app/com.floe.android.full-xYz/lib/arm64",
            ),
        )
        assertFalse(
            RootCaptureHelper.nativeDirectoryInsidePackage(
                "/mnt/expand/1234/app/com.floe.android.full-xYz/base.apk",
                "/mnt/expand/1234/app/com.floe.android.full-AbC/lib/arm64",
            ),
        )
        // No arbitrary file tree is accepted as a package-manager directory.
        assertFalse(
            RootCaptureHelper.nativeDirectoryInsidePackage(
                "/data/local/tmp/base.apk",
                "/data/local/tmp/lib/arm64",
            ),
        )
    }

    @Test
    fun manifestMustBindTheExactHelperIdentityAndDigestShape() {
        assertNull(
            RootCaptureHelper.manifestProblem(
                id = RootCaptureHelper.HELPER_ID,
                version = "1",
                abi = "arm64-v8a",
                minSdk = 28,
                pageSize = 16_384,
                packagedName = RootCaptureHelper.PACKAGED_NAME,
                sha256 = "a".repeat(64),
                sizeBytes = 1L,
            ),
        )
        // A different helper id/name/ABI is never substituted.
        assertNotNull(
            RootCaptureHelper.manifestProblem(
                RootCaptureHelper.HELPER_ID, "1", "arm64-v8a", 28, 16_384,
                "libother.so", "a".repeat(64), 1L,
            ),
        )
        assertNotNull(
            RootCaptureHelper.manifestProblem(
                RootCaptureHelper.HELPER_ID, "1", "x86_64", 28, 16_384,
                RootCaptureHelper.PACKAGED_NAME, "a".repeat(64), 1L,
            ),
        )
        // Malformed/truncated digest and an impossible size fail closed.
        assertNotNull(
            RootCaptureHelper.manifestProblem(
                RootCaptureHelper.HELPER_ID, "1", "arm64-v8a", 28, 16_384,
                RootCaptureHelper.PACKAGED_NAME, "a".repeat(63), 1L,
            ),
        )
        assertNotNull(
            RootCaptureHelper.manifestProblem(
                RootCaptureHelper.HELPER_ID, "1", "arm64-v8a", 28, 16_384,
                RootCaptureHelper.PACKAGED_NAME, "a".repeat(64), 0L,
            ),
        )
        assertNotNull(
            RootCaptureHelper.manifestProblem(
                RootCaptureHelper.HELPER_ID, "1", "arm64-v8a", 1, 16_384,
                RootCaptureHelper.PACKAGED_NAME, "a".repeat(64), 1L,
            ),
        )
    }
}
