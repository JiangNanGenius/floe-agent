// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/**
 * Focused JVM regression for the package-install hardlink launch compatibility
 * repair (G03-R3, actual candidate10 dpkg failure: backup-link "Permission
 * denied" from real hardlink denial under the pinned Termux PRoot fork, whose
 * link2symlink extension is activated ONLY by -l/--link2symlink; its -0 is the
 * fake root-id option only, cfr. src/cli/proot.h/proot.c at the pinned
 * v5.1.107.98 pin — see provenance r1/repro/final-bootstrap/provenance.json).
 * These tests pin the LAUNCHER CONTRACT only; the binary behavior itself is
 * qualified on-device by Main.
 */
class PRootLaunchSpecCommandTest {

    private class Fixture(val rootfs: File, val scratch: File, val nativeLib: File) {
        fun spec(emulateGuestRoot: Boolean, binds: List<LinuxBind> = emptyList()) =
            PRootLaunchSpec(
                nativeLibraryDirectory = nativeLib,
                rootfs = rootfs,
                scratch = scratch,
                guestWorkingDirectory = "/workspace",
                guestHome = "/home/floe",
                guestTemporaryDirectory = "/tmp",
                binds = binds,
                ownership = RunOwnership("env-1", "run-1", "project-1", rootfs.absolutePath),
                emulateGuestRoot = emulateGuestRoot,
            )
    }

    private fun fixture(test: (Fixture) -> Unit) {
        val home = Files.createTempDirectory("floe-proot-launch-").toFile()
        val rootfs = File(home, "rootfs").apply { check(mkdirs()) }
        val scratch = File(home, "scratch").apply { check(mkdirs()) }
        val nativeLib = File(home, "lib").apply { check(mkdirs()) }
        try { test(Fixture(rootfs, scratch, nativeLib)) } finally {
            home.walkBottomUp().forEach { it.delete() }
        }
    }

    @Test fun guestRootLaunchCarriesRootIdThenHardlinkEmulationInOrder() = fixture { f ->
        val argv = f.spec(emulateGuestRoot = true)
            .command(listOf("/bin/sh", "-lc", "true")).argv
        assertEquals(File(f.nativeLib, "libproot.so").absolutePath, argv[0])
        val prootFlags = argv.takeWhile { !it.startsWith("-b") && it != "-w" }
        assertEquals(
            listOf(File(f.nativeLib, "libproot.so").absolutePath,
                "--kill-on-exit", "-r", f.rootfs.absolutePath, "-0", "-l"),
            prootFlags,
        )
        assertEquals(1, argv.count { it == "-0" })
        assertEquals(1, argv.count { it == "-l" })
    }

    @Test fun nonRootGuestLaunchStillGetsHardlinkEmulationWithoutIdentityFlags() = fixture { f ->
        val argv = f.spec(emulateGuestRoot = false)
            .command(listOf("/bin/sh", "-lc", "true")).argv
        assertTrue("hardlink compatibility must not depend on guest root mode",
            argv.contains("-l"))
        assertFalse("no guest identity may be claimed outside emulateGuestRoot",
            argv.contains("-0"))
        assertFalse("no -i/--change-id/--root-id identity option is ever added",
            argv.any { it == "-i" || it == "--change-id" || it == "--root-id" ||
                it == "--link2symlink" /* short form only: one argv entry, no value */ })
        assertEquals(1, argv.count { it == "-l" })
    }

    @Test fun bindsWorkingDirectoryAndOwnedProotEnvironmentArePreserved() = fixture { f ->
        val workspace = File(f.rootfs, "ws").apply { check(mkdirs()) }
        val launch = f.spec(emulateGuestRoot = true,
            binds = listOf(LinuxBind(workspace, "/workspace")))
            .command(listOf("/bin/sh", "-lc", "true"),
                environment = mapOf("DEBIAN_FRONTEND" to "noninteractive"))
        val argv = launch.argv
        val bindIndex = argv.indexOf("-b")
        assertTrue(bindIndex > 0)
        assertTrue("the emulation flag must precede scoped binds and -w",
            argv.indexOf("-l") < bindIndex)
        assertEquals("${workspace.absolutePath}:/workspace", argv[bindIndex + 1])
        assertEquals("/workspace", argv[argv.indexOf("-w") + 1])
        assertEquals(listOf("/bin/sh", "-lc", "true"), argv.takeLast(3))
        assertEquals(File(f.nativeLib, "libproot_loader.so").absolutePath,
            launch.env["PROOT_LOADER"])
        assertEquals(f.scratch.absolutePath, launch.env["PROOT_TMP_DIR"])
        assertEquals("noninteractive", launch.env["DEBIAN_FRONTEND"])
    }

    @Test fun callersStillCannotInjectProotControlEnvironment() = fixture { f ->
        val spec = f.spec(emulateGuestRoot = true)
        val failure = runCatching {
            spec.command(listOf("/bin/sh", "-lc", "true"),
                environment = mapOf("PROOT_L2S_DIR" to "/tmp/whatever"))
        }.exceptionOrNull()
        assertTrue(failure is IllegalArgumentException)
    }
}
