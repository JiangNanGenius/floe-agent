// SPDX-License-Identifier: MPL-2.0
// Regression sources for the Alpha68 Samsung materialization-start failure
// (job-d169dd02bbb941bd): a task-only environment inherits a LIVE
// project/shared layer whose earlier GUI guest sessions left unix-socket
// endpoints behind; the layer copier used to refuse the whole start with a
// generic swallowed failure. These tests pin: sockets/FIFOs are skipped and
// counted (never fatal), devices still refuse with a typed code, every raw
// copy-phase IOException carries the closed rootfs_copy_io code, and
// cancellation stays an InterruptedException subtype.
// Author-written; NOT executed by this lane (primary owns builds/tests).
package com.floe.android.linuxruntime.rootfs

import java.net.StandardProtocolFamily
import java.nio.channels.ServerSocketChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class LinuxRootfsMaterializerRuntimeEntriesTest {

    // The host JDK supplies AF_UNIX. Compile against Android's narrower
    // ServerSocketChannel surface while exercising the real host socket.
    private fun socketChannel(): ServerSocketChannel = ServerSocketChannel::class.java
        .getMethod("open", java.net.ProtocolFamily::class.java)
        .invoke(null, StandardProtocolFamily.UNIX) as ServerSocketChannel

    private fun fixture(test: (Path, Path, Path) -> Unit) {
        // AF_UNIX has a short pathname limit. Gradle's internal build-cache
        // fixture path is too long; keep this small, owned fixture in Local.
        val repo = generateSequence(Path.of(System.getProperty("user.dir")).toAbsolutePath()) { it.parent }
            .first { Files.isDirectory(it.resolve("FloeAndroid")) }
        val fixtureRoot = Files.createDirectories(repo.resolve("Local/Scratch/a68"))
        val home = Files.createTempDirectory(fixtureRoot, "s").toRealPath()
        try {
            val parent = Files.createDirectory(home.resolve("parent"))
            val child = Files.createDirectory(home.resolve("child"))
            val base = Files.createDirectory(home.resolve("base"))
            Files.createDirectories(base.resolve("usr/bin"))
            Files.writeString(base.resolve("usr/bin/base-tool"), "base")
            Files.createDirectories(base.resolve("etc"))
            Files.writeString(base.resolve("etc/config"), "config")
            test(parent, child, base)
        } finally {
            Files.walk(home).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
            }
        }
    }

    private fun parentPlan(parent: Path, base: Path) = LinuxRootfsMaterializer.Plan(
        "parent-env", "base-1", parent.toFile(), listOf(parent.toFile(), base.toFile()))

    private fun childPlan(child: Path, parent: Path, base: Path) = LinuxRootfsMaterializer.Plan(
        "child-env", "base-1", child.toFile(), listOf(child.toFile(), parent.toFile(), base.toFile()))

    @Test fun inheritedLiveLayerSocketDoesNotRefuseMaterialization() = fixture { parent, child, base ->
        val materializer = LinuxRootfsMaterializer()
        materializer.prepare(parentPlan(parent, base)) { false }
        // An earlier GUI guest session leaves its X11 socket endpoint behind.
        val x11 = Files.createDirectories(parent.resolve("tmp/.X11-unix"))
        val socketPath = x11.resolve("X0")
        socketChannel().use { channel ->
            channel.bind(java.net.UnixDomainSocketAddress.of(socketPath))
            val result = materializer.prepare(childPlan(child, parent, base)) { false }
            assertFalse(result.reused)
            assertEquals(1, result.skippedRuntimeEntries)
            // Real content of the inherited layer still materializes.
            assertEquals("base", Files.readString(child.resolve("usr/bin/base-tool")))
            assertTrue(Files.isDirectory(child.resolve("tmp/.X11-unix"), NOFOLLOW_LINKS))
            // The socket endpoint itself is not (cannot be) copied.
            assertFalse(Files.exists(child.resolve("tmp/.X11-unix/X0")))
            // Marker published: the child env is materialized for reuse.
            assertTrue(Files.isRegularFile(child.resolve(".floe-linux-rootfs-v1"), NOFOLLOW_LINKS))
        }
        // The source layer keeps its own socket (user files are never reset).
        assertTrue(Files.exists(socketPath))
    }

    @Test fun multipleInheritedSocketsAreAllCounted() = fixture { parent, child, base ->
        val materializer = LinuxRootfsMaterializer()
        materializer.prepare(parentPlan(parent, base)) { false }
        val run = Files.createDirectories(parent.resolve("run/dbus"))
        val first = run.resolve("bus")
        val second = Files.createDirectories(parent.resolve("tmp")).resolve("second.sock")
        socketChannel().use { a ->
            a.bind(java.net.UnixDomainSocketAddress.of(first))
            socketChannel().use { b ->
                b.bind(java.net.UnixDomainSocketAddress.of(second))
                val result = materializer.prepare(childPlan(child, parent, base)) { false }
                assertEquals(2, result.skippedRuntimeEntries)
                assertFalse(result.reused)
            }
        }
    }

    @Test fun cleanBaseColdCopySkipsNothing() = fixture { _, child, base ->
        val result = LinuxRootfsMaterializer().prepare(parentPlan(child, base)) { false }
        assertFalse(result.reused)
        assertEquals(0, result.skippedRuntimeEntries)
        assertTrue(Files.isRegularFile(child.resolve(".floe-linux-rootfs-v1"), NOFOLLOW_LINKS))
    }

    @Test fun copyPhaseIoFailureCarriesClosedCode() = fixture { parent, child, base ->
        // A regular file the owner cannot read reproduces a copy-phase
        // open() EACCES on POSIX hosts without root privileges.
        Files.setAttribute(base.resolve("etc/config"), "unix:mode", 0)
        val probe = Files.isReadable(base.resolve("etc/config"))
        assumeTrue("test requires a non-root runner (mode-000 file unreadable)", !probe)
        val failure = assertThrows(RootfsMaterializeException::class.java) {
            LinuxRootfsMaterializer().prepare(parentPlan(child, base)) { false }
        }
        assertEquals(RootfsMaterializeException.CODE_ROOTFS_COPY_IO, failure.code)
        assertEquals("open_input", failure.operation)
        assertEquals(0, failure.sourceMode)
        assertEquals((Files.getAttribute(base.resolve("etc/config"), "unix:uid") as Number).toInt(),
            failure.sourceOwnerUid)
        // The original layer is untouched by a failed cold copy.
        assertFalse(Files.exists(child.resolve(".floe-linux-rootfs-v1")))
    }

    @Test fun byteBudgetRefusalCarriesClosedCode() = fixture { parent, child, base ->
        val failure = assertThrows(RootfsMaterializeException::class.java) {
            LinuxRootfsMaterializer(maxBytes = 2).prepare(parentPlan(child, base)) { false }
        }
        assertEquals(RootfsMaterializeException.CODE_ROOTFS_COPY_BYTE_BUDGET, failure.code)
    }

    @Test fun markerMismatchIsARefusalNotASilentReset() = fixture { parent, child, base ->
        val materializer = LinuxRootfsMaterializer()
        materializer.prepare(parentPlan(parent, base)) { false }
        // A different base revision against the SAME environment: refuse.
        val failure = assertThrows(RootfsMaterializeException::class.java) {
            materializer.prepare(LinuxRootfsMaterializer.Plan(
                "parent-env", "base-2", parent.toFile(), listOf(parent.toFile(), base.toFile()))) { false }
        }
        assertEquals(RootfsMaterializeException.CODE_ROOTFS_MARKER_MISMATCH, failure.code)
        // The existing layer content is preserved byte-for-byte.
        assertEquals("base", Files.readString(parent.resolve("usr/bin/base-tool")))
    }

    @Test fun cancellationStaysAnInterruptedExceptionSubtype() = fixture { parent, child, base ->
        val failure = assertThrows(RootfsPrepareCancelledException::class.java) {
            LinuxRootfsMaterializer().prepare(parentPlan(child, base)) { true }
        }
        // Historical callers/tests contract on InterruptedException exactly.
        assertTrue(failure is InterruptedException)
        // Cancellation is NOT a RootfsMaterializeException defect code.
        assertFalse(RootfsMaterializeException::class.java.isInstance(failure))
    }
}
