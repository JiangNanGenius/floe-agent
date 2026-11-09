// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardOpenOption.READ
import java.nio.file.SimpleFileVisitor
import java.nio.file.FileVisitResult
import java.nio.file.attribute.BasicFileAttributes
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
            val uid = (Files.getAttribute(home, "unix:uid") as Number).toInt()
            RootfsOwnedSourceAccess(home, uid).walk(object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    Files.delete(file); return FileVisitResult.CONTINUE
                }
                override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult {
                    if (exc != null) throw exc
                    Files.delete(dir); return FileVisitResult.CONTINUE
                }
            }, deleting = true)
        }
    }
    private fun mode(file: Path) = (Files.getAttribute(file, "unix:mode", NOFOLLOW_LINKS) as Number).toInt() and 0xFFF
    private fun read(channel: FileChannel): String = channel.use {
        val bytes = java.nio.ByteBuffer.allocate(64)
        while (it.read(bytes) > 0) { }
        String(bytes.array(), 0, bytes.position(), Charsets.UTF_8)
    }

    private fun tree(root: Path, uid: Int): Pair<Map<String, Int>, Map<String, String>> {
        val access = RootfsOwnedSourceAccess(root, uid)
        val modes = mutableMapOf<String, Int>(); val bytes = mutableMapOf<String, String>()
        access.walk(object : SimpleFileVisitor<Path>() {
            override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
                modes[root.relativize(dir).toString()] = access.originalMode(dir)
                return FileVisitResult.CONTINUE
            }
            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                modes[root.relativize(file).toString()] = access.originalMode(file)
                if (attrs.isRegularFile) bytes[root.relativize(file).toString()] = read(access.open(file))
                return FileVisitResult.CONTINUE
            }
        })
        assertFalse(Files.exists(access.journal))
        return modes to bytes
    }

    private fun lockedTree(root: Path): Triple<Path, Path, Path> {
        val outer = Files.createDirectory(root.resolve("locked"))
        val inner = Files.createDirectory(outer.resolve("nested"))
        val file = Files.writeString(inner.resolve("payload"), "nested bytes")
        Files.setAttribute(file, "unix:mode", 0)
        Files.setAttribute(inner, "unix:mode", 0x40) // search only
        Files.setAttribute(outer, "unix:mode", 0)
        return Triple(outer, inner, file)
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

    @Test fun nestedUnreadableDirectoriesCopyContentAndPreserveEveryMode() = fixture { home, base, _, uid ->
        val (outer, _, _) = lockedTree(base)
        val child = Files.createDirectory(home.resolve("task"))
        LinuxRootfsMaterializer(ownerUid = uid).prepare(LinuxRootfsMaterializer.Plan("task", "base", child.toFile(),
            listOf(child.toFile(), base.toFile()))) { false }
        assertEquals(0, mode(outer)); assertEquals(0, mode(child.resolve("locked")))
        assertFalse(Files.exists(RootfsOwnedSourceAccess(base, uid).journal))
        val source = tree(base, uid); val copied = tree(child, uid)
        assertEquals(0, source.first["locked"]); assertEquals(0x40, source.first["locked/nested"])
        assertEquals(0, source.first["locked/nested/payload"])
        for ((name, value) in source.first) assertEquals(name, value, copied.first[name])
        for ((name, value) in source.second) assertEquals(name, value, copied.second[name])
        assertEquals("nested bytes", copied.second["locked/nested/payload"])
    }

    @Test fun readableDirectoryWithoutSearchIsPreparedBeforeChildLookup() = fixture { _, root, _, uid ->
        val directory = Files.createDirectory(root.resolve("read-only"))
        Files.writeString(directory.resolve("payload"), "reachable")
        Files.setAttribute(directory, "unix:mode", 0x100)
        val result = tree(root, uid)
        assertEquals("reachable", result.second["read-only/payload"])
        assertEquals(0x100, result.first["read-only"]); assertEquals(0x100, mode(directory))
    }

    @Test fun interruptedNestedDirectoryAndFileGrantsRecoverInOrder() = fixture { _, root, _, uid ->
        val (outer, inner, file) = lockedTree(root)
        val access = RootfsOwnedSourceAccess(root, uid)
        access.beginDirectory(outer); access.beginDirectory(inner); access.beginRead(file)
        assertEquals(0x140, mode(outer)); assertEquals(0x140, mode(inner)); assertEquals(0x100, mode(file))
        RootfsOwnedSourceAccess(root, uid).recover()
        assertFalse(Files.exists(access.journal)); assertEquals(0, mode(outer))
        val result = tree(root, uid)
        assertEquals(0x40, result.first["locked/nested"]); assertEquals(0, result.first["locked/nested/payload"])
        assertEquals("nested bytes", result.second["locked/nested/payload"])
    }

    @Test fun cancellationRestoresAllEnteredDirectories() = fixture { _, root, _, uid ->
        val (_, _, file) = lockedTree(root)
        val access = RootfsOwnedSourceAccess(root, uid)
        assertThrows(InterruptedException::class.java) {
            access.walk(object : SimpleFileVisitor<Path>() {
                override fun visitFile(path: Path, attrs: BasicFileAttributes): FileVisitResult {
                    if (path == file) throw InterruptedException("owned fixture cancellation")
                    return FileVisitResult.CONTINUE
                }
            })
        }
        assertFalse(Files.exists(access.journal)); assertEquals(0, mode(root.resolve("locked")))
        val result = tree(root, uid)
        assertEquals(0x40, result.first["locked/nested"]); assertEquals(0, result.first["locked/nested/payload"])
    }

    @Test fun transactionRollbackAndCleanupHandleUnreadableDirectories() = fixture { home, base, _, uid ->
        lockedTree(base)
        val root = Files.createDirectory(home.resolve("task")); val copier = LinuxRootfsMaterializer(ownerUid = uid)
        copier.prepare(LinuxRootfsMaterializer.Plan("task", "base", root.toFile(), listOf(root.toFile(), base.toFile()))) { false }
        val expected = tree(root, uid)
        val owner = LinuxEnvironmentTransaction(copier); val handle = owner.prepare("task", root.toFile()) { false }
        Files.writeString(root.resolve("new-file"), "change")
        owner.finish(handle, false); owner.release(handle)
        assertEquals(expected, tree(root, uid)); assertFalse(Files.exists(root.resolve("new-file")))
        assertEquals(0, mode(root.resolve("locked")))
    }

    @Test fun legacySingleFileRecordStillRestoresItsOriginalMode() = fixture { _, root, file, uid ->
        val access = RootfsOwnedSourceAccess(root, uid)
        val value = java.util.Properties().apply {
            setProperty("version", "1"); setProperty("uid", uid.toString()); setProperty("relative", "restricted")
            setProperty("rootKey", Files.readAttributes(root, BasicFileAttributes::class.java).fileKey().toString())
            setProperty("key", Files.readAttributes(file, BasicFileAttributes::class.java).fileKey().toString())
            setProperty("mode", "0")
        }
        Files.newOutputStream(access.journal).use { value.store(it, null) }
        Files.setAttribute(file, "unix:mode", 0x100)
        RootfsOwnedSourceAccess(root, uid).recover()
        assertEquals(0, mode(file)); assertFalse(Files.exists(access.journal))
    }

    @Test fun liveSiblingRefusesNewPermissionChangesButAllowsReadableFiles() = fixture { _, root, file, uid ->
        val access = RootfsOwnedSourceAccess(root, uid, mayChangePermissions = { false })
        val readable = Files.writeString(root.resolve("readable"), "allowed")
        assertEquals("allowed", read(access.open(readable)))
        val failure = assertThrows(RootfsMaterializeException::class.java) { access.open(file) }
        assertEquals(RootfsMaterializeException.CODE_ROOTFS_SOURCE_BUSY, failure.code)
        assertEquals(0, mode(file)); assertFalse(Files.exists(access.journal))
    }

    @Test fun failedNestedRecoveryRestoresActivatedAncestorsAndKeepsRecords() = fixture { _, root, _, uid ->
        val directory = Files.createDirectory(root.resolve("locked"))
        val file = Files.writeString(directory.resolve("payload"), "protected")
        Files.setAttribute(file, "unix:mode", 0); Files.setAttribute(directory, "unix:mode", 0x80)
        val access = RootfsOwnedSourceAccess(root, uid)
        access.beginDirectory(directory); access.beginRead(file)
        val saved = root.resolve("saved-original"); Files.move(file, saved)
        Files.writeString(file, "replacement")
        assertThrows(IOException::class.java) { RootfsOwnedSourceAccess(root, uid).recover() }
        assertEquals(0x80, mode(directory)); assertTrue(Files.exists(access.journal))
        // Operator repairs the deliberate inode replacement; leave the
        // recorded temporary mode so the original durable record remains valid.
        Files.setAttribute(directory, "unix:mode", 0x1C0)
        assertEquals("replacement", Files.readString(file))
        Files.delete(file); Files.move(saved, file)
        RootfsOwnedSourceAccess(root, uid).recover()
        assertEquals(0x80, mode(directory)); assertFalse(Files.exists(access.journal))
        assertEquals("protected", tree(root, uid).second["locked/payload"])
    }

    @Test fun unreadableMarkedAncestorIsNotTreatedAsAnAbsentMarker() = fixture { home, base, _, uid ->
        val parent = Files.createDirectory(home.resolve("parent")); val child = Files.createDirectory(home.resolve("task"))
        val copier = LinuxRootfsMaterializer(ownerUid = uid)
        copier.prepare(LinuxRootfsMaterializer.Plan("parent", "base", parent.toFile(), listOf(parent.toFile(), base.toFile()))) { false }
        Files.delete(parent.resolve("restricted")); Files.setAttribute(parent, "unix:mode", 0)
        assertThrows(RootfsMaterializeException::class.java) {
            copier.prepare(LinuxRootfsMaterializer.Plan("task", "base", child.toFile(),
                listOf(child.toFile(), parent.toFile(), base.toFile()))) { false }
        }
        assertEquals(0, mode(parent)); assertFalse(Files.exists(child.resolve("restricted")))
        assertFalse(Files.exists(child.resolve(".floe-linux-rootfs-v1")))
    }
}
