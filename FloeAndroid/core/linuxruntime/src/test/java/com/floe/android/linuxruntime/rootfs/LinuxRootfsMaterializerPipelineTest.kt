// SPDX-License-Identifier: MPL-2.0
// Regression sources for the N05 cold-materialization repair (job-71fb822f1f594715):
// the pre-5.8 legacy path keeps EVERY per-file force and per-directory fsync
// on the owned descriptors but runs leaf copies through a bounded worker
// pipeline. These tests pin the changed concurrency boundaries:
// serial/pipelined output equivalence, per-file completion before the
// join/barrier, worker failure propagation with full join and no orphan
// staging, mid-pipeline cancellation that can never leave a detached writer
// over a deleted root, the closed budget codes, and progress accounting
// after the join. Author-written; NOT executed by this lane (primary owns
// builds/tests).
package com.floe.android.linuxruntime.rootfs

import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.stream.Collectors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LinuxRootfsMaterializerPipelineTest {

    private fun plan(layer: Path, base: Path, env: String = "pipe-env") =
        LinuxRootfsMaterializer.Plan(env, "base-1", layer.toFile(), listOf(layer.toFile(), base.toFile()))

    private fun liveWorkers() = Thread.getAllStackTraces().keys
        .filter { it.name.startsWith("floe-rootfs-copy") && it.isAlive }
        .map { it.name }

    private fun assertNoPipelineScratchUnder(home: Path) = Files.list(home).use { entries ->
        assertEquals(0L, entries.filter { it.fileName.toString().startsWith(".floe-rootfs-") }.count())
    }

    /** Builds a deterministic multi-chunk tree with globally unique file
     *  names, two symlinks, an empty directory and nested directories. */
    private class Tree(val files: Set<String>, val bytes: Long)

    private fun buildBase(base: Path, files: Int): Tree {
        val names = mutableSetOf<String>()
        var total = 0L
        Files.createDirectories(base.resolve("usr/bin"))
        Files.createDirectories(base.resolve("usr/lib"))
        Files.createDirectories(base.resolve("etc/conf.d/deep/deeper"))
        Files.createDirectories(base.resolve("var/empty"))
        val tool = base.resolve("usr/bin/tool")
        Files.writeString(tool, "#!/bin/sh\necho tool\n")
        Files.setAttribute(tool, "unix:mode", 0x1ED)
        names += "tool"; total += Files.size(tool)
        val big = base.resolve("usr/lib/big.bin")
        val pattern = ByteArray(100_000) { (it % 251).toByte() }
        Files.write(big, pattern)
        Files.write(big, pattern, java.nio.file.StandardOpenOption.APPEND)
        names += "big.bin"; total += Files.size(big)
        for (index in 0 until files) {
            val directory = if (index % 3 == 0) base.resolve("etc/conf.d/deep/deeper") else base.resolve("var")
            val file = directory.resolve("f$index.bin")
            Files.write(file, ByteArray(64) { (it % 17).toByte() })
            names += "f$index.bin"; total += Files.size(file)
        }
        Files.createSymbolicLink(base.resolve("bin"), Path.of("usr/bin"))
        Files.createSymbolicLink(base.resolve("hostlink"), Path.of("/etc/hosts"))
        return Tree(names, total)
    }

    /** Structural+content+mode fingerprint of a published tree, excluding the
     *  materialization marker (whose env/nonce legitimately differ). */
    private fun fingerprint(root: Path): List<String> {
        val digest = MessageDigest.getInstance("SHA-256")
        return Files.walk(root).use { paths ->
            paths.filter { it != root && it.fileName.toString() != ".floe-linux-rootfs-v1" }.map { path ->
                val relative = root.relativize(path).toString()
                when {
                    Files.isSymbolicLink(path) -> "L|$relative|${Files.readSymbolicLink(path)}"
                    Files.isDirectory(path, NOFOLLOW_LINKS) ->
                        "D|$relative|%03o".format((Files.getAttribute(path, "unix:mode", NOFOLLOW_LINKS) as Int) and 0xFFF)
                    else -> {
                        digest.reset()
                        val hash = digest.digest(Files.readAllBytes(path)).joinToString("") { "%02x".format(it) }
                        "F|$relative|%03o".format((Files.getAttribute(path, "unix:mode", NOFOLLOW_LINKS) as Int) and 0xFFF) + "|$hash"
                    }
                }
            }.sorted().collect(Collectors.toList())
        }
    }

    private fun fixture(files: Int = 120, test: (Path, Path, Path, Tree) -> Unit) {
        val home = Files.createTempDirectory("floe-rootfs-pipe-").toRealPath()
        try {
            val layer = Files.createDirectory(home.resolve("layer"))
            val base = Files.createDirectory(home.resolve("base"))
            val tree = buildBase(base, files)
            test(home, layer, base, tree)
        } finally {
            Files.walk(home).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
            }
        }
    }

    @Test fun pipelinedOutputEqualsSerialOutput() = fixture(files = 60) { _, layerA, base, tree ->
        val serial = LinuxRootfsMaterializer(copyWorkers = 0).prepare(plan(layerA, base, "env-a")) { false }
        val layerB = layerA.parent.resolve("layer-b")
        Files.createDirectory(layerB)
        val pipelined = LinuxRootfsMaterializer(copyWorkers = 4).prepare(plan(layerB, base, "env-b")) { false }
        assertFalse(serial.reused); assertFalse(pipelined.reused)
        assertEquals(0, serial.skippedRuntimeEntries)
        assertEquals(0, pipelined.skippedRuntimeEntries)
        assertEquals(serial.copiedBytes, pipelined.copiedBytes)
        assertEquals(tree.bytes, pipelined.copiedBytes)
        assertEquals(fingerprint(layerA), fingerprint(layerB))
        assertTrue(Files.isSymbolicLink(layerB.resolve("bin")))
        assertEquals(Path.of("usr/bin"), Files.readSymbolicLink(layerB.resolve("bin")))
        assertEquals(0x1ED, (Files.getAttribute(layerB.resolve("usr/bin/tool"), "unix:mode") as Int) and 0xFFF)
        // All pipeline threads were joined before prepare returned.
        assertEquals(emptyList<String>(), liveWorkers())
    }

    @Test fun legacyPipelineCompletesAndForcesEverySingleFile() = fixture(files = 120) { _, layer, base, tree ->
        val copied = ConcurrentHashMap.newKeySet<String>()
        val materializer = LinuxRootfsMaterializer(copyWorkers = 3)
        materializer.fileCopiedTestHook = { out -> copied += out.fileName.toString() }
        val result = materializer.prepare(plan(layer, base)) { false }
        assertFalse(result.reused)
        // Every regular file's worker unit ran to completion (copy + final mode
        // + its own force(true) on the owned descriptor) before the join.
        assertEquals(tree.files, copied)
        assertEquals(tree.bytes, result.copiedBytes)
        assertTrue(Files.isRegularFile(layer.resolve(".floe-linux-rootfs-v1"), NOFOLLOW_LINKS))
        assertEquals(emptyList<String>(), liveWorkers())
    }

    @Test fun bulkBarrierSeesEveryQueuedCopyFinished() = fixture(files = 40) { _, layer, base, tree ->
        val copied = ConcurrentHashMap.newKeySet<String>()
        var wrongChunkSize = 0
        var barrierCalls = 0
        var unfinishedAtBarrier = 0
        val materializer = LinuxRootfsMaterializer(copyWorkers = 3, durabilityBarrier = { _ ->
            // The bulk barrier must only run AFTER every pipeline worker has
            // joined: no queued copy may still be missing at this point.
            barrierCalls++
            unfinishedAtBarrier = tree.files.size - copied.size
        })
        materializer.fileCopiedTestHook = { out ->
            // The hook fires at the worker's copy tail: a multi-chunk file
            // must already carry its full byte count there, proving the whole
            // chunk loop completed inside its own worker before the join.
            if (out.fileName.toString() == "big.bin" && Files.size(out) != 200_000L) wrongChunkSize++
            copied += out.fileName.toString()
        }
        materializer.prepare(plan(layer, base)) { false }
        assertEquals(1, barrierCalls)
        assertEquals(0, unfinishedAtBarrier)
        assertEquals(0, wrongChunkSize)
        assertEquals(emptyList<String>(), liveWorkers())
    }

    @Test fun workerFailurePropagatesJoinsWorkersAndPublishesNothing() = fixture(files = 30) { home, layer, base, _ ->
        Files.writeString(layer.resolve("keep"), "keep me")
        val materializer = LinuxRootfsMaterializer(copyWorkers = 4)
        materializer.fileCopiedTestHook = { out ->
            if (out.fileName.toString() == "f7.bin") throw IOException("injected worker failure")
        }
        val failure = assertThrows(RootfsMaterializeException::class.java) {
            materializer.prepare(plan(layer, base)) { false }
        }
        assertEquals(RootfsMaterializeException.CODE_ROOTFS_COPY_IO, failure.code)
        assertEquals("force_file", failure.operation)
        // Nothing published, the original layer is intact, and the finally
        // cleanup ran only AFTER every owned worker had joined: no detached
        // writer can be left over a deleted root.
        assertEquals("keep me", Files.readString(layer.resolve("keep")))
        assertFalse(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
        assertEquals(emptyList<String>(), liveWorkers())
        assertNoPipelineScratchUnder(home)
    }

    @Test fun midPipelineCancellationJoinsWorkersKeepsOriginalLayer() = fixture(files = 300) { home, layer, base, _ ->
        Files.writeString(layer.resolve("keep"), "keep me")
        val cancel = AtomicBoolean(false)
        val seen = AtomicInteger(0)
        val materializer = LinuxRootfsMaterializer(copyWorkers = 4)
        materializer.fileCopiedTestHook = { _ -> if (seen.incrementAndGet() == 40) cancel.set(true) }
        val failure = assertThrows(RootfsPrepareCancelledException::class.java) {
            materializer.prepare(plan(layer, base)) { cancel.get() }
        }
        assertTrue(failure is InterruptedException)
        assertFalse(RootfsMaterializeException::class.java.isInstance(failure))
        assertEquals("keep me", Files.readString(layer.resolve("keep")))
        assertFalse(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
        // Cancellation drained every queued task (each closed its own input
        // descriptor) and joined the workers before returning.
        assertEquals(emptyList<String>(), liveWorkers())
        assertNoPipelineScratchUnder(home)
    }

    @Test fun callerInterruptStillJoinsWorkersBeforeCleanup() = fixture(files = 120) { home, layer, base, _ ->
        Files.writeString(layer.resolve("keep"), "keep me")
        val caller = Thread.currentThread()
        val interrupted = AtomicBoolean(false)
        val materializer = LinuxRootfsMaterializer(copyWorkers = 1)
        materializer.fileCopiedTestHook = {
            if (interrupted.compareAndSet(false, true)) caller.interrupt()
        }
        val flagPreserved = try {
            assertThrows(InterruptedException::class.java) {
                materializer.prepare(plan(layer, base)) { false }
            }
            Thread.currentThread().isInterrupted
        } finally {
            // The test runner and fixture cleanup do not inherit our interruption.
            Thread.interrupted()
        }
        assertTrue(flagPreserved)
        assertEquals(emptyList<String>(), liveWorkers())
        assertEquals("keep me", Files.readString(layer.resolve("keep")))
        assertFalse(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
        assertNoPipelineScratchUnder(home)
    }

    @Test fun entryBudgetStillRefusesOnTheWalkThread() = fixture(files = 8) { home, layer, base, _ ->
        val materializer = LinuxRootfsMaterializer(copyWorkers = 4, maxEntries = 4)
        val failure = assertThrows(RootfsMaterializeException::class.java) {
            materializer.prepare(plan(layer, base)) { false }
        }
        assertEquals(RootfsMaterializeException.CODE_ROOTFS_COPY_ENTRY_BUDGET, failure.code)
        assertFalse(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
        assertEquals(emptyList<String>(), liveWorkers())
        assertNoPipelineScratchUnder(home)
    }

    @Test fun byteBudgetRefusalStaysClosedAcrossThePipeline() = fixture(files = 8) { home, layer, base, _ ->
        // 200,000-byte chunked file + 8 small files + tool against a ceiling
        // the tree exceeds mid-copy: the refusal is the same closed
        // byte-budget code whether the walk precheck or a worker's atomic
        // commit trips first, and nothing publishes.
        val materializer = LinuxRootfsMaterializer(maxBytes = 200_128, copyWorkers = 1)
        val failure = assertThrows(RootfsMaterializeException::class.java) {
            materializer.prepare(plan(layer, base)) { false }
        }
        assertEquals(RootfsMaterializeException.CODE_ROOTFS_COPY_BYTE_BUDGET, failure.code)
        assertFalse(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
        assertEquals(emptyList<String>(), liveWorkers())
        assertNoPipelineScratchUnder(home)
    }

    @Test fun progressAfterJoinReportsExactPipelinedTotals() = fixture(files = 1_100) { _, layer, base, tree ->
        val phases = mutableListOf<LinuxRootfsMaterializer.Phase>()
        val entries = mutableListOf<Long>()
        val bytes = mutableListOf<Long>()
        // A bulk-barrier materialization skips the per-file fsyncs, so only
        // pipeline accounting and the join-then-report order are under test.
        val result = LinuxRootfsMaterializer(copyWorkers = 4, durabilityBarrier = { },
            progress = { value -> phases += value.phase; entries += value.entries; bytes += value.bytes })
            .prepare(plan(layer, base)) { false }
        assertEquals(LinuxRootfsMaterializer.Phase.BARRIER, phases[phases.size - 2])
        assertEquals(LinuxRootfsMaterializer.Phase.PUBLISHED, phases.last())
        assertEquals(LinuxRootfsMaterializer.Phase.COPY, phases.first())
        // Bounded callbacks (every 1024 entries), monotone, and the LAST COPY
        // report — which runs after the join — carries the exact totals the
        // result returns.
        assertTrue(phases.count { it == LinuxRootfsMaterializer.Phase.COPY } >= 3)
        assertTrue(bytes.zipWithNext().all { (a, b) -> b >= a })
        assertTrue(entries.zipWithNext().all { (a, b) -> b >= a })
        val lastCopyReport = phases.indexOfLast { it == LinuxRootfsMaterializer.Phase.COPY }
        assertEquals(result.copiedBytes, bytes[lastCopyReport])
        assertEquals(tree.bytes, result.copiedBytes)
        assertTrue(entries[lastCopyReport] >= 1_100)
        assertNull(liveWorkers().firstOrNull())
    }

    @Test fun serialFallbackFlagRestoresLegacySingleCopier() = fixture(files = 12) { home, layer, base, _ ->
        Files.writeString(layer.resolve("keep"), "keep me")
        val materializer = LinuxRootfsMaterializer(copyWorkers = 0)
        var hookCalls = 0
        materializer.fileCopiedTestHook = { hookCalls++ }
        materializer.prepare(plan(layer, base)) { false }
        // The seam is pipeline-only: the serial copier never fires it, so the
        // zero-worker configuration really is the original in-place copy.
        assertEquals(0, hookCalls)
        assertTrue(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
        assertEquals(emptyList<String>(), liveWorkers())
        assertNoPipelineScratchUnder(home)
    }
}
