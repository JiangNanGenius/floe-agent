// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.*
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import java.nio.file.StandardOpenOption.*
import java.nio.file.attribute.BasicFileAttributes
import java.util.Properties
import java.util.UUID

/** Internal copy/snapshot access under the original runtime lease. Borrow only
 * owner-read (files) or owner-read/search (directories), restoring exact modes.
 * One durable ledger ABOVE the guest root orders nested and file recovery.
 * The caller must exclude live guest work before any source mode mutation. */
internal class RootfsOwnedSourceAccess(
    private val root: Path,
    private val ownerUid: Int,
    private val mayChangePermissions: () -> Boolean = { true },
    private val opener: (Path) -> FileChannel = { FileChannel.open(it, READ, NOFOLLOW_LINKS) },
) {
    private data class Entry(val path: Path, val key: String, val original: Int, val directory: Boolean) {
        val added: Int get() = if (directory) 0x140 else 0x100
    }
    internal val journal: Path = root.parent.resolve(".floe-read-mode-${root.fileName}.journal")
    private val rootKey = identity(root)
    private var entries = emptyList<Entry>()
    private var walking = false
    private fun refuse(): Nothing = throw IOException("Owned source access could not be verified")
    private fun requireSafe(value: Boolean) { if (!value) refuse() }
    private fun attributes(path: Path) = Files.readAttributes(path, "unix:mode,uid", NOFOLLOW_LINKS)
    private fun mode(path: Path) = (attributes(path)["mode"] as Number).toInt() and 0xFFF
    private fun owned(path: Path) = (attributes(path)["uid"] as Number).toInt() == ownerUid
    private fun directory(path: Path) = Files.isDirectory(path, NOFOLLOW_LINKS) && !Files.isSymbolicLink(path)
    private fun identity(path: Path): String = Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        .fileKey()?.toString()?.takeIf { it.length in 1..160 } ?: refuse()
    private fun checkRoot() {
        requireSafe(ownerUid >= 0 && root.isAbsolute && root == root.normalize() && root.parent != null)
        requireSafe(root.fileName.toString().matches(Regex("[A-Za-z0-9._-]{1,160}")))
        var cursor = root.root
        for (part in root) { cursor = cursor.resolve(part); requireSafe(directory(cursor)) }
        requireSafe(owned(root) && owned(root.parent))
        requireSafe(identity(root) == rootKey)
    }
    private fun checkPath(path: Path, isDirectory: Boolean) {
        checkRoot()
        requireSafe(path.startsWith(root) && path == path.normalize() && (path != root || isDirectory))
        var cursor = root
        if (path != root) for (part in root.relativize(path.parent)) {
            cursor = cursor.resolve(part); requireSafe(directory(cursor))
        }
        requireSafe(!Files.isSymbolicLink(path) && owned(path))
        requireSafe(if (isDirectory) directory(path) else Files.isRegularFile(path, NOFOLLOW_LINKS))
    }
    private fun validate(entry: Entry) {
        checkPath(entry.path, entry.directory)
        requireSafe(identity(entry.path) == entry.key)
        requireSafe(entry.original in 0..0xFFF && entry.original and entry.added != entry.added)
        requireSafe(mode(entry.path) in setOf(entry.original, entry.original or entry.added))
    }
    private fun idle(entry: Entry) {
        if (!mayChangePermissions()) throw RootfsMaterializeException(
            RootfsMaterializeException.CODE_ROOTFS_SOURCE_BUSY, operation = if (entry.directory) "walk" else "open_input",
            sourceMode = entry.original, sourceOwnerUid = ownerUid, sourceIsDirectory = entry.directory)
    }
    private fun forceParent() { FileChannel.open(root.parent, READ, NOFOLLOW_LINKS).use { it.force(true) } }

    private fun save(next: List<Entry>) {
        requireSafe(next.size <= 1024)
        if (next.isEmpty()) {
            Files.deleteIfExists(journal); forceParent(); entries = next; return
        }
        val value = Properties().apply {
            setProperty("version", "2"); setProperty("rootKey", rootKey); setProperty("uid", ownerUid.toString())
            setProperty("count", next.size.toString())
            next.forEachIndexed { i, e ->
                setProperty("$i.relative", root.relativize(e.path).toString()); setProperty("$i.key", e.key)
                setProperty("$i.mode", e.original.toString()); setProperty("$i.kind", if (e.directory) "d" else "f")
            }
        }
        val data = java.io.ByteArrayOutputStream().apply { value.store(this, null) }.toByteArray()
        requireSafe(data.size <= 8 * 1024 * 1024)
        val temporary = journal.resolveSibling(journal.fileName.toString() + "." + UUID.randomUUID() + ".writing")
        try {
            FileChannel.open(temporary, CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { output ->
                val bytes = ByteBuffer.wrap(data)
                while (bytes.hasRemaining()) output.write(bytes)
                output.force(true)
            }
            Files.move(temporary, journal, ATOMIC_MOVE, REPLACE_EXISTING)
            forceParent()
            entries = next
        } finally { Files.deleteIfExists(temporary) }
    }

    private fun load(): List<Entry> {
        checkRoot()
        requireSafe(Files.isRegularFile(journal, NOFOLLOW_LINKS) && owned(journal) && Files.size(journal) in 1..(8 * 1024 * 1024))
        val value = Properties()
        try { Files.newInputStream(journal, NOFOLLOW_LINKS).use { value.load(it) } }
        catch (bad: IllegalArgumentException) { throw IOException("Invalid source recovery record", bad) }
        requireSafe(value.getProperty("rootKey") == rootKey && value.getProperty("uid") == ownerUid.toString())
        val version = value.getProperty("version")
        requireSafe(version == "1" || version == "2")
        val count = if (version == "1") 1 else value.getProperty("count")?.toIntOrNull() ?: refuse()
        requireSafe(count in 1..1024)
        return (0 until count).map { i ->
            val prefix = if (version == "1") "" else "$i."
            val kind = if (version == "1") "f" else value.getProperty(prefix + "kind")
            requireSafe(kind == "f" || kind == "d")
            val text = value.getProperty(prefix + "relative") ?: refuse()
            requireSafe(text.toByteArray(Charsets.UTF_8).size <= 4096 && '\u0000' !in text && (text.isNotEmpty() || kind == "d"))
            val relative = root.fileSystem.getPath(text)
            requireSafe(!relative.isAbsolute && relative == relative.normalize() && relative.none { it.toString() in setOf(".", "..") })
            val path = root.resolve(relative)
            val key = value.getProperty(prefix + "key")?.takeIf { it.length in 1..160 } ?: refuse()
            val original = value.getProperty(prefix + "mode")?.toIntOrNull() ?: refuse()
            Entry(path, key, original, kind == "d").also {
                requireSafe(original in 0..0xFFF && original and it.added != it.added)
            }
        }.also { requireSafe(it.map { e -> e.path }.distinct().size == it.size) }
    }

    /** The path form avoids Android's READ-before-NOFOLLOW-chmod. Real-parent,
     * inode/type/owner checks and the original exclusive lease fence it. */
    private fun setMode(entry: Entry, value: Int) {
        validate(entry)
        Files.setAttribute(entry.path, "unix:mode", value)
        requireSafe(identity(entry.path) == entry.key && mode(entry.path) == value)
    }
    private fun begin(path: Path, isDirectory: Boolean): Entry {
        checkPath(path, isDirectory)
        requireSafe(entries.none { it.path == path })
        val entry = Entry(path, identity(path), mode(path), isDirectory)
        validate(entry); idle(entry)
        save(entries + entry)
        setMode(entry, entry.original or entry.added)
        return entry
    }
    internal fun beginRead(file: Path) {
        if (entries.isEmpty() && !walking) recover()
        begin(file, false)
    }
    internal fun beginDirectory(path: Path) {
        if (entries.isEmpty() && !walking) recover()
        begin(path, true)
    }
    fun originalMode(path: Path): Int = entries.firstOrNull { it.path == path }?.original ?: mode(path)
    private fun restore(entry: Entry, channel: FileChannel, retire: Boolean = true) {
        setMode(entry, entry.original)
        channel.force(true)
        if (retire) save(entries - entry)
    }
    private fun restoreDirectory(entry: Entry, retire: Boolean = true) {
        validate(entry)
        if (mode(entry.path) == entry.original) setMode(entry, entry.original or entry.added)
        FileChannel.open(entry.path, READ, NOFOLLOW_LINKS).use { restore(entry, it, retire) }
    }

    /** Activate ancestors top-down, restore files, then directories bottom-up.
     * On refusal keep ancestor records so a later valid recovery can reach a
     * repaired child; undo any activation without retiring those records. */
    private fun restoreOutstanding() {
        if (!Files.exists(journal, NOFOLLOW_LINKS)) { entries = emptyList(); return }
        entries = load()
        val directories = entries.filter { it.directory }.sortedBy { it.path.nameCount }
        val activated = mutableListOf<Entry>()
        try {
            for (e in directories) {
                validate(e)
                if (mode(e.path) == e.original) setMode(e, e.original or e.added)
                activated += e
            }
            for (e in entries.filterNot { it.directory }.toList()) {
                validate(e)
                if (mode(e.path) == e.original) setMode(e, e.original or e.added)
                opener(e.path).use { restore(e, it) }
            }
            for (e in directories.asReversed()) restoreDirectory(e)
        } catch (failure: Throwable) {
            for (e in activated.asReversed()) if (entries.any { it.path == e.path }) {
                try { restoreDirectory(e, retire = false) }
                catch (restore: Throwable) { failure.addSuppressed(restore) }
            }
            throw failure
        }
    }
    fun recover() {
        if (!Files.exists(journal, NOFOLLOW_LINKS)) return
        if (!mayChangePermissions()) throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_SOURCE_BUSY)
        restoreOutstanding()
    }

    fun open(file: Path): FileChannel {
        if (!walking) recover()
        try { return opener(file) }
        catch (denied: AccessDeniedException) {
            try {
                beginRead(file)
                val entry = entries.first { it.path == file }
                val channel = opener(file)
                try { restore(entry, channel); return channel }
                catch (failure: Throwable) {
                    try { channel.close() } catch (close: Throwable) { failure.addSuppressed(close) }
                    throw failure
                }
            } catch (failure: Throwable) {
                val fileEntry = entries.firstOrNull { !it.directory && it.path == file }
                try {
                    if (walking && fileEntry != null) {
                        validate(fileEntry)
                        if (mode(file) == fileEntry.original) setMode(fileEntry, fileEntry.original or fileEntry.added)
                        opener(file).use { restore(fileEntry, it) }
                    } else if (!walking) restoreOutstanding()
                } catch (recovery: Throwable) { recovery.addSuppressed(failure); throw recovery }
                throw failure
            }
        }
    }

    /** Streams open BEFORE preVisitDirectory. Retry only an owned directory
     * missing owner r/x; also lend search at preVisit for r-without-x. The same
     * walker handles already-owned disposable trees without restoring nodes
     * that deletion has just removed. Never use deleting for a source tree. */
    fun walk(visitor: FileVisitor<Path>, deleting: Boolean = false) {
        // A disposable subtree's parent may itself be guest data. Its sibling
        // files must never be interpreted as service recovery authority.
        if (!deleting) recover()
        checkRoot(); requireSafe(!walking); walking = true
        var terminated = false
        val nestedRoots = mutableSetOf<Path>()
        val skipSiblings = mutableSetOf<Path>()
        fun result(path: Path, value: FileVisitResult): FileVisitResult {
            if (value == FileVisitResult.TERMINATE) terminated = true
            if (path in nestedRoots && value == FileVisitResult.SKIP_SIBLINGS) skipSiblings.add(path)
            return value
        }
        fun prepareDirectory(path: Path) {
            if (deleting) {
                checkPath(path, true)
                if (mode(path) != 0x1C0) Files.setAttribute(path, "unix:mode", 0x1C0)
            } else if (mode(path) and 0x140 != 0x140 && entries.none { it.path == path }) begin(path, true)
        }
        fun closeDirectory(path: Path) {
            if (!deleting) entries.firstOrNull { it.directory && it.path == path }?.let { restoreDirectory(it) }
        }
        val wrapper = object : FileVisitor<Path> {
            override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
                prepareDirectory(dir)
                val value = result(dir, visitor.preVisitDirectory(dir, attrs))
                if (value != FileVisitResult.CONTINUE) closeDirectory(dir)
                return value
            }
            override fun visitFile(file: Path, attrs: BasicFileAttributes) = result(file, visitor.visitFile(file, attrs))
            override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult {
                var failure: Throwable? = null
                try { return result(dir, visitor.postVisitDirectory(dir, exc)) }
                catch (caught: Throwable) { failure = caught; throw caught }
                finally {
                    try { closeDirectory(dir) }
                    catch (restore: Throwable) { if (failure != null) failure.addSuppressed(restore) else throw restore }
                }
            }
            override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult {
                if (exc !is AccessDeniedException || !directory(file) || !owned(file) || mode(file) and 0x140 == 0x140)
                    return result(file, visitor.visitFileFailed(file, exc))
                prepareDirectory(file)
                nestedRoots.add(file)
                var failure: Throwable? = null
                try { Files.walkFileTree(file, this) }
                catch (caught: Throwable) { failure = caught; throw caught }
                finally {
                    nestedRoots.remove(file)
                    try { closeDirectory(file) }
                    catch (restore: Throwable) { if (failure != null) failure.addSuppressed(restore) else throw restore }
                }
                return when {
                    terminated -> FileVisitResult.TERMINATE
                    skipSiblings.remove(file) -> FileVisitResult.SKIP_SIBLINGS
                    else -> FileVisitResult.CONTINUE
                }
            }
        }
        var failure: Throwable? = null
        try { Files.walkFileTree(root, wrapper) }
        catch (caught: Throwable) { failure = caught; throw caught }
        finally {
            walking = false
            if (!deleting) try { restoreOutstanding() }
            catch (restore: Throwable) { if (failure != null) failure.addSuppressed(restore) else throw restore }
        }
    }
}
