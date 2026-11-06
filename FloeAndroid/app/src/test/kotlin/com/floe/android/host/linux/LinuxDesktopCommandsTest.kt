// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

/** Synthetic host executables exercise the production guest script protocol.
 * This is not Android execution or graphical-window acceptance. */
class LinuxDesktopCommandsTest {
    @Test fun launcherKeepsItsCommandStreamAndDisplayAfterStartup() {
        val root = Files.createTempDirectory("floe-gui-protocol-").toFile()
        val bin = root.resolve("bin").apply { mkdirs() }
        fun executable(name: String, body: String) = bin.resolve(name).apply {
            writeText("#!/bin/bash\n$body\n"); setExecutable(true)
        }
        executable("stty", "exit 0")
        executable("vncpasswd", "cat")
        executable("Xtigervnc", "exec sleep 30")
        executable("dbus-run-session", "test \"\$1\" = -- && shift; export DBUS_SESSION_BUS_ADDRESS=synthetic-project-bus; exec \"\$@\"")
        executable("openbox", "printf '%s' \"\$DBUS_SESSION_BUS_ADDRESS\" > \"\$WMTRACE\"; exec sleep 30")
        executable("inkscape", "printf '%s|%s|%s' \"\$DISPLAY\" \"\${1:-}\" \"\$DBUS_SESSION_BUS_ADDRESS\" > \"\$TRACE\"")
        executable("gimp", "exit 7")
        executable("pcmanfm", """
            if test "${'$'}{1:-}" = --daemon-mode; then
              exec python3 -c 'import os,socket,time; os.chdir(os.environ["XDG_RUNTIME_DIR"]); s=socket.socket(socket.AF_UNIX); s.bind("pcmanfm-socket--"+os.environ["DISPLAY"].split(":")[1]); s.listen(); time.sleep(30)'
            fi
            printf '%s|%s|%s|%s' "${'$'}DISPLAY" "${'$'}{1:-}" "${'$'}{2:-}" "${'$'}DBUS_SESSION_BUS_ADDRESS" > "${'$'}PCMANFMTRACE"
            printf '%s\n' window >> "${'$'}PCMANFMCOUNT"
        """.trimIndent())
        executable("apt-get", "if IFS= read -r leaked; then exit 42; fi; exit 0")
        root.resolve("work file.svg").writeText("<svg/>")
        val executor = Executors.newSingleThreadExecutor()
        val process = ProcessBuilder("bash", "-c", LinuxDesktopCommands.launch("a".repeat(32),
            171, 960, 1280, install = false, desktop = false)).apply {
            directory(root)
            environment()["PATH"] = bin.absolutePath + ":" + System.getenv("PATH")
            environment()["TMPDIR"] = root.absolutePath
            environment()["TRACE"] = root.resolve("trace").absolutePath
            environment()["WMTRACE"] = root.resolve("wm-trace").absolutePath
            environment()["PCMANFMTRACE"] = root.resolve("pcmanfm-trace").absolutePath
            environment()["PCMANFMCOUNT"] = root.resolve("pcmanfm-count").absolutePath
            redirectErrorStream(true)
        }.start()
        try {
            val reader = process.inputStream.bufferedReader()
            fun awaitLine(expected: String) {
                executor.submit<Boolean> {
                    while (true) {
                        val line = reader.readLine() ?: return@submit false
                        if (line == expected) return@submit true
                    }
                    @Suppress("UNREACHABLE_CODE") false
                }.get(8, TimeUnit.SECONDS).also { assertTrue(expected, it) }
            }
            awaitLine("FLOE_READ:" + "a".repeat(32))
            process.outputStream.write("synthetic-password\n".toByteArray()); process.outputStream.flush()
            awaitLine("FLOE_READY:" + "a".repeat(32))
            process.outputStream.write(LinuxDesktopCommands.application("inkscape", false, "b".repeat(32))); process.outputStream.flush()
            awaitLine("FLOE_APP_STARTED:" + "b".repeat(32))
            val trace = root.resolve("trace")
            fun awaitTrace(file: java.io.File): String {
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                while ((!file.isFile || file.length() == 0L) && System.nanoTime() < deadline) Thread.sleep(10)
                assertTrue("Owned child must publish its trace: ${file.name}", file.isFile && file.length() > 0L)
                return file.readText()
            }
            awaitTrace(trace)
            assertEquals(":171||synthetic-project-bus", trace.readText())
            assertEquals("synthetic-project-bus", awaitTrace(root.resolve("wm-trace")))
            root.resolve("floe-gui-" + "a".repeat(32)).resolve("pcmanfm-socket--171").writeText("stale owned socket")
            process.outputStream.write(LinuxDesktopCommands.application("pcmanfm", false, "1".repeat(32)))
            process.outputStream.flush()
            awaitLine("FLOE_APP_STARTED:" + "1".repeat(32))
            assertEquals(":171|--new-win|${root.canonicalPath}|synthetic-project-bus", awaitTrace(root.resolve("pcmanfm-trace")))
            assertEquals(listOf("window"), root.resolve("pcmanfm-count").readLines())
            process.outputStream.write(LinuxDesktopCommands.application("gimp", false, "c".repeat(32))
                .toString(Charsets.UTF_8).replace("\n", "\r\n").toByteArray())
            process.outputStream.flush()
            awaitLine("FLOE_APP_FAILED:" + "c".repeat(32) + ":exit")
            val file = java.util.Base64.getEncoder().encodeToString("work file.svg".toByteArray())
            process.outputStream.write(("open:inkscape:$file:" + "d".repeat(32) + "\n").toByteArray())
            process.outputStream.flush()
            awaitLine("FLOE_APP_STARTED:" + "d".repeat(32))
            assertEquals(":171|./work file.svg|synthetic-project-bus", trace.readText())
            process.outputStream.write(("install:inkscape:" + "e".repeat(32) + "\nping:" + "f".repeat(32) + "\n").toByteArray())
            process.outputStream.flush()
            awaitLine("FLOE_INSTALLED:" + "e".repeat(32))
            awaitLine("FLOE_PONG:" + "f".repeat(32))
            process.outputStream.write("stop\n".toByteArray()); process.outputStream.flush()
            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(0, process.exitValue())
        } finally {
            runCatching { process.outputStream.close() }
            if (!process.waitFor(3, TimeUnit.SECONDS)) process.destroyForcibly()
            runCatching { process.inputStream.close() }
            executor.shutdownNow(); root.deleteRecursively()
        }
    }
}
