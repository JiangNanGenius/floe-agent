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
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.LockSupport

/**
 * Materializes a full writable Linux filesystem at the ORIGINAL registry layer
 * path. It does not create/select environment records. It must only be called
 * by the runtime owner while holding the original lease, after UID recovery,
 * with no other runtime workload. Ordered lookup paths alone are not a rootfs.
 *
 * Inheritance is a snapshot at first materialization. An existing full parent
 * is the snapshot anchor (so deleted parent files are not resurrected from the
 * base). Later parent edits need an explicit rebuild; this is not overlayfs.
 *
 * The cold materialize copy runs through a bounded copy/force pipeline: the
 * walk thread keeps ALL ownership work (containment, budgets' entry side,
 * owned source access with its mode-loan journal, directory/symlink placement
 * and existing-path replacement, and opening each input descriptor), while
 * pipeline workers only copy bytes of an already-validated fresh leaf, apply
 * its source mode and — on the pre-5.8 legacy barrier — run that file's own
 * `force(true)` on its owned output descriptor. Only flush latency overlaps;
 * every required per-file force and both publication barriers stay, and
 * copyLayer joins every worker before returning on success, failure, budget
 * refusal, cancellation and thread interrupt alike, so cleanup can never
 * delete a tree a detached worker still writes and the marker can never
 * precede unfinished copies. Transaction snapshots (hard-link preserving)
 * keep the byte-for-byte serial copier.
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
     * all bytes/metadata are durable — without that per-file cost. A null
     * barrier keeps EVERY per-file `force(true)` and every directory fsync
     * (the [copyWorkers] pipeline only overlaps their latency); it never
     * substitutes syncfs on kernels that cannot report writeback errors.
     */
    private val durabilityBarrier: ((Path) -> Unit)? = null,
    /** Bounded counts/durations only (no paths/IDs); diagnostics for the cold run. */
    private val progress: ((Progress) -> Unit)? = null,
    /** Set only by the trusted runtime owner, never by a model/request. */
    private val ownerUid: Int? = null,
    private val sourceMutationsAllowed: () -> Boolean = { true },
    /**
     * Bounded depth of the materialize-path copy/force pipeline. Workers hold
     * no source-access state and no directory placement duty; pending work is
     * capped at the pipeline's bounded queue, so the extra footprint is a few
     * file handles plus one 64 KiB buffer per running worker. 0 or below
     * restores the fully serial copy (the transaction-snapshot path always
     * stays serial by construction).
     */
    private val copyWorkers: Int = Runtime.getRuntime().availableProcessors().coerceIn(1, 4),
) {
    /**
     * Test seam only: observes each staged file path after a pipeline worker
     * completed its copy, final mode and (legacy path) its own `force(true)`.
     * Production never sets it; a throw is recorded as that file's failure
     * through the closed copy vocabulary so tests can exercise the real
     * mid-worker error/drain/join path without privileged fault injection.
     */
    @Volatile internal var fileCopiedTestHook: ((Path) -> Unit)? = null
    enum class Phase { COPY, BARRIER, PUBLISHED }
    data class Progress(val phase: Phase, val entries: Long, val bytes: Long, val elapsedMillis: Long)

    data class Plan(
        val environmentId: String,
        val baseRevision: String,
        val writableLayer: File,
        /** Original authority order, writable first and verified base last. */
        val orderedLayers: List<File>,
    )
    data class Result(
        val rootfs: File,
        val copiedBytes: Long,
        val reused: Boolean,
        /** Guest runtime endpoints (sockets/FIFOs) skipped while copying an
         *  inherited live layer. Zero for reuse and for clean base layers. */
        val skippedRuntimeEntries: Int = 0,
    )

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
        for (layer in layers) recoverSourcePermissions(layer)
        val parent = root.parent
        readMarker(root)?.let {
            // A marker naming a DIFFERENT environment/base is a refused
            // rebuild, never a silent reset of the user's layer.
            if (it.getProperty("environment") != plan.environmentId ||
                it.getProperty("base") != plan.baseRevision) {
                throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_MARKER_MISMATCH)
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
                val value = Progress(phase, budget.entries.toLong(), budget.bytes.get(),
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
            if (cancelled()) throw RootfsPrepareCancelledException()
            // Make every copied byte and attribute durable BEFORE the marker
            // can claim a complete stage. A failure/cancel here leaves the
            // unmarked stage unpublished and the original layer intact.
            report(Phase.BARRIER)
            try { durabilityBarrier?.invoke(stage) }
            catch (failure: Exception) {
                if (failure is RootfsMaterializeException) throw failure
                throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_BARRIER_IO, failure)
            }
            if (cancelled()) throw RootfsPrepareCancelledException()
            try {
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
            } catch (failure: Exception) {
                if (failure is RootfsMaterializeException) throw failure
                throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_PUBLISH_IO, failure)
            }
            report(Phase.PUBLISHED)
            return Result(root.toFile(), budget.bytes.get(), false, budget.skippedRuntimeEntries)
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
        try {
            val attrs = try { Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS) }
            catch (_: java.nio.file.NoSuchFileException) { return null }
            require(attrs.isRegularFile && attrs.size() <= 2048)
            return Properties().apply { Files.newInputStream(path, NOFOLLOW_LINKS).use { load(it) } }
        } catch (failure: java.io.IOException) {
            // EACCES is not an absent marker: falling back to a lower base
            // could otherwise resurrect a full ancestor's deleted files.
            throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_IO, failure, "stat")
        }
    }

    private inner class CopyBudget(val preserveMetadata: Boolean = false) {
        val hardLinks = mutableMapOf<Any, Path>()
        /** Written by pipeline workers as each chunk commits; atomic so the
         *  byte budget stays a real bound across overlapped copies. */
        val bytes = AtomicLong()
        var entries = 0
        var skippedRuntimeEntries = 0
        val directoryModes = mutableMapOf<Path, Int>()
        val directoryModified = mutableMapOf<Path, java.nio.file.attribute.FileTime>()
    }

    /** Guest runtime endpoints (unix sockets, FIFOs) left inside a LIVE layer
     *  by earlier guest sessions carry no durable data: they are runtime
     *  rendezvous artifacts, exactly like the device nodes the installer
     *  already excludes from the base. Copying them is impossible (a socket
     *  has no byte content to reopen) and refusing them wedges later
     *  environments that inherit the layer, so they are skipped and counted.
     *  A device node is NOT skippable: refuse it with a typed
     *  code so a rooted/restored oddity can never slip in silently. */
    private fun copyLayer(source: Path, stage: Path, budget: CopyBudget,
                          cancelled: () -> Boolean, onCopyProgress: () -> Unit) {
        var operation = "walk"
        var inputForDiagnostic: Path? = null
        val access = sourceAccess(source)
        // Bounded copy/force pipeline for the materialize path only. The
        // transaction snapshot preserves hard links against files the walk
        // has ALREADY fully written, so it keeps the serial copier unchanged.
        val pipeline = if (!budget.preserveMetadata && copyWorkers > 0)
            CopyPipeline(cancelled, durabilityBarrier == null) else null
        val stagedDirectories = if (pipeline != null) ArrayList<Path>() else null
        try {
            val visitor = object : SimpleFileVisitor<Path>() {
            private fun destination(path: Path): Path {
                if (cancelled()) throw RootfsPrepareCancelledException()
                pipeline?.recordedFailure()?.let { throw it }
                if (++budget.entries > maxEntries) {
                    throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_ENTRY_BUDGET)
                }
                val relative = source.relativize(path)
                val output = stage.resolve(relative).normalize()
                check(output.startsWith(stage))
                // Staging parents can contain guest links from a lower layer.
                // Never traverse one when merging a higher layer.
                var cursor = stage
                for (index in 0 until (relative.nameCount - 1).coerceAtLeast(0)) {
                    cursor = cursor.resolve(relative.getName(index))
                    if (!Files.isDirectory(cursor, NOFOLLOW_LINKS) || Files.isSymbolicLink(cursor)) {
                        throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_SYMLINK)
                    }
                }
                return output
            }

            override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
                val out = destination(dir)
                operation = "remove"
                if (Files.exists(out, NOFOLLOW_LINKS) && !Files.isDirectory(out, NOFOLLOW_LINKS)) removeTree(out)
                operation = "mkdir"
                if (!Files.exists(out, NOFOLLOW_LINKS)) Files.createDirectory(out)
                operation = "stat"
                budget.directoryModes[out] = access?.originalMode(dir) ?: mode(dir)
                if (budget.preserveMetadata) budget.directoryModified[out] = attrs.lastModifiedTime()
                stagedDirectories?.add(out)
                operation = "walk"
                return FileVisitResult.CONTINUE
            }

            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                if (source.relativize(file).toString() == marker) return FileVisitResult.CONTINUE
                val out = destination(file)
                operation = "remove"
                if (Files.exists(out, NOFOLLOW_LINKS)) removeTree(out)
                when {
                    attrs.isSymbolicLink -> {
                        operation = "symlink"
                        Files.createSymbolicLink(out, Files.readSymbolicLink(file))
                    }
                    attrs.isRegularFile -> {
                        // A transaction snapshot preserves hard links INSIDE
                        // its own independent copy, never links to writable
                        // source data. Initial layer merging stays unchanged.
                        val key = if (budget.preserveMetadata) attrs.fileKey() else null
                        val earlier = key?.let { budget.hardLinks[it] }
                        if (earlier != null) {
                            operation = "hardlink"
                            Files.createLink(out, earlier)
                            operation = "walk"
                            return FileVisitResult.CONTINUE
                        }
                        if (attrs.size() > maxBytes - budget.bytes.get()) {
                            throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_BYTE_BUDGET)
                        }
                        val active = pipeline
                        operation = "mode"
                        val sourceMode = if (active != null) access?.originalMode(file) ?: mode(file) else 0
                        operation = "open_input"
                        inputForDiagnostic = file
                        val input = access?.open(file) ?: FileChannel.open(file, READ, NOFOLLOW_LINKS)
                        if (active != null) {
                            // Capture the source mode while the walk's owned
                            // access window is still open; workers never touch
                            // source-access state.
                            operation = "walk"
                            val task = FileCopyTask(active, input, out, sourceMode, budget, cancelled)
                            if (!active.submit(task)) {
                                task.releaseUnstarted()
                                throw active.abortReason()
                            }
                        } else input.use { channel ->
                            operation = "open_output"
                            FileChannel.open(out, CREATE_NEW, WRITE).use { output ->
                                val buffer = ByteBuffer.allocate(64 * 1024)
                                while (true) {
                                    if (cancelled()) throw RootfsPrepareCancelledException()
                                    buffer.clear()
                                    operation = "read"
                                    val size = channel.read(buffer)
                                    if (size < 0) break
                                    if (size.toLong() > maxBytes - budget.bytes.get()) {
                                        throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_BYTE_BUDGET)
                                    }
                                    budget.bytes.addAndGet(size.toLong())
                                    buffer.flip()
                                    operation = "write"
                                    while (buffer.hasRemaining()) output.write(buffer)
                                }
                                // One real filesystem barrier below covers every
                                // file; per-file fsync is pure cold-copy latency.
                                operation = "force_file"
                                if (durabilityBarrier == null) output.force(true)
                            }
                        }
                        if (key != null) budget.hardLinks[key] = out
                    }
                    else -> if (isGuestRuntimeEndpoint(file, attrs)) {
                        // Leftover guest runtime endpoint (socket/FIFO) in a
                        // live inherited layer: no durable bytes, never
                        // materializable state; skip it like the installer
                        // excludes device nodes from the base.
                        budget.skippedRuntimeEntries += 1
                        return FileVisitResult.CONTINUE
                    } else {
                        throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_UNSUPPORTED)
                    }
                }
                // Preserve regular-file timestamps. A symlink is always a
                // literal target, never a followed metadata write; portable
                // Java cannot promise symlink timestamps (including Bsd NIO).
                if (budget.preserveMetadata && !attrs.isSymbolicLink) {
                    operation = "timestamp"
                    Files.setAttribute(out, "basic:lastModifiedTime", attrs.lastModifiedTime(), NOFOLLOW_LINKS)
                }
                // NOFOLLOW timestamp setters may need a readable descriptor.
                // Apply restrictive final modes only after all metadata writes.
                // Pipeline workers apply each copied file's own mode right
                // around its forced write; the serial path keeps applying it
                // here against the walk-captured attributes.
                if (attrs.isRegularFile && pipeline == null) {
                    operation = "mode"
                    Files.setAttribute(out, "unix:mode", mode(file), NOFOLLOW_LINKS)
                }
                // Bounded progress: every 1024 entries, never per file/log byte.
                if (budget.entries % 1024L == 0L) onCopyProgress()
                operation = "walk"
                return FileVisitResult.CONTINUE
            }

            override fun postVisitDirectory(dir: Path, exc: java.io.IOException?): FileVisitResult {
                if (exc != null) { operation = "walk"; inputForDiagnostic = dir; throw exc }
                val out = stage.resolve(source.relativize(dir))
                // syncfs flushes directory metadata too; only the legacy
                // (no-barrier) path needs a per-directory fsync. The pipeline
                // defers those fsyncs to AFTER every file force completed
                // (its link is then present), keeping the same force count.
                operation = "force_dir"
                if (durabilityBarrier == null && pipeline == null) forceDirectory(out)
                operation = "walk"
                return FileVisitResult.CONTINUE
            }

            override fun visitFileFailed(file: Path, exc: java.io.IOException): FileVisitResult {
                operation = "walk"
                inputForDiagnostic = file
                throw exc
            }
            }
            if (access != null) access.walk(visitor) else Files.walkFileTree(source, visitor)
            if (pipeline != null) {
                // Join phase one: every queued leaf's create+copy+(legacy)
                // per-file force has ACTUALLY finished before any directory
                // barrier runs, so each directory fsync persists links that
                // already exist (the same coverage the serial post-visit had).
                pipeline.awaitIdle()
                // Phase two: the legacy path's per-directory fsyncs run on the
                // same bounded workers; the syncfs path skips them exactly as
                // the serial path does (the bulk barrier covers metadata).
                if (pipeline.recordedFailure() == null && durabilityBarrier == null && stagedDirectories != null) {
                    for (directory in stagedDirectories) {
                        if (!pipeline.submit(DirForceTask(pipeline, directory))) break
                    }
                }
                pipeline.awaitIdle()
                pipeline.recordedFailure()?.let { throw it }
            }
        } catch (cancel: InterruptedException) {
            pipeline?.failAll()
            throw cancel
        } catch (typed: RootfsMaterializeException) {
            pipeline?.failAll()
            throw typed
        } catch (io: java.io.IOException) {
            pipeline?.failAll()
            // One closed code for every raw copy-phase filesystem failure
            // (open/read/write/fsync/readdir); the original IOException stays
            // on the cause chain for debugger inspection only.
            // Only numeric inode facts from the exact source we tried to open;
            // never retain its path in a log/receipt or infer a new read grant.
            val inputAttributes = if (operation == "open_input" || operation == "walk") inputForDiagnostic?.let { path ->
                runCatching { Files.readAttributes(path, "unix:mode,uid", NOFOLLOW_LINKS) }.getOrNull()
            } else null
            throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_IO, io, operation,
                (inputAttributes?.get("mode") as? Number)?.toInt()?.and(0xFFF),
                (inputAttributes?.get("uid") as? Number)?.toInt()?.takeIf { it >= 0 },
                (inputAttributes?.get("mode") as? Number)?.toInt()?.let { it and 0xF000 == 0x4000 })
        } finally {
            // copyLayer never returns while a worker is alive: sentinel + join
            // here, so the caller's transaction cleanup can never delete a
            // tree out from under a detached copy/force worker, and the
            // publication barriers below always see finished copies.
            pipeline?.close()
        }
    }

    /**
     * Bounded copy/force pipeline used by [copyLayer] on the materialize path.
     *
     * Ownership stays with the walk thread: it validates containment and
     * parent chains, spends the entry budget, performs every owned source
     * access open (mode-loan journal included), creates directories and
     * symlinks, and replaces existing staged paths. A worker receives only a
     * ALREADY-OPENED owned input descriptor plus a verified fresh leaf under
     * the stage and performs the byte copy, the file's own source mode and —
     * when [forceEachFile] (pre-5.8 legacy barrier) — that file's `force(true)`
     * on its own output descriptor, then the deferred per-directory fsyncs.
     * Nothing is skipped, replaced by syncfs, or reported as success on
     * failure; only flush latency overlaps.
     *
     * Backpressure is a counting semaphore (open input descriptors bounded by
     * the queue capacity), the first recorded failure wins, and [close] is a
     * sentinel-plus-join guarantee: no worker thread survives the enclosing
     * [copyLayer] return on success, budget refusal, IO failure, cancellation
     * or thread interrupt alike.
     */
    private inner class CopyPipeline(
        private val cancelled: () -> Boolean,
        val forceEachFile: Boolean,
    ) {
        private val workerCount = copyWorkers.coerceIn(1, 4)
        private val capacity = workerCount * 4
        private val queue = LinkedBlockingQueue<Runnable>(capacity)
        private val permits = Semaphore(capacity)
        private val outstanding = AtomicInteger(0)
        private val failure = AtomicReference<Throwable?>(null)
        @Volatile private var stop = false
        private val sentinel = Runnable { }
        private val threads = List(workerCount) { index ->
            Thread({ pump() }, "floe-rootfs-copy-$index").apply { isDaemon = true; start() }
        }

        fun shouldAbort(): Boolean = stop || failure.get() != null
        fun recordedFailure(): Throwable? = failure.get()
        fun failAll() { stop = true }

        /** The first recorded failure wins so an injected mid-copy EIO can
         *  never be replaced by a later success — or the reverse. */
        fun record(caught: Throwable) {
            stop = true
            failure.compareAndSet(null, caught)
        }

        /** Only reachable while a real failure/cancel/interrupt is in play;
         *  a bare stop without one is never treated as success. */
        fun abortReason(): Throwable = recordedFailure()
            ?: if (cancelled()) RootfsPrepareCancelledException()
            else InterruptedException("Rootfs copy pipeline interrupted")

        /** Returns false (without queueing) once the pipeline must abort. */
        fun submit(task: Runnable): Boolean {
            try {
                while (!permits.tryAcquire(50, TimeUnit.MILLISECONDS)) {
                    if (shouldAbort()) return false
                }
            } catch (interrupted: InterruptedException) {
                stop = true
                Thread.currentThread().interrupt()
                return false
            }
            if (shouldAbort()) { permits.release(); return false }
            outstanding.incrementAndGet()
            try {
                queue.put(task) // permit held => queue slot reserved
            } catch (interrupted: InterruptedException) {
                outstanding.decrementAndGet(); permits.release(); stop = true
                Thread.currentThread().interrupt()
                return false
            }
            return true
        }

        private fun pump() {
            while (true) {
                val task = try { queue.take() }
                catch (interrupted: InterruptedException) { Thread.interrupted(); continue }
                if (task === sentinel) { permits.release(); return }
                try { task.run() }
                catch (escaped: Throwable) { record(escaped) }
                finally { permits.release(); outstanding.decrementAndGet() }
            }
        }

        /** Blocks until every queued/running task has finished (or, after
         *  [failAll], fast-exited). An interrupt of the caller marks the
         *  pipeline stopping, still waits for the bounded workers, restores
         *  the interrupt flag and reports it as a lifecycle interruption —
         *  never as a completed copy. */
        fun awaitIdle() {
            var interrupted = false
            while (outstanding.get() > 0) {
                if (Thread.interrupted()) { interrupted = true; stop = true }
                if (outstanding.get() > 0) LockSupport.parkNanos(2_000_000L)
            }
            if (interrupted) {
                Thread.currentThread().interrupt()
                throw InterruptedException("Rootfs copy pipeline interrupted")
            }
        }

        /** Sentinel + join guarantee: safe to call from finally on any path. */
        fun close() {
            stop = true
            var interrupted = false
            repeat(threads.size) {
                var acquired = false
                while (!acquired) {
                    try { acquired = permits.tryAcquire(50, TimeUnit.MILLISECONDS) }
                    catch (again: InterruptedException) { interrupted = true }
                }
                // A held permit reserves a queue slot, so the put cannot block;
                // only an interrupt can fail it — retry until every worker has
                // received EXACTLY one sentinel (a lost sentinel would strand
                // its worker in take() and defeat the join guarantee).
                while (true) {
                    try { queue.put(sentinel); break }
                    catch (again: InterruptedException) { interrupted = true; stop = true }
                }
            }
            // Workers may currently run bounded filesystem calls; queued work
            // fast-exits under the stop flag. Keep joining until EVERY thread
            // is dead — returning earlier could leave a worker writing into
            // the tree the transaction cleanup is about to delete.
            for (thread in threads) {
                while (thread.isAlive) {
                    try { thread.join(100) }
                    catch (again: InterruptedException) { interrupted = true; stop = true }
                }
            }
            if (interrupted) Thread.currentThread().interrupt()
        }
    }

    /**
     * One leaf's copy work. The walk thread hands over the input descriptor it
     * opened under the owned access; this task owns both channels from here on
     * and closes each exactly once even when the pipeline aborts. On the
     * legacy barrier path the source mode is applied BEFORE `force(true)`
     * (strictly stronger durability than the pre-pipeline order); on the
     * syncfs path it is applied after close, and the bulk barrier covers it.
     */
    private inner class FileCopyTask(
        private val pipeline: CopyPipeline,
        private val input: FileChannel,
        private val output: Path,
        private val sourceMode: Int,
        private val budget: CopyBudget,
        private val cancelled: () -> Boolean,
    ) : Runnable {
        fun releaseUnstarted() { runCatching { input.close() } }

        override fun run() {
            if (pipeline.shouldAbort()) { closeInput(); return }
            var operation = "open_output"
            try {
                if (cancelled()) throw RootfsPrepareCancelledException()
                FileChannel.open(output, CREATE_NEW, WRITE).use { file ->
                    val buffer = ByteBuffer.allocate(64 * 1024)
                    while (true) {
                        if (cancelled()) throw RootfsPrepareCancelledException()
                        buffer.clear()
                        operation = "read"
                        val size = input.read(buffer)
                        if (size < 0) break
                        operation = "write"
                        // Same closed bound as the serial path: a chunk is
                        // written only while the atomic total stays within
                        // maxBytes; the exceeding chunk is never written.
                        if (budget.bytes.addAndGet(size.toLong()) > maxBytes) {
                            throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_BYTE_BUDGET)
                        }
                        buffer.flip()
                        while (buffer.hasRemaining()) file.write(buffer)
                    }
                    if (pipeline.forceEachFile) {
                        operation = "mode"
                        Files.setAttribute(output, "unix:mode", sourceMode, NOFOLLOW_LINKS)
                        operation = "force_file"
                        file.force(true)
                    }
                }
                if (!pipeline.forceEachFile) {
                    operation = "mode"
                    Files.setAttribute(output, "unix:mode", sourceMode, NOFOLLOW_LINKS)
                }
                operation = if (pipeline.forceEachFile) "force_file" else "mode"
                fileCopiedTestHook?.invoke(output)
            } catch (cancel: RootfsPrepareCancelledException) {
                pipeline.record(cancel)
            } catch (typed: RootfsMaterializeException) {
                pipeline.record(typed)
            } catch (io: java.io.IOException) {
                pipeline.record(RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_IO, io, operation))
            } finally {
                closeInput()
            }
        }

        private fun closeInput() {
            try { input.close() }
            catch (io: java.io.IOException) {
                // The serial copier surfaces a closing input as a copy-phase
                // failure too; keep the same closed code, never a silent drop.
                pipeline.record(RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_IO, io, "read"))
            }
        }
    }

    /** Legacy-path per-directory fsync, deferred until every file link and
     *  force completed. One fsync per staged directory, same count as the
     *  serial post-visit pass; a failure is the closed copy_io/force_dir
     *  refusal, never a skipped barrier. */
    private inner class DirForceTask(
        private val pipeline: CopyPipeline,
        private val directory: Path,
    ) : Runnable {
        override fun run() {
            if (pipeline.shouldAbort()) return
            try { forceDirectory(directory) }
            catch (io: java.io.IOException) {
                pipeline.record(RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_IO, io, "force_dir"))
            }
        }
    }

    /** Service-owned package snapshots reuse the established bounded copier.
     * The destination must be a newly-created empty sibling. Publication and
     * rollback belong to LinuxEnvironmentTransaction, after real UID drain. */
    internal fun copyTransactionSnapshot(sourceFile: File, destination: Path,
        cancelled: () -> Boolean): Long {
        val source = trustedRoot(sourceFile)
        recoverSourcePermissions(source)
        require(destination.parent == source.parent && destination != source)
        require(Files.isDirectory(destination, NOFOLLOW_LINKS) && !Files.isSymbolicLink(destination))
        Files.newDirectoryStream(destination).use { require(!it.iterator().hasNext()) }
        val originalMarker = source.resolve(marker)
        require(readMarker(source) != null)
        val budget = CopyBudget(preserveMetadata = true)
        copyLayer(source, destination, budget, cancelled) {}
        // copyLayer omits the materialization marker. A transaction instead
        // restores that original identity verbatim, without inventing a base.
        FileChannel.open(originalMarker, READ, NOFOLLOW_LINKS).use { input ->
            require(input.size() in 1..2048)
            FileChannel.open(destination.resolve(marker), CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { output ->
                val buffer = ByteBuffer.allocate(2048)
                while (true) {
                    buffer.clear()
                    val count = input.read(buffer)
                    if (count < 0) break
                    buffer.flip()
                    while (buffer.hasRemaining()) output.write(buffer)
                }
                output.force(true)
            }
        }
        Files.setAttribute(destination.resolve(marker), "unix:mode", mode(originalMarker), NOFOLLOW_LINKS)
        Files.setAttribute(destination.resolve(marker), "basic:lastModifiedTime",
            Files.getLastModifiedTime(originalMarker, NOFOLLOW_LINKS), NOFOLLOW_LINKS)
        for ((directory, permissions) in budget.directoryModes.entries.sortedByDescending { it.key.nameCount }) {
            check(realDirectoryWithin(destination, directory))
            Files.setAttribute(directory, "basic:lastModifiedTime",
                requireNotNull(budget.directoryModified[directory]), NOFOLLOW_LINKS)
            Files.setAttribute(directory, "unix:mode", permissions, NOFOLLOW_LINKS)
        }
        if (cancelled()) throw InterruptedException("Environment snapshot cancelled")
        durabilityBarrier?.invoke(destination)
        forceDirectory(destination)
        return budget.bytes.get()
    }

    internal fun removeTransactionTree(path: Path) { removeTree(path) }

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

    internal fun recoverSourcePermissions(root: Path) {
        try { sourceAccess(root)?.recover() }
        catch (failure: java.io.IOException) {
            throw RootfsMaterializeException(RootfsMaterializeException.CODE_ROOTFS_COPY_IO, failure, "mode")
        }
    }

    internal fun sourceAccess(root: Path): RootfsOwnedSourceAccess? =
        ownerUid?.let { RootfsOwnedSourceAccess(root, it, sourceMutationsAllowed) }

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
        if (!Files.isDirectory(path, NOFOLLOW_LINKS)) {
            Files.delete(path) // unlink a file/guest link; never traverse its target
            return
        }
        val visitor = object : SimpleFileVisitor<Path>() {
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
        }
        sourceAccess(path)?.walk(visitor, deleting = true) ?: Files.walkFileTree(path, visitor)
    }
}
