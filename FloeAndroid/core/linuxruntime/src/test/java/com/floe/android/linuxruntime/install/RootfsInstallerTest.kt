// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Transaction/publication/cache/cancellation/ownership checks for the
 * installer facade with an in-memory transport. Every failure path must
 * preserve any existing revision and leave no installer-owned debris.
 */
class RootfsInstallerTest {
    @JvmField @Rule val tmp: TemporaryFolder = TemporaryFolder()

    private val ops = JvmPosixFileOps()

    private fun workspace(): File = File(tmp.root, "ws-${System.nanoTime()}")

    private fun goodArchiveBytes(): ByteArray = TarArchive()
        .rootDirectory(0x1ED)
        .directory("usr", 0x1ED)
        .file("usr/a", "alpha".toByteArray(), 0x1B4)
        .symlink("bin", "usr")
        .toXz()

    private fun installer(
        bytes: ByteArray,
        reserveBytes: Long = RootfsInstaller.DEFAULT_RESERVE_BYTES,
        usableOverride: Long? = null,
    ): Triple<RootfsInstaller, FakeFetch, File> {
        val ws = workspace()
        val fetch = FakeFetch(bytes)
        val effectiveOps: PosixFileOps = usableOverride?.let { LowDiskOps(ops, it) } ?: ops
        return Triple(
            RootfsInstaller(ws, effectiveOps, fetch, reserveBytes),
            fetch,
            ws,
        )
    }

    @Test
    fun preparePublishVerifyHappyPathWithOwnershipTransfer() {
        val bytes = goodArchiveBytes()
        val (installer, fetch, ws) = installer(bytes)
        val catalog = catalogFor(bytes)
        val prepared = installer.prepare(catalog)
        assertEquals(1, fetch.openCount)
        assertTrue(File(prepared.rootfsDirectory, "usr/a").isFile)
        assertTrue(File(prepared.stagingDirectory, RootfsInstaller.OWNER_MARKER_NAME).isFile)
        val target = File(ws, "revisions/r1").also { checkNotNull(it.parentFile).mkdirs() }
        val published = installer.publish(prepared, target)
        assertEquals(File(target, "rootfs"), published.rootfsDirectory)
        assertFalse("marker must not survive publication",
            File(target, RootfsInstaller.OWNER_MARKER_NAME).exists())
        val manifest = installer.verifyPublishedRevision(target)
        assertEquals(catalog.archiveSha256, manifest.archiveSha256)
        assertEquals(catalog.catalogId, manifest.catalogId)
        assertEquals(1L, manifest.stats.files)
        assertEquals(1L, manifest.stats.directories)
        assertEquals(1L, manifest.stats.symbolicLinks)
        assertEquals(0L, manifest.stats.implicitDirectories)
        assertEquals("alpha", File(published.rootfsDirectory, "usr/a").readText())
    }

    @Test
    fun publishRejectsExistingTargetAndMissingParent() {
        val bytes = goodArchiveBytes()
        val (installer, _, ws) = installer(bytes)
        val prepared = installer.prepare(catalogFor(bytes))
        val taken = File(ws, "revisions/live"); taken.mkdirs()
        File(taken, "keep").writeText("old root")
        val (failure, _) = expectInstall { installer.publish(prepared, taken) }
        assertEquals(InstallFailure.DESTINATION_EXISTS, failure)
        assertEquals("old root", File(taken, "keep").readText())
        val (parentFailure, _) = expectInstall {
            installer.publish(prepared, File(ws, "nowhere/revisions/r2"))
        }
        assertEquals(InstallFailure.DESTINATION_PARENT_MISSING, parentFailure)
        // staging survives both rejections and can still be published correctly.
        assertNotNull(installer.publish(prepared, File(ws, "revisions/r2")))
    }

    @Test
    fun digestMismatchKeepsPublishedRevisionAndLeavesNoDebris() {
        val good = goodArchiveBytes()
        val (installer, _, ws) = installer(good)
        val catalog = catalogFor(good)
        val revision = installer.install(catalog, File(ws, "revisions/v1").also { checkNotNull(it.parentFile).mkdirs() })
        val manifestBefore = revision.revisionDirectory.resolve("manifest.json").readText()

        // A fresh workspace forces the transport path (no cache reuse here).
        val badWs = workspace()
        val badInstaller = RootfsInstaller(badWs, ops, FakeFetch("different-bytes!".toByteArray()))
        val (failure, _) = expectInstall { badInstaller.prepare(catalog) }
        assertEquals(InstallFailure.DIGEST_MISMATCH, failure)
        assertEquals(manifestBefore, File(revision.revisionDirectory, "manifest.json").readText())
        // staging cleaned, part cleaned, no cache entry for a failed digest.
        val stagingRoot = File(badWs, RootfsInstaller.STAGING_DIR_NAME)
        assertEquals(0, stagingRoot.listFiles()?.size ?: 0)
        val downloads = File(badWs, RootfsInstaller.DOWNLOADS_DIR_NAME)
        val leftovers = downloads.walkTopDown().filter { it.isFile }.toList()
        assertEquals(emptyList<String>(), leftovers.map { it.name })
        assertTrue(File(ws, "revisions/v1/rootfs/usr/a").isFile)
    }

