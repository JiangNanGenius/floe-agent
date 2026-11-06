// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import java.nio.file.Files
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class LinuxDesktopStartupProtocolTest {
    private val nonce = "a".repeat(32)

    @Test fun missingGuestToolsProduceAReceiptBeforeWaitingForCredentials() {
        val failure = runFailure(install = false) { bin ->
            bin.resolve("dbus-run-session").apply {
                writeText("#!/bin/bash\ntest \"\$1\" = -- && shift; exec \"\$@\"\n")
                setExecutable(true)
            }
        }
        assertEquals("vnc_tools", failure.stage)
        assertEquals(73, failure.exitCode)
    }

    @Test fun failedPackageSetupProducesAnImmediateBoundedReceipt() {
        val failure = runFailure(install = true) { bin ->
            bin.resolve("apt-get").apply { writeText("#!/bin/bash\nexit 100\n"); setExecutable(true) }
        }
        assertEquals("packages", failure.stage)
        assertEquals(100, failure.exitCode)
    }

    @Test fun wrongNonceUnknownStageAndEchoedScriptCannotBecomeFailureReceipts() {
        assertNull(LinuxDesktopStartupProtocol.failure("FLOE_START_FAILED:${"b".repeat(32)}:display:1\n", nonce))
        assertNull(LinuxDesktopStartupProtocol.failure("FLOE_START_FAILED:$nonce:arbitrary:1\n", nonce))
        assertNull(LinuxDesktopStartupProtocol.failure("printf 'FLOE_START_FAILED:$nonce:display:1'\n", nonce))
        assertNull(LinuxDesktopStartupProtocol.failure("FLOE_START_FAILED:$nonce:display:999\n", nonce))
        assertEquals(1, LinuxDesktopStartupProtocol.failure("FLOE_START_FAILED:$nonce:display:1\r\n", nonce)?.exitCode)
    }

    /** Run the production launcher with a completely synthetic PATH. No host
     * package manager, display service or guest credentials are used. */
    private fun runFailure(install: Boolean, prepare: (java.io.File) -> Unit): LinuxDesktopStartupProtocol.Failure {
        val root = Files.createTempDirectory("floe-gui-startup-").toFile()
        val bin = root.resolve("bin").apply { mkdirs() }
        Files.createSymbolicLink(bin.resolve("bash").toPath(), java.nio.file.Path.of("/bin/bash"))
        prepare(bin)
        var process: Process? = null
        try {
            process = ProcessBuilder("/bin/bash", "-c", LinuxDesktopCommands.launch(nonce, 171, 960, 1280, install, false))
                .apply {
                    directory(root); environment()["PATH"] = bin.absolutePath
                    environment()["TMPDIR"] = root.absolutePath; redirectErrorStream(true)
                }.start()
            assertTrue("Failed startup must settle without the App handshake timeout", process.waitFor(3, TimeUnit.SECONDS))
            val output = process.inputStream.bufferedReader().readText()
            assertNotEquals(0, process.exitValue())
            assertFalse(output.contains("FLOE_READ:$nonce"))
            assertFalse(output.contains("FLOE_READY:$nonce"))
            return checkNotNull(LinuxDesktopStartupProtocol.failure(output, nonce)) { output }
        } finally {
            process?.destroyForcibly()
            root.deleteRecursively()
        }
    }
}
