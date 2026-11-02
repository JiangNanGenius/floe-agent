// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * AUTHORED NOT RUN — pure C01 separated-stdio argv resolution.
 *
 * This is the no-shell authority: a saved command/arguments/cwd must become an
 * exact guest argv, never a shell string. The tests pin absolute passthrough,
 * workspace-relative resolution, the environment's OWN PATH search and every
 * traversal/absence refusal. They create no process.
 */
class C01StdioCommandTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `absolute guest executable is passed through with args unchanged`() {
        val root = temporary.newFolder("root")
        val argv = C01StdioCommand.resolve(
            "/usr/bin/node", listOf("server.mjs", "--stdio", "a b;c"), ".", root)
        assertEquals(listOf("/usr/bin/node", "server.mjs", "--stdio", "a b;c"), argv)
    }

    @Test
    fun `bare command is found only inside the selected writable root`() {
        val root = temporary.newFolder("root")
        val bin = File(root, "usr/local/bin").apply { mkdirs() }
        File(bin, "uvx").writeText("#!/bin/sh\n")
        assertTrue(File(bin, "uvx").isFile)
        val argv = C01StdioCommand.resolve("uvx", listOf("mcp-server"), ".", root)
        assertEquals(listOf("/usr/local/bin/uvx", "mcp-server"), argv)
        assertFalse(argv[0].startsWith(root.absolutePath))
    }

    @Test
    fun `bare command absence is refused instead of a host fallback`() {
        val root = temporary.newFolder("root")
        try {
            C01StdioCommand.resolve("node", emptyList(), ".", root)
            throw AssertionError("A missing guest command must be refused")
        } catch (expected: IllegalArgumentException) {
            assertEquals("stdioCommandNotFound", expected.message)
        }
    }

    @Test
    fun `relative command is resolved against the workspace cwd`() {
        val root = temporary.newFolder("root")
        val argv = C01StdioCommand.resolve(
            "node-http/floe-start.mjs", listOf("--port", "0"),
            "MCPServices/abc", root)
        assertEquals(
            listOf("/workspace/MCPServices/abc/node-http/floe-start.mjs", "--port", "0"),
            argv)
        val atRoot = C01StdioCommand.resolve("tools/server", emptyList(), "", root)
        assertEquals(listOf("/workspace/tools/server"), atRoot)
    }

    @Test
    fun `traversal and malformed components are refused everywhere`() {
        val root = temporary.newFolder("root")
        assertRefused { C01StdioCommand.resolve("../sh", emptyList(), "", root) }
        assertRefused { C01StdioCommand.resolve("/usr/../../etc/sh", emptyList(), "", root) }
        assertRefused { C01StdioCommand.resolve("node", emptyList(), "a/../b", root) }
        assertRefused { C01StdioCommand.resolve("/bin/sh", emptyList(), "a/./b", root) }
        assertRefused { C01StdioCommand.resolve("node\nrm", emptyList(), "", root) }
        assertRefused { C01StdioCommand.resolve("", emptyList(), "", root) }
        assertRefused { C01StdioCommand.resolve("node", List(65) { "a" }, "", root) }
    }

    private fun assertRefused(block: () -> Unit) {
        try {
            block()
            throw AssertionError("Expected the command resolver to refuse")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }
}
