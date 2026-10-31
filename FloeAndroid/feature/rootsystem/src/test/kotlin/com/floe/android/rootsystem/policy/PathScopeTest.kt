// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PathScopeTest {

    @Test
    fun relativePathsAreNormalizedAndTraversalRejected() {
        assertEquals("a/b", (PathPolicy.normalizeRelative("./a/b") as PathPolicy.RelativeResult.Ok).relative)
        assertEquals("", (PathPolicy.normalizeRelative("") as PathPolicy.RelativeResult.Ok).relative)
        assertEquals("a", (PathPolicy.normalizeRelative("a/") as PathPolicy.RelativeResult.Ok).relative)
        assertEquals("traversal", (PathPolicy.normalizeRelative("../a") as PathPolicy.RelativeResult.Rejected).code)
        assertEquals("traversal", (PathPolicy.normalizeRelative("a/../../b") as PathPolicy.RelativeResult.Rejected).code)
        assertEquals("absolute", (PathPolicy.normalizeRelative("/a") as PathPolicy.RelativeResult.Rejected).code)
        assertEquals("separator", (PathPolicy.normalizeRelative("a\\b") as PathPolicy.RelativeResult.Rejected).code)
        assertEquals("depth", (PathPolicy.normalizeRelative((1..33).joinToString("/")) as PathPolicy.RelativeResult.Rejected).code)
        assertEquals("segment", (PathPolicy.normalizeRelative("a".repeat(256)) as PathPolicy.RelativeResult.Rejected).code)
        assertEquals("path_chars", (PathPolicy.normalizeRelative("a\u0000b") as PathPolicy.RelativeResult.Rejected).code)
    }

    @Test
    fun containmentIsLexicalAndSeparatorAware() {
        assertTrue(PathPolicy.isWithin("/sdcard/Floe", "/sdcard/Floe"))
        assertTrue(PathPolicy.isWithin("/sdcard/Floe", "/sdcard/Floe/a/b"))
        assertFalse(PathPolicy.isWithin("/sdcard/Floe", "/sdcard/FloeX/a"))
        assertFalse(PathPolicy.isWithin("/sdcard/Floe", "/sdcard/Other"))
        assertTrue(PathPolicy.isWithin("/", "/sdcard/Floe"))
    }

    @Test
    fun explicitBoundedScopesAreAllowed() {
        val packages = setOf("com.floe.agent.full")

        // Shared storage roots and subdirectories.
        assertNull(PathPolicy.validateScopeBase("/sdcard", packages))
        assertNull(PathPolicy.validateScopeBase("/sdcard/Download/Floe", packages))
        assertNull(PathPolicy.validateScopeBase("/storage/emulated/0", packages))
        assertNull(PathPolicy.validateScopeBase("/storage/emulated/10/Download", packages))
        assertNull(PathPolicy.validateScopeBase("/storage/self/primary/Download", packages))
        assertNull(PathPolicy.validateScopeBase("/mnt/user/0/primary/Download", packages))
        assertNull(PathPolicy.validateScopeBase("/data/media/0/Download", packages))
        assertNull(PathPolicy.validateScopeBase("/storage/ABCD-1234/Download", packages))

        // Specific other-app data directories, including adopted volumes.
        assertNull(PathPolicy.validateScopeBase("/data/data/com.other.app", packages))
        assertNull(PathPolicy.validateScopeBase("/data/data/com.other.app/files", packages))
        assertNull(PathPolicy.validateScopeBase("/data/user/0/com.other.app", packages))
        assertNull(PathPolicy.validateScopeBase("/data/user/10/com.other.app/files", packages))
        assertNull(PathPolicy.validateScopeBase("/data/user_de/0/com.other.app", packages))
        assertNull(
            PathPolicy.validateScopeBase(
                "/mnt/expand/1234-ABCD/user/0/com.other.app/files",
                packages,
            ),
        )
        assertNull(
            PathPolicy.validateScopeBase(
                "/mnt/expand/1234-ABCD/user_de/10/com.other.app",
                packages,
            ),
        )
        assertNull(PathPolicy.validateScopeBase("/data/local/tmp/floe-system", packages))

        // Platform inspection trees are allowed read-only.
        assertNull(PathPolicy.validateScopeBase("/system", packages))
        assertNull(PathPolicy.validateScopeBase("/system/app", packages))
        assertNull(PathPolicy.validateScopeBase("/vendor/lib64", packages))
        assertNull(PathPolicy.validateScopeBase("/product/etc", packages))
        assertNull(PathPolicy.validateScopeBase("/system_ext", packages))
        assertNull(PathPolicy.validateScopeBase("/odm", packages))
        assertNull(PathPolicy.validateScopeBase("/apex/com.android.runtime", packages))
    }

    @Test
    fun writablePlatformScopeIsRejected() {
        val packages = setOf("com.floe.agent.full")
        for (path in listOf(
            "/system",
            "/system/app",
            "/vendor",
            "/vendor/lib64",
            "/product",
            "/system_ext",
            "/odm",
            "/apex/com.android.runtime",
        )) {
            assertEquals(
                "scope_read_only",
                PathPolicy.validateScopeBase(path, packages, writable = true),
            )
        }
    }

    @Test
    fun broadKernelAndFloePrivateScopesAreRejected() {
        val packages = setOf("com.floe.agent.full")
        assertEquals("scope_root", PathPolicy.validateScopeBase("/", packages))
        assertEquals("scope_relative", PathPolicy.validateScopeBase("sdcard/Download", packages))
        assertEquals("scope_syntax", PathPolicy.validateScopeBase("/data/../system", packages))

        // Ancestor scopes that would grant every app/user/volume at once.
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/data", packages))
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/data/data", packages))
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/data/user", packages))
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/data/user/0", packages))
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/data/user_de/0", packages))
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/storage", packages))
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/storage/emulated", packages))
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/storage/self", packages))
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/mnt/expand", packages))
        assertEquals(
            "scope_forbidden",
            PathPolicy.validateScopeBase("/mnt/expand/1234-ABCD", packages),
        )
        assertEquals("scope_forbidden", PathPolicy.validateScopeBase("/mnt/expand/1234-ABCD/user", packages))
        assertEquals(
            "scope_forbidden",
            PathPolicy.validateScopeBase("/mnt/expand/1234-ABCD/user/0", packages),
        )

        // Kernel, device, boot and credential trees remain hard-denied.
        for (path in listOf(
            "/proc/1",
            "/sys/kernel",
            "/dev/block",
            "/root",
            "/init",
            "/sbin",
            "/metadata",
            "/efs",
            "/persist",
            "/mnt/media_rw/ABCD",
            "/data/system",
            "/data/misc/keystore",
            "/data/adb",
            "/data/apex",
            "/data/app",
            "/data/vendor",
            "/data/security",
        )) {
            assertEquals("scope_forbidden", PathPolicy.validateScopeBase(path, packages))
        }

        // Floe-private directories are protected for every user and alias.
        for (path in listOf(
            "/data/data/com.floe.agent.full",
            "/data/data/com.floe.agent.full/files",
            "/data/user/0/com.floe.agent.full",
            "/data/user/10/com.floe.agent.full",
            "/data/user_de/0/com.floe.agent.full",
            "/data/user_de/10/com.floe.agent.full/files",
            "/mnt/expand/1234-ABCD/user/0/com.floe.agent.full",
            "/mnt/expand/1234-ABCD/user_de/10/com.floe.agent.full/files",
            "/storage/emulated/0/Android/data/com.floe.agent.full",
            "/sdcard/Android/media/com.floe.agent.full",
            "/data/data/com.floe.agent.full.dev",
        )) {
            assertEquals("scope_floe_private", PathPolicy.validateScopeBase(path, packages))
        }
    }

    @Test
    fun floePrivateAliasesAndAncestorMutationAreProtected() {
        val own = setOf("com.floe.agent.full")

        for (path in listOf(
            "/data/data/com.floe.agent.full/files",
            "/data/user/0/com.floe.agent.full/db",
            "/data/user/10/com.floe.agent.full/cache",
            "/data/user_de/0/com.floe.agent.full/files",
            "/data/user_de/10/com.floe.agent.full/db",
            "/mnt/expand/1234-ABCD/user/0/com.floe.agent.full/files",
            "/mnt/expand/1234-ABCD/user_de/10/com.floe.agent.full/db",
            "/storage/emulated/0/Android/data/com.floe.agent.full/files",
            "/sdcard/Android/media/com.floe.agent.full/note.txt",
            "/storage/ABCD-1234/Android/data/com.floe.agent.full/files",
        )) {
            assertTrue(path, ProtectedTargets.isProtectedPath(path, own))
        }
        assertFalse(
            ProtectedTargets.isProtectedPath("/data/data/com.other.app/files", own),
        )
        assertFalse(
            ProtectedTargets.isProtectedPath("/storage/emulated/0/Android/data/com.other.app", own),
        )
        assertFalse(ProtectedTargets.isProtectedPath("/sdcard/Download/Floe/file.txt", own))
        assertFalse(ProtectedTargets.isProtectedPath("/data/local/tmp/floe-system/x", own))

        // Destructive ancestor targets must be refused before any deletion.
        for (path in listOf(
            "/storage/emulated/0",
            "/storage/emulated/0/Android",
            "/storage/emulated/0/Android/data",
            "/sdcard",
            "/sdcard/Android",
            "/data/data",
            "/data/user/0",
            "/data/user_de/10",
            "/mnt/expand/1234-ABCD",
            "/mnt/expand/1234-ABCD/user/0",
            "/storage/ABCD-1234",
        )) {
            assertTrue(path, ProtectedTargets.containsProtectedSubtree(path, own))
        }
        assertFalse(
            ProtectedTargets.containsProtectedSubtree("/storage/emulated/0/Download", own),
        )
        assertFalse(
            ProtectedTargets.containsProtectedSubtree("/data/user/0/com.other.app", own),
        )
        assertFalse(ProtectedTargets.containsProtectedSubtree("/data/local/tmp", own))

        assertTrue(ProtectedTargets.isReadOnlySystemPath("/system/app"))
        assertTrue(ProtectedTargets.isReadOnlySystemPath("/vendor/lib64"))
        assertFalse(ProtectedTargets.isReadOnlySystemPath("/sdcard/Download"))
        assertFalse(ProtectedTargets.isReadOnlySystemPath("/systemx"))
    }

    @Test
    fun siblingRuntimeAndPlayDebugAliasesStayPrivateForEveryHostPackage() {
        // The service may be hosted by the Full App or by the sibling runtime
        // component; the whole Floe family must stay out of both ceilings.
        val appHost = FloePackageFamily.protectedPackages(setOf("com.floe.agent.full"))
        val runtimeHost = FloePackageFamily.protectedPackages(setOf("com.floe.agent.runtime.full"))

        // Even a raw host package passed straight to the low-level policy is
        // expanded, so a future caller cannot regress the sibling protection.
        assertTrue(
            PathPolicy.isFloePrivatePath(
                "/data/data/com.floe.agent.runtime.full",
                setOf("com.floe.agent.full"),
            ),
        )
        assertEquals(
            "scope_floe_private",
            PathPolicy.validateScopeBase(
                "/data/user/0/com.floe.agent.runtime.full.dev",
                setOf("com.floe.agent.full"),
            ),
        )

        for (path in listOf(
            "/data/data/com.floe.agent",
            "/data/data/com.floe.agent.dev/files",
            "/data/data/com.floe.agent.full",
            "/data/data/com.floe.agent.full.dev/db",
            "/data/data/com.floe.agent.runtime",
            "/data/data/com.floe.agent.runtime.dev/files",
            "/data/data/com.floe.agent.runtime.full",
            "/data/data/com.floe.agent.runtime.full.dev/db",
            "/data/user/0/com.floe.agent.full.dev",
            "/data/user/10/com.floe.agent.runtime.full.dev/db",
            "/data/user_de/0/com.floe.agent.dev",
            "/data/user_de/10/com.floe.agent.runtime.dev/files",
            "/mnt/expand/1234-ABCD/user/0/com.floe.agent.runtime.full",
            "/mnt/expand/1234-ABCD/user_de/10/com.floe.agent.full.dev/files",
            "/mnt/expand/1234-ABCD/app/com.floe.agent.runtime",
            "/storage/emulated/0/Android/data/com.floe.agent.runtime.full.dev/files",
            "/sdcard/Android/media/com.floe.agent.full/files",
            "/storage/ABCD-1234/Android/obb/com.floe.agent.runtime.dev",
        )) {
            assertEquals(path, "scope_floe_private", PathPolicy.validateScopeBase(path, appHost))
            assertEquals(path, "scope_floe_private", PathPolicy.validateScopeBase(path, runtimeHost))
            assertTrue(path, ProtectedTargets.isProtectedPath(path, setOf("com.floe.agent.full")))
            assertTrue(
                path,
                ProtectedTargets.isProtectedPath(path, setOf("com.floe.agent.runtime.full")),
            )
        }

        // Explicitly granted OTHER app data remains useful for both hosts.
        for (path in listOf(
            "/data/data/com.other.app",
            "/data/user/10/com.other.app/files",
            "/data/user_de/0/com.other.app",
            "/mnt/expand/1234-ABCD/app/com.other.app",
            "/storage/emulated/0/Android/data/com.other.app/files",
        )) {
            assertNull(path, PathPolicy.validateScopeBase(path, appHost))
            assertNull(path, PathPolicy.validateScopeBase(path, runtimeHost))
            assertFalse(path, ProtectedTargets.isProtectedPath(path, setOf("com.floe.agent.full")))
        }

        // A shared-storage or user-parent grant must never enable a recursive
        // delete that reaches a Floe sibling subtree.
        for (path in listOf(
            "/storage/emulated/0",
            "/storage/emulated/0/Android",
            "/storage/emulated/0/Android/data",
            "/data/data",
            "/data/user/0",
            "/data/user_de/10",
            "/mnt/expand/1234-ABCD",
            "/mnt/expand/1234-ABCD/app",
            "/mnt/expand/1234-ABCD/user/0",
        )) {
            assertTrue(
                path,
                ProtectedTargets.containsProtectedSubtree(
                    path,
                    setOf("com.floe.agent.runtime.full"),
                ),
            )
        }
        assertFalse(
            ProtectedTargets.containsProtectedSubtree(
                "/data/user/0/com.other.app",
                setOf("com.floe.agent.runtime.full"),
            ),
        )
    }

    @Test
    fun canonicalSymlinkEscapeIsOutsideTheLexicalScope() {
        val temp = Files.createTempDirectory("floe-path-scope")
        val root = Files.createDirectory(temp.resolve("root"))
        val outside = Files.createDirectory(temp.resolve("outside"))
        try {
            Files.createSymbolicLink(root.resolve("link"), outside)
            val canonicalRoot = root.toFile().canonicalPath
            val escaped = root.resolve("link").toFile().canonicalFile
            val inside = root.resolve("file.txt").toFile().canonicalFile
            assertFalse(PathPolicy.isWithin(canonicalRoot, escaped.path))
            assertTrue(PathPolicy.isWithin(canonicalRoot, inside.path))
            assertTrue(PathPolicy.isWithinAny(listOf(canonicalRoot), inside.path))
            assertFalse(PathPolicy.isWithinAny(listOf(canonicalRoot), escaped.path))
        } finally {
            Files.deleteIfExists(root.resolve("link"))
            Files.deleteIfExists(root)
            Files.deleteIfExists(outside)
            Files.deleteIfExists(temp)
        }
    }

    @Test
    fun baseNormalizationHandlesRepeatedSeparators() {
        assertEquals("/a/b", PathPolicy.normalizeBase("//a//b/./"))
        assertNull(PathPolicy.normalizeBase("../a"))
        assertNull(PathPolicy.normalizeBase("a/b"))
        assertNotNull(PathPolicy.normalizeBase("/data/local/tmp/floe-x"))
    }
}
