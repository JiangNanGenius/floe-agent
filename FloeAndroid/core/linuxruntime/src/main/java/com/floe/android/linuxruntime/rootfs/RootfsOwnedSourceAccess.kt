// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.AccessDeniedException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardOpenOption.*
import java.nio.file.attribute.BasicFileAttributes
import java.util.Properties
import java.util.UUID

/** Internal copy/snapshot access under the runtime owner's exclusive, quiescent
 * lease. Guest packages can leave owned mode-000 files that NIO cannot copy.
 * Only an owned regular inode may borrow owner-read, never group/other access.
 * Its mode is restored before returning the open channel. The durable record
 * lives ABOVE the guest root, and survives a process death in that short gap. */
internal class RootfsOwnedSourceAccess(
    private val root: Path,
    private val ownerUid: Int,
    private val opener: (Path) -> FileChannel = { FileChannel.open(it, READ, NOFOLLOW_LINKS) },
) {
    internal val journal: Path = root.parent.resolve(".floe-read-mode-${root.fileName}.journal")

    private fun refuse(): Nothing = throw IOException("Owned source access could not be verified")
    private fun requireSafe(value: Boolean) { if (!value) refuse() }
    private fun identity(path: Path): String {
        val attrs = Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        return attrs.fileKey()?.toString()?.takeIf { it.length in 1..160 } ?: refuse()
    }
    private fun attributes(path: Path) = Files.readAttributes(path, "unix:mode,uid", NOFOLLOW_LINKS)
    private fun mode(path: Path) = ((attributes(path)["mode"] as Number).toInt() and 0xFFF)
    private fun owned(path: Path) = (attributes(path)["uid"] as Number).toInt() == ownerUid
    private fun directory(path: Path) = Files.isDirectory(path, NOFOLLOW_LINKS) && !Files.isSymbolicLink(path)
    private fun checkRoot() {
        requireSafe(ownerUid >= 0 && root.isAbsolute && root == root.normalize() && root.parent != null)
        requireSafe(root.fileName.toString().matches(Regex("[A-Za-z0-9._-]{1,160}")))
        var cursor = root.root
        for (part in root) { cursor = cursor.resolve(part); requireSafe(directory(cursor)) }
        requireSafe(owned(root) && owned(root.parent))
    }
    private fun checkFile(path: Path) {
        checkRoot()
        requireSafe(path != root && path.startsWith(root) && path == path.normalize())
        var cursor = root
        for (part in root.relativize(path.parent)) {
            cursor = cursor.resolve(part); requireSafe(directory(cursor))
        }
        requireSafe(Files.isRegularFile(path, NOFOLLOW_LINKS) && !Files.isSymbolicLink(path) && owned(path))
    }
    private fun forceParent() { FileChannel.open(root.parent, READ, NOFOLLOW_LINKS).use { it.force(true) } }

    private fun publish(record: Properties) {
        requireSafe(!Files.exists(journal, NOFOLLOW_LINKS))
        val temporary = journal.resolveSibling(journal.fileName.toString() + "." + UUID.randomUUID() + ".writing")
        try {
            val bytes = java.io.ByteArrayOutputStream().apply { record.store(this, null) }.toByteArray()
            requireSafe(bytes.size <= 65536)
            FileChannel.open(temporary, CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { output ->
                val data = ByteBuffer.wrap(bytes)
                while (data.hasRemaining()) output.write(data)
                output.force(true)
            }
            Files.move(temporary, journal, ATOMIC_MOVE)
            forceParent() // the recovery record is durable BEFORE chmod
        } finally { Files.deleteIfExists(temporary) }
    }

    private fun record(): Properties {
        checkRoot()
        requireSafe(Files.isRegularFile(journal, NOFOLLOW_LINKS) && owned(journal) && Files.size(journal) in 1..65536)
        return Properties().apply { Files.newInputStream(journal, NOFOLLOW_LINKS).use { load(it) } }
    }
    private fun validate(record: Properties): Pair<Path, Int> {
        checkRoot()
        requireSafe(record.getProperty("version") == "1" && record.getProperty("rootKey") == identity(root))
        requireSafe(record.getProperty("uid") == ownerUid.toString())
        val relativeText = record.getProperty("relative") ?: refuse()
        requireSafe(relativeText.length in 1..4096 && '\u0000' !in relativeText)
        val relative = root.fileSystem.getPath(relativeText)
        requireSafe(!relative.isAbsolute && relative == relative.normalize() && relative.none { it.toString() in setOf(".", "..") })
        val file = root.resolve(relative)
        checkFile(file)
        requireSafe(record.getProperty("key") == identity(file))
        val original = record.getProperty("mode")?.toIntOrNull() ?: refuse()
        requireSafe(original in 0..0xFFF && original and 0x100 == 0)
        requireSafe(mode(file) in setOf(original, original or 0x100))
        return file to original
    }

    /** The checked path is a regular inode inside a quiescent private root.
     * Use chmod's path form: Android's NOFOLLOW attribute setter first opens
     * the file for READ and therefore itself fails on the mode-000 source. */
    private fun setMode(record: Properties, value: Int) {
        val (file, _) = validate(record)
        Files.setAttribute(file, "unix:mode", value)
        requireSafe(identity(file) == record.getProperty("key") && mode(file) == value)
    }

    /** Separate prepare/recover phases also permit real interrupted-journal
     * qualification without changing the production open/restore sequence. */
    internal fun beginRead(file: Path) {
        recover()
        checkFile(file)
        val original = mode(file)
        requireSafe(original and 0x100 == 0)
        val value = Properties().apply {
            setProperty("version", "1"); setProperty("rootKey", identity(root))
            setProperty("uid", ownerUid.toString()); setProperty("relative", root.relativize(file).toString())
            setProperty("key", identity(file)); setProperty("mode", original.toString())
        }
        publish(value)
        setMode(value, original or 0x100)
    }

    private fun finish(value: Properties, channel: FileChannel) {
        val (_, original) = validate(value)
        setMode(value, original)
        channel.force(true) // original inode metadata durable before retiring its record
        Files.delete(journal)
        forceParent()
    }

    fun recover() {
        if (!Files.exists(journal, NOFOLLOW_LINKS)) return
        val value = record()
        val (file, original) = validate(value)
        // Recovery may find the old mode already restored but its record not
        // retired. Reopen under that SAME durable record, then restore again.
        if (mode(file) == original) setMode(value, original or 0x100)
        opener(file).use { finish(value, it) }
    }

    fun open(file: Path): FileChannel {
        try { return opener(file) }
        catch (denied: AccessDeniedException) {
            try {
                beginRead(file)
                val value = record()
                val channel = opener(file)
                try { finish(value, channel); return channel }
                catch (failure: Throwable) {
                    try { channel.close() } catch (close: Throwable) { failure.addSuppressed(close) }
                    throw failure
                }
            } catch (failure: Throwable) {
                try { recover() }
                catch (recovery: Throwable) { recovery.addSuppressed(failure); throw recovery }
                throw failure
            }
        }
    }
}
