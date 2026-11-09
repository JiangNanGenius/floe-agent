// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardOpenOption.READ
import org.junit.Assert.*
import org.junit.Test

class RootfsOwnedSourceAccessTest {
    private fun fixture(test: (Path, Path, Path, Int) -> Unit) {
        val home = Files.createTempDirectory("floe-owned-source-").toRealPath()
        try {
            val root = Files.createDirectory(home.resolve("project"))
            val file = Files.writeString(root.resolve("restricted"), "original bytes")
            val uid = (Files.getAttribute(root, "unix:uid") as Number).toInt()
            Files.setAttribute(file, "unix:mode", 0)
            assertFalse("real non-root permission boundary required", Files.isReadable(file))
            test(home, root, file, uid)
        } finally {
            Files.walk(home).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) } }
        }
    }
    private fun mode(file: Path) = (Files.getAttribute(file, "unix:mode", NOFOLLOW_LINKS) as Number).toInt() and 0xFFF
    private fun read(channel: FileChannel): String = channel.use {
        val bytes = java.nio.ByteBuffer.allocate(64)
        while (it.read(bytes) > 0) { }
        String(bytes.array(), 0, bytes.position(), Charsets.UTF_8)
    }

    @Test fun ownedModeZeroIsCopiedWithSourceAndDestinationModesPreserved() = fixture { home, root, file, uid ->
        val child = Files.createDirectory(home.resolve("task"))
        val materializer = LinuxRootfsMaterializer(ownerUid = uid)
        val result = materializer.prepare(LinuxRootfsMaterializer.Plan("task", "base", child.toFile(),
            listOf(child.toFile(), root.toFile()))) { false }
        assertFalse(result.reused)
        val copied = child.resolve("restricted")
        assertEquals(0, mode(file)); assertEquals(0, mode(copied))
        assertEquals("original bytes", read(RootfsOwnedSourceAccess(root, uid).open(file)))
        assertEquals("original bytes", read(RootfsOwnedSourceAccess(child, uid).open(copied)))
        assertEquals(0, mode(file)); assertEquals(0, mode(copied))
        assertFalse(Files.exists(RootfsOwnedSourceAccess(root, uid).journal))
        assertFalse(Files.exists(RootfsOwnedSourceAccess(child, uid).journal))
    }

    @Test fun interruptedPermissionGrantRecoversBeforeMarkedLayerReuse() = fixture { home, base, file, uid ->
        val root = Files.createDirectory(home.resolve("task"))
        val plan = LinuxRootfsMaterializer.Plan("task", "base", root.toFile(), listOf(root.toFile(), base.toFile()))
        LinuxRootfsMaterializer(ownerUid = uid).prepare(plan) { false }
        val access = RootfsOwnedSourceAccess(base, uid)
        access.beginRead(file) // actual durable record + chmod; simulate process death before open/restore
        assertEquals(0x100, mode(file)); assertTrue(Files.exists(access.journal))
        assertTrue(LinuxRootfsMaterializer(ownerUid = uid).prepare(plan) { false }.reused)
        assertEquals(0, mode(file)); assertFalse(Files.exists(access.journal))
    }

    @Test fun failedOpenRestoresTheOriginalModeAndRetiresItsRecord() = fixture { _, root, file, uid ->
        var opens = 0
        val access = RootfsOwnedSourceAccess(root, uid) { path ->
            opens++
            if (opens == 2) throw IOException("injected open failure after durable grant")
            FileChannel.open(path, READ, NOFOLLOW_LINKS)
        }
        val failure = assertThrows(IOException::class.java) { access.open(file) }
        assertEquals("injected open failure after durable grant", failure.message)
        assertEquals(0, mode(file)); assertFalse(Files.exists(access.journal))
        assertEquals("original bytes", read(RootfsOwnedSourceAccess(root, uid).open(file)))
        assertEquals(0, mode(file))
    }

    @Test fun recoveryRefusesAReplacedInodeWithoutChangingIt() = fixture { _, root, file, uid ->
        val access = RootfsOwnedSourceAccess(root, uid)
        access.beginRead(file)
        val saved = root.resolve("saved-original")
        Files.move(file, saved)
        Files.writeString(file, "replacement")
        val replacementMode = mode(file)
        assertThrows(IOException::class.java) { RootfsOwnedSourceAccess(root, uid).recover() }
        assertEquals("replacement", Files.readString(file)); assertEquals(replacementMode, mode(file))
        assertTrue(Files.exists(access.journal))
        Files.delete(file); Files.move(saved, file)
        RootfsOwnedSourceAccess(root, uid).recover()
        assertEquals(0, mode(file)); assertFalse(Files.exists(access.journal))
    }

    @Test fun recoveryRefusesALinkAndDoesNotTouchItsTarget() = fixture { home, root, file, uid ->
        val outside = Files.writeString(home.resolve("outside"), "outside")
        val oldMode = mode(outside)
        val access = RootfsOwnedSourceAccess(root, uid)
        access.beginRead(file)
        val saved = root.resolve("saved-original"); Files.move(file, saved)
        Files.createSymbolicLink(file, outside)
        assertThrows(IOException::class.java) { RootfsOwnedSourceAccess(root, uid).recover() }
        assertEquals(oldMode, mode(outside)); assertEquals("outside", Files.readString(outside))
        assertTrue(Files.exists(access.journal))
        Files.delete(file); Files.move(saved, file); access.recover()
        assertEquals(0, mode(file))
    }

    @Test fun anUnmatchedOwnerCannotBorrowReadPermission() = fixture { _, root, file, uid ->
        val access = RootfsOwnedSourceAccess(root, uid + 1)
        assertThrows(IOException::class.java) { access.open(file) }
        assertEquals(0, mode(file)); assertFalse(Files.exists(access.journal))
    }

    @Test fun transactionRollbackPreservesModeZeroAndOriginalBytes() = fixture { home, base, _, uid ->
        val root = Files.createDirectory(home.resolve("task"))
        val copier = LinuxRootfsMaterializer(ownerUid = uid)
        copier.prepare(LinuxRootfsMaterializer.Plan("task", "base", root.toFile(),
            listOf(root.toFile(), base.toFile()))) { false }
        val owner = LinuxEnvironmentTransaction(copier)
        val handle = owner.prepare("task", root.toFile()) { false }
        val file = root.resolve("restricted")
        Files.setAttribute(file, "unix:mode", 0x180)
        Files.writeString(file, "changed bytes")
        owner.finish(handle, false)
        assertEquals(0, mode(file))
        assertEquals("original bytes", read(RootfsOwnedSourceAccess(root, uid).open(file)))
        assertEquals(0, mode(file))
        owner.release(handle)
    }
}