    @Test
    fun cancellationDuringDownloadPreservesEverythingAndCleansPart() {
        val good = goodArchiveBytes()
        val (installer, _, ws) = installer(good)
        installer.install(catalogFor(good), File(ws, "revisions/v1").also { checkNotNull(it.parentFile).mkdirs() })
        val random = ByteArray(300 * 1024)
        java.security.SecureRandom().nextBytes(random)
        val big = TarArchive().file("usr/big", random).toXz()
        var checks = 0
        val cancel = CancellationCheck { checks += 1; checks > 2 }
        val second = RootfsInstaller(ws, ops, FakeFetch(big))
        expectCancelled { second.prepare(catalogFor(big), null, cancel) }
        val stagingRoot = File(ws, RootfsInstaller.STAGING_DIR_NAME)
        assertEquals(0, stagingRoot.listFiles()?.size ?: 0)
        assertTrue(File(ws, "revisions/v1/rootfs/usr/a").isFile)
    }

    @Test
    fun cancellationDuringExtractIsReportedAsCancellationNotSuccess() {
        val tar = TarArchive()
        repeat(60) { tar.file("usr/f$it", ByteArray(120)) }
        val bytes = tar.toXz()
        val (installer, _, ws) = installer(bytes)
        var checks = 0
        val cancel = CancellationCheck { checks += 1; checks > 25 }
        expectCancelled { installer.prepare(catalogFor(bytes), null, cancel) }
        val stagingRoot = File(ws, RootfsInstaller.STAGING_DIR_NAME)
        assertEquals(0, stagingRoot.listFiles()?.size ?: 0)
    }

    @Test
    fun diskBudgetPreflightFailsBeforeAnyBytesLanded() {
        val bytes = goodArchiveBytes()
        val (installer, fetch, ws) = installer(bytes, usableOverride = 1024L)
        val (failure, _) = expectInstall { installer.prepare(catalogFor(bytes)) }
        assertEquals(InstallFailure.DISK_BUDGET, failure)
        assertEquals(0, fetch.openCount)
        assertEquals(0, File(ws, RootfsInstaller.STAGING_DIR_NAME).listFiles()?.size ?: 0)
    }

    @Test
    fun cacheIsReusedOnlyAfterRehashAndRefetchedWhenCorrupted() {
        val bytes = goodArchiveBytes()
        val (installer, fetch, ws) = installer(bytes)
        val catalog = catalogFor(bytes)
        installer.prepare(catalog)
        assertEquals(1, fetch.openCount)
        installer.prepare(catalog)
        assertEquals("verified cache reuse without transport", 1, fetch.openCount)
        // Corrupt the cache bytes: re-hash must catch it and refetch.
        val cache = checkNotNull(
            File(File(ws, RootfsInstaller.DOWNLOADS_DIR_NAME), catalog.catalogId).listFiles(),
        ).first { it.name.startsWith("archive-") && !it.name.endsWith(".verified") }
        cache.appendBytes(byteArrayOf(0x21))
        installer.prepare(catalog)
        assertEquals("corrupt cache was discarded and refetched", 2, fetch.openCount)
    }

    @Test
    fun markerOwnershipDisciplineForDiscardAndSweep() {
        val bytes = goodArchiveBytes()
        val (installer, _, ws) = installer(bytes)
        val prepared = installer.prepare(catalogFor(bytes))
        // Tampered marker: discard refuses, publish refuses, staging survives.
        val marker = File(prepared.stagingDirectory, RootfsInstaller.OWNER_MARKER_NAME)
        val original = marker.readText()
        marker.writeText("tampered")
        assertFalse(installer.discard(prepared))
        val (failure, _) = expectInstall { installer.publish(prepared, File(ws, "rev/x")) }
        assertEquals(InstallFailure.OWNER_MARKER_MISSING, failure)
        assertTrue(File(prepared.rootfsDirectory, "usr/a").isFile)
        marker.writeText(original)
        assertTrue(installer.discard(prepared))
        assertFalse(prepared.stagingDirectory.exists())
        // Foreign staging directories are counted, never removed.
        val foreign = File(ws, RootfsInstaller.STAGING_DIR_NAME + "/foreign-dir")
        foreign.mkdirs(); File(foreign, "data").writeText("user data")
        val report = installer.sweepStaleWorkspace(0L)
        assertEquals(0, report.removedStaging.size)
        assertEquals(1, report.skippedForeign)
        assertTrue(File(foreign, "data").isFile)
    }

