// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CreativePathGuardTest {
    @Test
    fun `relative paths reject traversal absolute and empty components`() {
        assertTrue(CreativePathGuard.isSafeRelativePath(null))
        assertTrue(CreativePathGuard.isSafeRelativePath("Workbench/Assets/a.png"))
        assertTrue(CreativePathGuard.isSafeRelativePath("materials-1.png"))
        for (bad in listOf("../a", "a/../../b", "/etc/passwd", "a//b", "a/./b", "", "a\\b")) {
            assertFalse(bad, CreativePathGuard.isSafeRelativePath(bad))
        }
    }

    @Test
    fun `resolveUnder never returns a path outside the trusted root`() {
        val root = File(System.getProperty("java.io.tmpdir"), "creative-root").path
        val inside = CreativePathGuard.resolveUnder(root, "Workbench/Assets/a.png")
        assertTrue(inside != null)
        assertTrue(inside!!.startsWith(File(root).path))
        assertNull(CreativePathGuard.resolveUnder(root, "../outside.png"))
        assertNull(CreativePathGuard.resolveUnder(root, "/outside.png"))
    }

    @Test
    fun `session tokens are bounded and filename safe`() {
        assertTrue(CreativeSessionTokens.isValid(CreativeSessionTokens.newToken()))
        assertTrue(CreativeSessionTokens.isValid("session-1.abc_DEF"))
        assertFalse(CreativeSessionTokens.isValid(""))
        assertFalse(CreativeSessionTokens.isValid("bad/token"))
        assertFalse(CreativeSessionTokens.isValid("x".repeat(129)))
    }
}
