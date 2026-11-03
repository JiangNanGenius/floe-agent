// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.host.services.C01ManagedServiceOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AUTHORED NOT RUN — pure C01 separated-stdio admission vocabulary.
 *
 * These pin the values the trusted pump and the Swift provider must agree on:
 * the exact live-peer contract string, the closed declaration bounds, and the
 * refusal of every value that would turn the argv into a shell string or a
 * host/interpreted path. They never touch a device, process or Binder.
 */
class C01LinuxStdioTest {

    @Test
    fun `stdio lane requires the exact real peer contract`() {
        assertEquals("floe-service-stdio-v1", C01ManagedServiceOwner.STDIO_CONTRACT)
        assertTrue(C01ManagedServiceOwner.contractSupportsStdio("floe-service-stdio-v1"))
        assertFalse(C01ManagedServiceOwner.contractSupportsStdio(null))
        assertFalse(C01ManagedServiceOwner.contractSupportsStdio(""))
        assertFalse(C01ManagedServiceOwner.contractSupportsStdio("floe-multi-workload-v2"))
        assertFalse(C01ManagedServiceOwner.contractSupportsStdio("floe-multi-workload-v3"))
        // The service role and the pipe lane are distinct capabilities.
        assertTrue(C01ManagedServiceOwner.contractSupportsServices("floe-multi-workload-v3"))
        assertFalse(C01ManagedServiceOwner.contractSupportsServices("floe-service-stdio-v1"))
    }

    @Test
    fun `admissible stdio declaration is accepted unchanged`() {
        assertNull(C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node", listOf("server.mjs", "--stdio"), "MCPServices/demo/node-http"))
        assertNull(C01ManagedServiceOwner.stdioDeclarationRefusal(
            "/usr/bin/python3", emptyList(), ""))
        assertNull(C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node-http/floe-start.mjs", listOf("--flag=a b"), ""))
    }

    @Test
    fun `shell-shaped or escaping declarations are refused`() {
        // No shell string: newlines are refused, so one argv entry can never
        // become two commands.
        assertEquals("command", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node\nrm -rf /", emptyList(), ""))
        assertEquals("command", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node\u0000", emptyList(), ""))
        assertEquals("command", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "../../bin/sh", emptyList(), ""))
        assertEquals("command", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "", emptyList(), ""))
        assertEquals("arguments", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node", List(65) { "a" }, ""))
        assertEquals("arguments", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node", listOf("ok", "bad\narg"), ""))
        assertEquals("cwd", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node", emptyList(), "/absolute"))
        assertEquals("cwd", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node", emptyList(), "../escape"))
        assertEquals("cwd", C01ManagedServiceOwner.stdioDeclarationRefusal(
            "node", emptyList(), "a\\b"))
    }

    @Test
    fun `only the two managed-service slots exist and a port is still required for HTTP services`() {
        assertNull(C01ManagedServiceOwner.declarationRefusal("node", "server.mjs", 8080))
        assertEquals("port", C01ManagedServiceOwner.declarationRefusal("node", "server.mjs", null))
        assertEquals("port", C01ManagedServiceOwner.declarationRefusal("node", "server.mjs", 80))
        assertEquals("runtime", C01ManagedServiceOwner.declarationRefusal("ruby", "server.rb", 8080))
    }
}