    @Test
    fun sweepRemovesStalePartsAndClearCacheFreesVerifiedArchive() {
        val bytes = goodArchiveBytes()
        val (installer, _, ws) = installer(bytes)
        val catalog = catalogFor(bytes)
        installer.prepare(catalog)
        val downloads = File(File(ws, RootfsInstaller.DOWNLOADS_DIR_NAME), catalog.catalogId)
        val oldPart = File(downloads, "part-deadbeef01.part")
        oldPart.writeText("abandoned")
        oldPart.setLastModified(System.currentTimeMillis() - 10_000_000L)
        val freshPart = File(downloads, "part-cafebabe02.part")
        freshPart.writeText("recent")
        val report = installer.sweepStaleWorkspace(1_000_000L)
        assertEquals(1, report.removedPartFiles)
        assertFalse(oldPart.exists())
        assertTrue(freshPart.exists())
        assertTrue(downloads.listFiles()!!.any { it.name.startsWith("archive-") })
        val freed = installer.clearCache(catalog)
        assertTrue(freed > 0)
        assertFalse(downloads.listFiles()!!.any { it.name.startsWith("archive-") })
    }

    @Test
    fun httpSchemeAndNonHttpsTransportAreRejected() {
        val bytes = goodArchiveBytes()
        val good = catalogFor(bytes)
        val e = runCatching { good.copy(httpsUrl = "http://insecure.test/a.tar.xz") }.exceptionOrNull()
        assertTrue(e is IllegalArgumentException)
        val direct = runCatching { HttpsByteFetch().open("http://insecure.test/a.tar.xz") }.exceptionOrNull()
        assertTrue(direct is RootfsInstallException)
        assertEquals(InstallFailure.INVALID_CATALOG, (direct as RootfsInstallException).failure)
    }

    @Test
    fun discoverSelectsJvmImplementationOnHost() {
        assertTrue(PosixFileOps.discover() is JvmPosixFileOps)
    }

    @Test
    fun deleteTreeNeverFollowsStoredSymlinks() {
        val outside = File(tmp.root, "outside"); outside.mkdirs()
        val crownJewel = File(outside, "do-not-touch"); crownJewel.writeText("keep")
        val owned = File(tmp.root, "owned"); owned.mkdirs()
        java.nio.file.Files.createSymbolicLink(
            File(owned, "escape").toPath(), outside.toPath(),
        )
        File(owned, "file").writeText("f")
        ops.deleteTree(owned)
        assertFalse(owned.exists())
        assertTrue("symlinked directory contents must be untouched", crownJewel.isFile)
        assertTrue(outside.isDirectory)
    }

    @Test
    fun progressEventsCoverTheWholePrepareLifecycle() {
        val bytes = goodArchiveBytes()
        val (installer, _, _) = installer(bytes)
        val phases = mutableListOf<InstallPhase>()
        val listener = ProgressListener { phases += it.phase }
        installer.prepare(catalogFor(bytes), listener, null)
        assertTrue("phases=$phases", phases.contains(InstallPhase.PREFLIGHT))
        assertTrue(phases.contains(InstallPhase.DOWNLOAD))
        assertTrue(phases.contains(InstallPhase.VERIFY_ARCHIVE))
    }

    @Test
    fun manifestRoundTripsThroughJsonEscapeCorrectly() {
        val bytes = goodArchiveBytes()
        val (installer, _, ws) = installer(bytes)
        val catalog = catalogFor(bytes).copy(displayName = "weird \" \\ \n name", version = "v-1_2")
        val published = installer.install(catalog, File(ws, "rev/m").also { checkNotNull(it.parentFile).mkdirs() })
        val parsed = installer.verifyPublishedRevision(published.revisionDirectory)
        assertEquals("weird \" \\ \n name", parsed.displayName)
        assertEquals("v-1_2", parsed.version)
        assertEquals(catalog.archiveSha256, parsed.archiveSha256)
        assertEquals(4L, parsed.stats.entries)
    }

    @Test
    fun caseSensitiveDestinationRequirementIsProbed() {
        val bytes = goodArchiveBytes()
        val (installer, _, ws) = installer(bytes)
        val probeDir = tmp.newFolder("cstest")
        val uppercase = File(probeDir, "FloeCaseProbe-A").also { it.createNewFile() }
        val volumeIsCaseInsensitive = File(probeDir, "floecaseprobe-a").exists()
        uppercase.delete()
        val catalog = catalogFor(bytes).copy(requiresCaseSensitiveDestination = true)
        val result = runCatching { installer.prepare(catalog) }
        if (volumeIsCaseInsensitive) {
            val error = result.exceptionOrNull()
            assertTrue("expected rejection on this case-insensitive host",
                error is RootfsInstallException &&
                    error.failure == InstallFailure.CASE_INSENSITIVE_DESTINATION)
            assertEquals(0, File(ws, RootfsInstaller.STAGING_DIR_NAME).listFiles()?.size ?: 0)
        } else {
            assertTrue(result.isSuccess)
        }
    }
}
