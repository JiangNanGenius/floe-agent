// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.*
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardOpenOption.*
import java.nio.file.StandardCopyOption.*
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.util.Properties
import java.util.UUID

/** Original runtime owner must hold exclusive admission and prove UID
 * quiescence before prepare, recovery, commit or rollback. This class owns
 * ONLY guest-root filesystem recovery; it does not execute commands, create
 * environments, authorize a model path or roll back external/workspace effects. */
class LinuxEnvironmentTransaction(
    private val copier: LinuxRootfsMaterializer = LinuxRootfsMaterializer(),
    private val maxBytes: Long = 4L * 1024 * 1024 * 1024,
    private val maxEntries: Int = 250_000,
    private val availableSpace: (File) -> Long = { it.usableSpace },
) {
    class Handle internal constructor(internal val root: Path, internal val record: Properties) {
        val id: String get() = record.getProperty("nonce")
        val environmentID: String get() = record.getProperty("environment")
        val snapshotBytes: Long get() = record.getProperty("bytes").toLong()
        @Volatile internal var terminal: Receipt? = null
    }
    enum class Outcome { COMMITTED, ROLLED_BACK }
    data class Receipt(val id: String, val outcome: Outcome, val snapshotBytes: Long)
    private data class Image(val digest: String, val bytes: Long)
    private val marker = ".floe-linux-rootfs-v1"
    private fun journal(root: Path) = root.parent.resolve(".floe-package-${root.fileName}.journal")
    private fun snapshot(root: Path, record: Properties) = root.parent.resolve(".floe-package-${record.getProperty("nonce")}.snapshot")
    private fun failed(root: Path, record: Properties) = root.parent.resolve(".floe-package-${record.getProperty("nonce")}.failed")
    private fun key(path: Path): String {
        val attrs = Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        require(attrs.isDirectory && !attrs.isSymbolicLink)
        return requireNotNull(attrs.fileKey()).toString().also { require(it.length in 1..160) }
    }
    private fun trusted(path: Path) {
        require(path.isAbsolute && path == path.normalize() && path.parent != null)
        var cursor = path.root
        for (part in path) { cursor = cursor.resolve(part); key(cursor) }
    }
    private fun readProperties(path: Path): Properties {
        require(Files.isRegularFile(path, NOFOLLOW_LINKS) && Files.size(path) in 1..8192)
        return Properties().apply { Files.newInputStream(path, NOFOLLOW_LINKS).use { load(it) } }
    }
    private fun markerMatches(root: Path, environmentID: String) =
        readProperties(root.resolve(marker)).getProperty("environment") == environmentID
    private fun markerDigest(root: Path): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileChannel.open(root.resolve(marker), READ, NOFOLLOW_LINKS).use { input ->
            require(input.size() in 1..2048)
            val bytes = ByteBuffer.allocate(2049)
            var total = 0
            while (true) {
                bytes.clear(); val count = input.read(bytes)
                if (count < 0) break
                total += count; require(total <= 2048)
                bytes.flip(); digest.update(bytes)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    private fun forceDirectory(path: Path) { FileChannel.open(path, READ, NOFOLLOW_LINKS).use { it.force(true) } }
    private fun publishRecord(path: Path, value: Properties, initial: Boolean = false) {
        val temporary = path.resolveSibling(path.fileName.toString() + "." + UUID.randomUUID() + ".writing")
        var created = false
        try {
            FileChannel.open(temporary, CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { channel ->
                created = true
                val bytes = java.io.ByteArrayOutputStream().apply { value.store(this, null) }.toByteArray()
                require(bytes.size <= 8192)
                val data = ByteBuffer.wrap(bytes)
                while (data.hasRemaining()) channel.write(data)
                channel.force(true)
            }
            if (initial) require(!Files.exists(path, NOFOLLOW_LINKS))
            else require(Files.isRegularFile(path, NOFOLLOW_LINKS))
            Files.move(temporary, path, ATOMIC_MOVE, REPLACE_EXISTING)
            created = false
            forceDirectory(path.parent)
        } finally { if (created) Files.deleteIfExists(temporary) }
    }
    private fun move(from: Path, to: Path) {
        require(!Files.exists(to, NOFOLLOW_LINKS))
        Files.move(from, to, ATOMIC_MOVE)
        forceDirectory(from.parent)
    }
    private fun validate(root: Path, record: Properties) {
        trusted(root.parent)
        require(record.stringPropertyNames() == setOf("schema", "nonce", "environment", "root", "rootKey", "snapshotKey", "phase", "digest", "markerDigest", "bytes"))
        require(record.getProperty("digest")?.matches(Regex("[0-9a-f]{64}")) == true)
        require(record.getProperty("markerDigest")?.matches(Regex("[0-9a-f]{64}")) == true)
        require(record.getProperty("bytes")?.toLongOrNull()?.let { it in 0..maxBytes } == true)
        require(record.getProperty("schema") == "1")
        require(record.getProperty("root") == root.fileName.toString())
        require(root.fileName.toString().matches(Regex("[A-Za-z0-9_-]{1,128}")))
        val env = record.getProperty("environment")
        require(env != null && env.matches(Regex("[A-Za-z0-9_-]{1,128}")))
        val nonce = record.getProperty("nonce")
        require(UUID.fromString(nonce).toString() == nonce)
        require(record.getProperty("phase") in setOf("copying", "prepared", "rollback", "committed", "rolledBack"))
        require(record.getProperty("rootKey")?.length in 1..160)
        require(record.getProperty("snapshotKey")?.length in 1..160)
        require(record.getProperty("rootKey") != record.getProperty("snapshotKey"))
    }

    /** Snapshot bytes never share a writable inode with the source root.
     *
     * Snapshot failures carry bounded stage codes without exposing paths.
     * Lifecycle
     * cancellation stays an honest InterruptedException; the copier's own
     * RootfsMaterializeException vocabulary passes through untouched. */
    @Synchronized fun prepare(environmentID: String, writableLayer: File,
        cancelled: () -> Boolean): Handle {
        val root = writableLayer.toPath()
        trusted(root)
        require(environmentID.matches(Regex("[A-Za-z0-9_-]{1,128}")))
        require(markerMatches(root, environmentID))
        if (Files.exists(journal(root), NOFOLLOW_LINKS)) {
            // Was an untyped require: the durable journal names the recovery
            // obligation, so a refused prepare is now an actionable stage.
            throw environmentTransactionFailure(EnvironmentTransactionException.CODE_TRANSACTION_JOURNAL_PRESENT)
        }
        if (cancelled()) throw InterruptedException("Environment transaction cancelled")
        val beforeSnapshot = try {
            imageNodes(root, cancelled)
        } catch (cancel: InterruptedException) {
            throw cancel
        } catch (typed: RootfsMaterializeException) {
            throw typed
        } catch (failure: Exception) {
            // Raw open/read/attribute errors while hashing the live layer
            // used to escape untyped; keep the original as cause (debugger
            // only) and publish the bounded stage instead.
            throw environmentTransactionFailure(
                EnvironmentTransactionException.CODE_TRANSACTION_IMAGE_IO, cause = failure)
        }
        val before = beforeSnapshot.first
        // Android rejects getFileStore even for an app-owned directory.
        // File.usableSpace keeps the same fail-closed snapshot headroom.
        val freeBytes = try {
            availableSpace(root.toFile())
        } catch (cancel: InterruptedException) {
            throw cancel
        } catch (failure: Exception) {
            throw environmentTransactionFailure(
                EnvironmentTransactionException.CODE_TRANSACTION_IMAGE_IO, cause = failure)
        }
        if (freeBytes < before.bytes + 64L * 1024 * 1024) {
            throw environmentTransactionFailure(EnvironmentTransactionException.CODE_TRANSACTION_INSUFFICIENT_SPACE)
        }
        val record = Properties().apply {
            setProperty("schema", "1"); setProperty("nonce", UUID.randomUUID().toString())
            setProperty("environment", environmentID); setProperty("root", root.fileName.toString())
            setProperty("rootKey", key(root)); setProperty("phase", "copying")
            setProperty("digest", before.digest); setProperty("bytes", before.bytes.toString())
            setProperty("markerDigest", markerDigest(root))
        }
        val copy = snapshot(root, record)
        try {
            Files.createDirectory(copy)
            record.setProperty("snapshotKey", key(copy))
        } catch (failure: Exception) {
            throw environmentTransactionFailure(
                EnvironmentTransactionException.CODE_TRANSACTION_SNAPSHOT_COPY_IO, cause = failure)
        }
        var recorded = false
        try {
            try {
                publishRecord(journal(root), record, initial = true)
            } catch (failure: Exception) {
                throw environmentTransactionFailure(
                    EnvironmentTransactionException.CODE_TRANSACTION_PUBLISH_IO, cause = failure)
            }
            recorded = true
            try {
                copier.copyTransactionSnapshot(root.toFile(), copy, cancelled)
            } catch (cancel: InterruptedException) {
                throw cancel
            } catch (typed: RootfsMaterializeException) {
                // The copier's own reviewed vocabulary (copy IO/budgets and
                // friends) is already actionable; never re-wrap it.
                throw typed
            } catch (failure: Exception) {
                // Marker copy, timestamp/mode restore, the durability barrier
                // and the closing directory fsync threw raw; type the stage.
                throw environmentTransactionFailure(
                    EnvironmentTransactionException.CODE_TRANSACTION_SNAPSHOT_COPY_IO, cause = failure)
            }
            try {
                require(key(root) == record.getProperty("rootKey") && markerMatches(root, environmentID))
            } catch (failure: Exception) {
                throw environmentTransactionFailure(
                    EnvironmentTransactionException.CODE_TRANSACTION_IDENTITY_CHANGED, cause = failure)
            }
            val copySnapshot = try {
                imageNodes(copy, cancelled)
            } catch (cancel: InterruptedException) {
                throw cancel
            } catch (failure: Exception) {
                throw environmentTransactionFailure(
                    EnvironmentTransactionException.CODE_TRANSACTION_IMAGE_IO, cause = failure)
            }
            val liveSnapshot = try {
                imageNodes(root, cancelled)
            } catch (cancel: InterruptedException) {
                throw cancel
            } catch (failure: Exception) {
                throw environmentTransactionFailure(
                    EnvironmentTransactionException.CODE_TRANSACTION_IMAGE_IO, cause = failure)
            }
            if (copySnapshot.first != before || liveSnapshot.first != before) {
                // Was the untyped "Environment changed during snapshot" require:
                // report the bounded divergence axis (never a path) so the
                // device follow-up can tell metadata restore loss from real
                // guest mutation. Both comparisons run so the classifier sees
                // the dominant axis across copy and live re-read.
                val detail = divergence(beforeSnapshot.second, copySnapshot.second, liveSnapshot.second)
                throw environmentTransactionFailure(
                    EnvironmentTransactionException.CODE_TRANSACTION_SNAPSHOT_VERIFY_CHANGED, detail = detail)
            }
            record.setProperty("phase", "prepared")
            try {
                publishRecord(journal(root), record)
            } catch (failure: Exception) {
                throw environmentTransactionFailure(
                    EnvironmentTransactionException.CODE_TRANSACTION_PUBLISH_IO, cause = failure)
            }
            return Handle(root, record)
        } catch (failure: Throwable) {
            // No command has started. An uncertain durable publication stays
            // recoverable; never erase its only snapshot after a sync failure.
            // The cleanup is best-effort: it must NEVER mask the original
            // typed failure (a masked stage would reproduce exactly the
            // generic-receipt diagnosability gap this change closes).
            if (!recorded && !Files.exists(journal(root), NOFOLLOW_LINKS)) {
                runCatching {
                    if (Files.exists(copy, NOFOLLOW_LINKS) && key(copy) == record.getProperty("snapshotKey")) copier.removeTransactionTree(copy)
                }.onFailure { failure.addSuppressed(it) }
            }
            throw failure
        }
    }

    /** Call only after actual process quiescence. A failure retains the
     * journal/snapshot and therefore the original runtime ownership fence. */
    @Synchronized fun finish(handle: Handle, success: Boolean): Receipt {
        handle.terminal?.let { return it }
        val root = handle.root
        val record = readProperties(journal(root))
        validate(root, record)
        require(record.getProperty("nonce") == handle.id && record.getProperty("digest") == handle.record.getProperty("digest"))
        val phase = record.getProperty("phase")
        if (phase == "prepared" && success) {
            require(key(root) == record.getProperty("rootKey"))
            // A command cannot commit a guest with a missing/foreign identity
            // marker. Restore its saved state rather than release it as ready.
            if (runCatching { markerMatches(root, handle.environmentID) && markerDigest(root) == record.getProperty("markerDigest") }.getOrDefault(false)) {
                record.setProperty("phase", "committed")
                publishRecord(journal(root), record)
            }
        }
        val outcome = settle(root, record)
        return Receipt(handle.id, outcome, handle.snapshotBytes).also { handle.terminal = it }
    }

    /** Only after original native lease hand-back. A terminal receipt remains
     * durable until then, so a lost acknowledgement cannot replay a mutation. */
    @Synchronized fun release(handle: Handle) {
        require(handle.terminal != null)
        removeTerminalJournal(handle.root, handle.record)
    }
    private fun removeTerminalJournal(root: Path, expected: Properties) {
        if (!Files.exists(journal(root), NOFOLLOW_LINKS)) return
        val current = readProperties(journal(root))
        validate(root, current)
        require(current.getProperty("nonce") == expected.getProperty("nonce"))
        require(current.getProperty("phase") in setOf("committed", "rolledBack"))
        Files.delete(journal(root)); forceDirectory(root.parent)
    }

    /** Original boot/UID recovery calls this BEFORE registry acquisition or
     * new guest execution. It never replays an interrupted command. */
    @Synchronized fun recover(containers: File): Int {
        val parent = containers.toPath()
        if (!Files.exists(parent, NOFOLLOW_LINKS)) return 0
        trusted(parent)
        var count = 0
        Files.newDirectoryStream(parent, ".floe-package-*.journal").use { files ->
            for (file in files) {
                require(++count <= 1024)
                val record = readProperties(file)
                val name = record.getProperty("root")
                require(name != null && name.matches(Regex("[A-Za-z0-9_-]{1,128}")))
                val root = parent.resolve(name)
                validate(root, record)
                require(file == journal(root))
                settle(root, record)
                removeTerminalJournal(root, record)
            }
        }
        return count
    }
    private fun settle(root: Path, record: Properties): Outcome {
        validate(root, record)
        val copy = snapshot(root, record)
        val old = failed(root, record)
        var phase = record.getProperty("phase")
        if (phase == "copying") {
            require(key(root) == record.getProperty("rootKey") && markerMatches(root, record.getProperty("environment")))
            removeOwned(copy, record.getProperty("snapshotKey"))
            Files.delete(journal(root)); forceDirectory(root.parent)
            return Outcome.ROLLED_BACK // no command could have started
        }
        if (phase == "prepared") {
            require(key(root) == record.getProperty("rootKey"))
            require(key(copy) == record.getProperty("snapshotKey"))
            require(image(copy) == Image(record.getProperty("digest"), record.getProperty("bytes").toLong()))
            record.setProperty("phase", "rollback")
            publishRecord(journal(root), record)
            phase = "rollback"
        }
        if (phase == "rollback") {
            if (Files.exists(root, NOFOLLOW_LINKS) && key(root) == record.getProperty("rootKey")) {
                require(!Files.exists(old, NOFOLLOW_LINKS))
                require(key(copy) == record.getProperty("snapshotKey"))
                require(image(copy) == Image(record.getProperty("digest"), record.getProperty("bytes").toLong()))
                move(root, old)
            }
            if (!Files.exists(root, NOFOLLOW_LINKS)) {
                require(key(old) == record.getProperty("rootKey") && key(copy) == record.getProperty("snapshotKey"))
                move(copy, root)
            }
            require(key(root) == record.getProperty("snapshotKey")) { "Environment rollback identity is unknown" }
            require(markerMatches(root, record.getProperty("environment")))
            require(image(root) == Image(record.getProperty("digest"), record.getProperty("bytes").toLong()))
            record.setProperty("phase", "rolledBack")
            publishRecord(journal(root), record)
            phase = "rolledBack"
        }
        if (phase == "rolledBack") {
            require(key(root) == record.getProperty("snapshotKey"))
            removeOwned(old, record.getProperty("rootKey"))
        } else {
            require(phase == "committed" && key(root) == record.getProperty("rootKey"))
            removeOwned(copy, record.getProperty("snapshotKey"))
        }
        // The actual running owner removes this terminal journal only after
        // native authority release; recovery removes it before new admission.
        return if (phase == "committed") Outcome.COMMITTED else Outcome.ROLLED_BACK
    }
    private fun removeOwned(path: Path, expected: String) {
        if (!Files.exists(path, NOFOLLOW_LINKS)) return
        require(key(path) == expected) { "Recovery directory was replaced" }
        copier.removeTransactionTree(path)
        forceDirectory(path.parent)
    }

    private data class Node(val path: String, val kind: String, val mode: Int, val modified: Long,
        val content: String, val inode: String?)
    /** Walks and hashes one tree; returns the digest plus the sorted node
     *  list so the verify stage can classify a divergence axis without a
     *  second walk. */
    private fun imageNodes(root: Path, cancelled: () -> Boolean = { false }): Pair<Image, List<Node>> {
        trusted(root)
        copier.recoverSourcePermissions(root)
        val access = copier.sourceAccess(root)
        val nodes = ArrayList<Node>()
        val fileHashes = HashMap<String, String>()
        var bytes = 0L
        fun mode(path: Path) = access?.originalMode(path) ?: ((Files.getAttribute(path, "unix:mode", NOFOLLOW_LINKS) as Int) and 0xFFF)
        val visitor = object : SimpleFileVisitor<Path>() {
            fun entry(path: Path, attrs: BasicFileAttributes, directory: Boolean) {
                if (cancelled()) throw InterruptedException("Environment snapshot cancelled")
                require(nodes.size < maxEntries)
                val relative = root.relativize(path).toString()
                require(relative.toByteArray().size <= 4096)
                var inode: String? = null
                val kind: String
                val content: String
                when {
                    directory -> { kind = "directory"; content = "" }
                    attrs.isSymbolicLink -> { kind = "symlink"; content = Files.readSymbolicLink(path).toString(); require(content.toByteArray().size <= 4096) }
                    attrs.isRegularFile -> {
                        kind = "file"; inode = requireNotNull(attrs.fileKey()).toString()
                        content = fileHashes[inode] ?: run {
                            require(attrs.size() <= maxBytes - bytes)
                            val hash = MessageDigest.getInstance("SHA-256")
                            var size = 0L
                            (access?.open(path) ?: FileChannel.open(path, READ, NOFOLLOW_LINKS)).use { input ->
                                val buffer = ByteBuffer.allocate(64 * 1024)
                                while (true) {
                                    if (cancelled()) throw InterruptedException("Environment snapshot cancelled")
                                    buffer.clear(); val count = input.read(buffer)
                                    if (count < 0) break
                                    require(count.toLong() <= maxBytes - bytes)
                                    bytes += count; size += count; buffer.flip(); hash.update(buffer)
                                }
                            }
                            val after = Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
                            require(size == attrs.size() && after.fileKey() == attrs.fileKey() && after.size() == attrs.size() && after.lastModifiedTime() == attrs.lastModifiedTime())
                            hash.digest().joinToString("") { "%02x".format(it) }.also { fileHashes[inode] = it }
                        }
                    }
                    else -> {
                        // Guest runtime endpoints (sockets/FIFOs) are ephemeral
                        // rendezvous artifacts with no durable bytes; they are
                        // excluded from the transaction image exactly as the
                        // copier skips them, so a daemon's socket appearing
                        // or vanishing mid-transaction never masquerades as
                        // an environment content change. Anything else is a
                        // typed refusal, never silently hashed.
                        if (isGuestRuntimeEndpoint(path, attrs)) {
                            return@entry
                        }
                        throw RootfsMaterializeException(
                            RootfsMaterializeException.CODE_ROOTFS_SNAPSHOT_UNSUPPORTED)
                    }
                }
                nodes += Node(relative, kind, mode(path),
                    if (attrs.isSymbolicLink) 0L else attrs.lastModifiedTime().toMillis(), content, inode)
            }
            override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult { entry(dir, attrs, true); return FileVisitResult.CONTINUE }
            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult { entry(file, attrs, false); return FileVisitResult.CONTINUE }
        }
        if (access != null) access.walk(visitor) else Files.walkFileTree(root, visitor)
        return digest(nodes, bytes) to nodes.sortedBy { it.path }
    }

    private fun image(root: Path, cancelled: () -> Boolean = { false }): Image =
        imageNodes(root, cancelled).first

    /** The exact hard-link projection used by the digest: the first sorted
     *  path an inode appears at links the rest. Exposed so the verify
     *  divergence classifier compares the same values the digest compares. */
    private fun linkValues(ordered: List<Node>): List<String> {
        val linkNames = HashMap<String, String>()
        return ordered.map { node ->
            node.inode?.let { linkNames.getOrPut(it) { node.path } } ?: ""
        }
    }

    private fun digest(nodes: List<Node>, bytes: Long): Image {
        val ordered = nodes.sortedBy { it.path }
        val links = linkValues(ordered)
        val hash = MessageDigest.getInstance("SHA-256")
        for ((index, node) in ordered.withIndex()) {
            for (value in listOf(node.path, node.kind, node.mode.toString(), node.modified.toString(), node.content, links[index])) {
                val data = value.toByteArray(Charsets.UTF_8)
                hash.update(ByteBuffer.allocate(4).putInt(data.size).array()); hash.update(data)
            }
        }
        return Image(hash.digest().joinToString("") { "%02x".format(it) }, bytes)
    }

    /** Bounded snapshot-divergence axis for the verify stage. Compares the
     *  pre-copy node list against the copied snapshot and the live re-read and
     *  reports the FIRST differing axis only — a closed token, never a path,
     *  name, inode or content. Structural (path-set) differences report
     *  "structure"; a pure byte-total difference with identical node metadata
     *  reports "bytes". */
    private fun divergence(expected: List<Node>, copyNodes: List<Node>,
        liveNodes: List<Node>): String {
        fun classOf(actual: List<Node>): String? {
            if (actual.size != expected.size) return "entries"
            val actualLinks = linkValues(actual)
            val expectedLinks = linkValues(expected)
            for (index in actual.indices) {
                val want = expected[index]
                val got = actual[index]
                if (want.path != got.path) return "structure"
                if (want.kind != got.kind) return "kind"
                if (want.mode != got.mode) return "mode"
                // Content precedes modified: a real guest mutation changes
                // both, while a snapshot-metadata restore loss changes
                // modified alone — this order tells the two apart.
                if (want.content != got.content) return "content"
                if (want.modified != got.modified) return "modified"
                if (expectedLinks[index] != actualLinks[index]) return "link"
            }
            return null
        }
        return classOf(copyNodes) ?: classOf(liveNodes) ?: "bytes"
    }
}
