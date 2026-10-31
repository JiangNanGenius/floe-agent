// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardOpenOption.*
import java.nio.file.attribute.BasicFileAttributes
import java.util.Properties
import java.util.UUID

/**
 * Materializes a full writable Linux filesystem at the ORIGINAL registry layer
 * path. It does not create/select environment records. It must only be called
 * by the runtime owner while holding the original lease, after UID recovery,
 * with no other runtime workload. Ordered lookup paths alone are not a rootfs.
 *
 * Inheritance is a snapshot at first materialization. An existing full parent
 * is the snapshot anchor (so deleted parent files are not resurrected from the
 * base). Later parent edits need an explicit rebuild; this is not overlayfs.
 */
class LinuxRootfsMaterializer(
    private val maxBytes: Long = 4L * 1024 * 1024 * 1024,
    private val maxEntries: Int = 250_000,
    /**
     * ONE real durability barrier before the marker is written. Production
     * opens the controlled staging directory and calls native syncfs(fd);
     * null keeps the historical per-file `force(true)` for JVM/non-native
     * hosts. The extracted base is 10,206 members (8,014 regular files) / 221,379,155 bytes:
     * fsyncing every regular file plus ~1.2k directory fsyncs serializes the cold copy behind ~9k flush latencies (actual
     * cold runs: 27.4 s, 38.1 s, still copying after 148 s under load). One
     * filesystem barrier preserves the original crash rule — no marker before
     * all bytes/metadata are durable — without that per-file cost.
     */
    private val durabilityBarrier: ((Path) -> Unit)? = null,
    /** Bounded counts/durations only (no paths/IDs); diagnostics for the cold run. */
    private val progress: ((Progress) -> Unit)? = null,
) {
    enum class Phase { COPY, BARRIER, PUBLISHED }
    data class Progress(val phase: Phase, val entries: Long, val bytes: Long, val elapsedMillis: Long)

    data class Plan(
        val environmentId: String,
        val baseRevision: String,
        val writableLayer: File,
        /** Original authority order, writable first and verified base last. */
        val orderedLayers: List<File>,
    )
    data class Result(val rootfs: File, val copiedBytes: Long, val reused: Boolean)

    private val marker = ".floe-linux-rootfs-v1"

    /**
     * Restore a missing registry layer BEFORE Swift prepares/validates its
     * manifest. Otherwise the rename gap could make acquisition fail before
     * prepare() ever gets a chance to recover. Requires prior whole-UID stop.
     * This pass only restores absent paths; it deletes no directory or journal.
     */
    @Synchronized fun restoreMissingLayersBeforeRegistry(containers: File): Int {
        if (!Files.exists(containers.toPath(), NOFOLLOW_LINKS)) return 0
        val directory = trustedRoot(containers)
        var restored = 0
        var entries = 0
        Files.newDirectoryStream(directory, ".floe-rootfs-*.journal").use { journals ->
            for (journal in journals) {
                check(++entries <= 1024) { "Too many unfinished rootfs transactions" }
                require(Files.isRegularFile(journal, NOFOLLOW_LINKS) && Files.size(journal) <= 2048)
                val record = Properties().apply { Files.newInputStream(journal, NOFOLLOW_LINKS).use { load(it) } }
                val id = record.getProperty("environment")
                require(id != null && id.matches(Regex("[A-Za-z0-9_-]{1,128}")))
                require(journal.fileName.toString() == ".floe-rootfs-$id.journal" && record.getProperty("root") == id)
                val nonce = record.getProperty("nonce")
                require(UUID.fromString(nonce).toString() == nonce)
                val target = directory.resolve(id)
                if (!Files.exists(target, NOFOLLOW_LINKS)) {
                    val backup = directory.resolve(".floe-rootfs-$nonce.previous")
                    check(Files.isDirectory(backup, NOFOLLOW_LINKS) && !Files.isSymbolicLink(backup)) {
                        "Rootfs recovery data missing; transaction retained"
                    }
                    atomicMove(backup, target)
                    forceDirectory(directory)
                    restored++
                }
            }
        }
        return restored
    }

    /** No execution may start until this returns; cancellation preserves the old layer. */
    @Synchronized fun prepare(plan: Plan, cancelled: () -> Boolean): Result {
        require(plan.environmentId.matches(Regex("[A-Za-z0-9_-]{1,128}")))
        require(plan.baseRevision.matches(Regex("[A-Za-z0-9._-]{1,160}")))
        // A crash between the two renames can leave the registry path absent.
        // Validate its real parent, then recover before requiring that path.
        val root = plan.writableLayer.toPath().toAbsolutePath().normalize()
        require(plan.writableLayer.isAbsolute && root == plan.writableLayer.toPath())
        trustedRoot(root.parent.toFile())
        val journal = root.parent.resolve(".floe-rootfs-${plan.environmentId}.journal")
        recover(root, journal, plan)
        trustedRoot(plan.writableLayer)
        val layers = plan.orderedLayers.map(::trustedRoot)
        require(layers.size in 2..16 && layers.first() == root && layers.distinct().size == layers.size)
        require(layers.none { it != root && (it.startsWith(root) || root.startsWith(it)) })
        val parent = root.parent
        readMarker(root)?.let {
            check(it.getProperty("environment") == plan.environmentId && it.getProperty("base") == plan.baseRevision) {
                "Existing rootfs needs an explicit rebuild"
            }
            return Result(root.toFile(), 0, true)
        }
        val nonce = UUID.randomUUID().toString()
        val stage = parent.resolve(".floe-rootfs-$nonce.stage")
        val backup = parent.resolve(".floe-rootfs-$nonce.previous")
        val metadata = Properties().apply {
            setProperty("environment", plan.environmentId); setProperty("base", plan.baseRevision)
            setProperty("root", root.fileName.toString()); setProperty("nonce", nonce)
        }
        check(!Files.exists(journal, NOFOLLOW_LINKS))
        Files.createDirectory(stage)
        var published = false
        try {
            // Keep the closest full ancestor intact, including its deletions.
            val anchor = (1 until layers.lastIndex).firstOrNull { index ->
                readMarker(layers[index])?.getProperty("base") == plan.baseRevision
            } ?: layers.lastIndex
            val budget = CopyBudget()
            val startedNanos = System.nanoTime()
            fun report(phase: Phase) {
                val callback = progress ?: return
                val value = Progress(phase, budget.entries.toLong(), budget.bytes,
                    (System.nanoTime() - startedNanos) / 1_000_000)
                try { callback(value) } catch (_: Exception) {
                    // Diagnostics never change preparation; fatal errors still propagate.
                }
            }
            report(Phase.COPY)
            for (index in anchor downTo 0) copyLayer(layers[index], stage, budget, cancelled) {
                report(Phase.COPY)
            }
            report(Phase.COPY)
            if (cancelled()) throw InterruptedException("Rootfs preparation cancelled")
            // Make every copied byte and attribute durable BEFORE the marker
            // can claim a complete stage. A failure/cancel here leaves the
            // unmarked stage unpublished and the original layer intact.
            report(Phase.BARRIER)
            durabilityBarrier?.invoke(stage)
            if (cancelled()) throw InterruptedException("Rootfs preparation cancelled")
            writeProperties(stage.resolve(marker), metadata)
            // Keep directories writable while merging; apply their final
            // inherited modes only after the last layer and marker are ready.
            for ((directory, mode) in budget.directoryModes.entries.sortedByDescending { it.key.nameCount }) {
                // A later layer may have replaced a lower ancestor with a
                // guest link. NOFOLLOW_LINKS on just the last component would
                // still traverse that ancestor and chmod an outside directory.
                if (realDirectoryWithin(stage, directory)) Files.setAttribute(directory, "unix:mode", mode, NOFOLLOW_LINKS)
            }
            forceDirectory(stage)
            // The registry path never changes; the journal owns only these two
            // generated siblings and lets the next owner finish/roll back.
            writeProperties(journal, metadata)
            forceDirectory(parent)
            atomicMove(root, backup)
            forceDirectory(parent)
            try { atomicMove(stage, root); forceDirectory(parent) }
            catch (failure: Exception) {
                if (!Files.exists(root, NOFOLLOW_LINKS)) { atomicMove(backup, root); forceDirectory(parent) }
                throw failure
            }
            published = true
            // Confirm the exact committed marker before pruning the old copy.
            check(readMarker(root)?.getProperty("nonce") == nonce)
            removeTree(backup)
            Files.delete(journal)
            forceDirectory(parent)
            report(Phase.PUBLISHED)
            return Result(root.toFile(), budget.bytes, false)
        } finally {
            // A failed journalled transaction is recovered on the next call.
            // Never delete its only recovery copy or an arbitrary caller path.
            if (!Files.exists(journal, NOFOLLOW_LINKS)) {
                if (Files.exists(stage, NOFOLLOW_LINKS)) removeTree(stage)
            } else if (!published && Files.exists(root, NOFOLLOW_LINKS) && !Files.exists(backup, NOFOLLOW_LINKS)) {
                if (Files.exists(stage, NOFOLLOW_LINKS)) removeTree(stage)
                Files.delete(journal)
                forceDirectory(parent)
            }
        }
    }

    private fun trustedRoot(file: File): Path {
        val path = file.toPath().toAbsolutePath().normalize()
        require(file.isAbsolute && path == file.toPath() && path.parent != null)
        // Every component is a real directory. Guest symlinks INSIDE it are
        // copied literally and are never followed by the host copier.
        var cursor = path.root
        for (part in path) {
            cursor = cursor.resolve(part)
            require(Files.isDirectory(cursor, NOFOLLOW_LINKS) && !Files.isSymbolicLink(cursor))
        }
        return path
    }

    private fun readMarker(root: Path): Properties? {
        val path = root.resolve(marker)
        if (!Files.exists(path, NOFOLLOW_LINKS)) return null
        require(Files.isRegularFile(path, NOFOLLOW_LINKS) && Files.size(path) <= 2048)
        return Properties().apply { Files.newInputStream(path, NOFOLLOW_LINKS).use { load(it) } }
    }

    private inner class CopyBudget {
        var bytes = 0L
        var entries = 0
        val directoryModes = mutableMapOf<Path, Int>()
    }

    private fun copyLayer(source: Path, stage: Path, budget: CopyBudget,
                          cancelled: () -> Boolean, onCopyProgress: () -> Unit) {
        Files.walkFileTree(source, object : SimpleFileVisitor<Path>() {
            private fun destination(path: Path): Path {
                if (cancelled()) throw InterruptedException("Rootfs preparation cancelled")
                check(++budget.entries <= maxEntries) { "Rootfs entry budget exceeded" }
                val relative = source.relativize(path)
                val output = stage.resolve(relative).normalize()
                check(output.startsWith(stage))
                // Staging parents can contain guest links from a lower layer.
                // Never traverse one when merging a higher layer.
                var cursor = stage
                for (index in 0 until (relative.nameCount - 1).coerceAtLeast(0)) {
                    cursor = cursor.resolve(relative.getName(index))
                    check(Files.isDirectory(cursor, NOFOLLOW_LINKS) && !Files.isSymbolicLink(cursor)) {
                        "Layer attempts to write through a guest symlink"
                    }
                }
                return output
            }

            override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
                val out = destination(dir)
                if (Files.exists(out, NOFOLLOW_LINKS) && !Files.isDirectory(out, NOFOLLOW_LINKS)) removeTree(out)
                if (!Files.exists(out, NOFOLLOW_LINKS)) Files.createDirectory(out)
                budget.directoryModes[out] = mode(dir)
                return FileVisitResult.CONTINUE
            }

            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                if (source.relativize(file).toString() == marker) return FileVisitResult.CONTINUE
                val out = destination(file)
                if (Files.exists(out, NOFOLLOW_LINKS)) removeTree(out)
                when {
                    attrs.isSymbolicLink -> Files.createSymbolicLink(out, Files.readSymbolicLink(file))
                    attrs.isRegularFile -> {
                        check(attrs.size() <= maxBytes - budget.bytes) { "Rootfs byte budget exceeded" }
                        FileChannel.open(file, READ, NOFOLLOW_LINKS).use { input ->
                            FileChannel.open(out, CREATE_NEW, WRITE).use { output ->
                                val buffer = ByteBuffer.allocate(64 * 1024)
                                while (true) {
                                    if (cancelled()) throw InterruptedException("Rootfs preparation cancelled")
                                    buffer.clear()
                                    val size = input.read(buffer)
                                    if (size < 0) break
                                    check(size.toLong() <= maxBytes - budget.bytes) { "Rootfs byte budget exceeded" }
                                    budget.bytes += size
                                    buffer.flip()
                                    while (buffer.hasRemaining()) output.write(buffer)
                                }
                                // One real filesystem barrier below covers every
                                // file; per-file fsync is pure cold-copy latency.
                                if (durabilityBarrier == null) output.force(true)
                            }
                        }
                        Files.setAttribute(out, "unix:mode", mode(file), NOFOLLOW_LINKS)
                    }
                    else -> error("Unsupported filesystem entry in environment layer")
                }
                // Bounded progress: every 1024 entries, never per file/log byte.
                if (budget.entries % 1024L == 0L) onCopyProgress()
                return FileVisitResult.CONTINUE
            }

            override fun postVisitDirectory(dir: Path, exc: java.io.IOException?): FileVisitResult {
                if (exc != null) throw exc
                val out = stage.resolve(source.relativize(dir))
                // syncfs flushes directory metadata too; only the legacy
                // (no-barrier) path needs a per-directory fsync.
                if (durabilityBarrier == null) forceDirectory(out)
                return FileVisitResult.CONTINUE
            }
        })
    }

    private fun recover(root: Path, journal: Path, plan: Plan) {
        if (!Files.exists(journal, NOFOLLOW_LINKS)) return
        require(Files.isRegularFile(journal, NOFOLLOW_LINKS) && Files.size(journal) <= 2048)
        val record = Properties().apply { Files.newInputStream(journal, NOFOLLOW_LINKS).use { load(it) } }
        require(record.getProperty("environment") == plan.environmentId && record.getProperty("base") == plan.baseRevision)
        require(record.getProperty("root") == root.fileName.toString())
        val nonce = record.getProperty("nonce")
        require(UUID.fromString(nonce).toString() == nonce)
        val stage = root.parent.resolve(".floe-rootfs-$nonce.stage")
        val backup = root.parent.resolve(".floe-rootfs-$nonce.previous")
        if (!Files.exists(root, NOFOLLOW_LINKS)) {
            check(Files.isDirectory(backup, NOFOLLOW_LINKS) && !Files.isSymbolicLink(backup)) { "Rootfs recovery data missing" }
            atomicMove(backup, root)
            forceDirectory(root.parent)
        } else if (Files.exists(backup, NOFOLLOW_LINKS)) {
            check(readMarker(root)?.getProperty("nonce") == nonce) { "Rootfs commit ambiguous; recovery data retained" }
            removeTree(backup)
        }
        if (Files.exists(stage, NOFOLLOW_LINKS)) removeTree(stage)
        Files.delete(journal)
        forceDirectory(root.parent)
    }

    private fun writeProperties(path: Path, properties: Properties) {
        FileChannel.open(path, CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { channel ->
            val bytes = java.io.ByteArrayOutputStream().apply { properties.store(this, null) }.toByteArray()
            val buffer = ByteBuffer.wrap(bytes)
            while (buffer.hasRemaining()) channel.write(buffer)
            channel.force(true)
        }
    }

    private fun atomicMove(from: Path, to: Path) {
        check(!Files.exists(to, NOFOLLOW_LINKS))
        try { Files.move(from, to, ATOMIC_MOVE) }
        catch (failure: AtomicMoveNotSupportedException) { throw java.io.IOException("Atomic rootfs publication unavailable", failure) }
    }

    private fun forceDirectory(path: Path) { FileChannel.open(path, READ).use { it.force(true) } }

    private fun mode(path: Path): Int = (Files.getAttribute(path, "unix:mode", NOFOLLOW_LINKS) as Int) and 0xFFF

    private fun realDirectoryWithin(root: Path, directory: Path): Boolean {
        check(directory.startsWith(root))
        var cursor = root
        if (!Files.isDirectory(cursor, NOFOLLOW_LINKS)) return false
        for (part in root.relativize(directory)) {
            cursor = cursor.resolve(part)
            if (!Files.isDirectory(cursor, NOFOLLOW_LINKS) || Files.isSymbolicLink(cursor)) return false
        }
        return true
    }

    private fun removeTree(path: Path) {
        Files.walkFileTree(path, object : SimpleFileVisitor<Path>() {
            override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
                // These are transaction-owned staging/backup paths. Make their
                // directories deletable without following any guest symlink.
                Files.setAttribute(dir, "unix:mode", 0x1C0, NOFOLLOW_LINKS) // 0700
                return FileVisitResult.CONTINUE
            }
            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                Files.delete(file); return FileVisitResult.CONTINUE
            }
            override fun postVisitDirectory(dir: Path, exc: java.io.IOException?): FileVisitResult {
                if (exc != null) throw exc
                Files.delete(dir); return FileVisitResult.CONTINUE
            }
        })
    }
}
