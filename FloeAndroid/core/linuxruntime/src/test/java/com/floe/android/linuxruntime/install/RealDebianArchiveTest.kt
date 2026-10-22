// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * End-to-end qualification against the REAL pinned Debian archive using the
 * PRODUCTION catalog entry (no synthetic stand-ins). Opt-in so the shared
 * Gradle cohort can run or skip it explicitly:
 *   -Dfloe.install.debianArchive=/abs/path/debian-bookworm-aarch64-pd-v4.7.0.tar.xz
 * If the property is absent, the R1 upstream path is tried; if no file
 * exists the test reports SKIPPED (never silently passing an unexecuted
 * assertion).
 */
class RealDebianArchiveTest {
    @JvmField @Rule val tmp: TemporaryFolder = TemporaryFolder()

    private fun archivePath(): String =
        System.getProperty("floe.install.debianArchive")
            ?: "Local/Private/android-g03-20261022/r1/backend/upstream/" +
            "debian-bookworm-aarch64-pd-v4.7.0.tar.xz"

    @Test
    fun productionCatalogEndToEndInstallOfPinnedDebian() {
        val source = File(archivePath())
        val absolute = if (source.isAbsolute) source else File(System.getProperty("user.dir"), source.path)
        assumeTrue("pinned Debian archive not present at ${absolute.path}", absolute.isFile)
        val catalog = FloeRootfsCatalog.debianBookwormAarch64PdV470
        val fetch = FileBytesFetch(absolute)
        val ws = File(tmp.root, "ws")
        val installer = RootfsInstaller(ws, JvmPosixFileOps(), fetch)
        val published = installer.install(catalog, File(ws, "revisions/debian-r1")
            .also { checkNotNull(it.parentFile).mkdirs() })
        assertTrue(File(published.rootfsDirectory, "etc/os-release").isFile)
        // Exact measured structure of the pinned archive.
        val m = installer.verifyPublishedRevision(published.revisionDirectory)
        assertEquals(catalog.archiveSha256, m.archiveSha256)
        assertEquals(10_206L, m.stats.entries)
        assertEquals(8_014L, m.stats.files)
        assertEquals(1_160L, m.stats.directories) // 1,161 members incl. prefix root redeclare
        assertEquals(1_023L, m.stats.symbolicLinks)
        assertEquals(8L, m.stats.excludedCharacterDevices)
        assertEquals(0L, m.stats.excludedBlockDevices)
        assertEquals(0L, m.stats.excludedFifos)
        assertEquals(0L, m.stats.hardLinks)
        assertEquals(0L, m.stats.implicitDirectories)
        assertEquals(221_379_155L, m.stats.bytesWritten)
        // Guest semantics materialized without ever following a target.
        assertEquals("usr/bin", java.nio.file.Files.readSymbolicLink(
            File(published.rootfsDirectory, "bin").toPath()).toString())
        assertEquals("/proc/self/fd", java.nio.file.Files.readSymbolicLink(
            File(published.rootfsDirectory, "dev/fd").toPath()).toString())
        assertEquals("dash", java.nio.file.Files.readSymbolicLink(
            File(published.rootfsDirectory, "usr/bin/sh").toPath()).toString())
        assertEquals(0x3FF, unixModeAt(File(published.rootfsDirectory, "tmp"))) // 01777
        assertEquals(0x9ED, unixModeAt(File(published.rootfsDirectory, "usr/bin/su"))) // 04755
        // /dev nodes are runtime-bound by the launcher: excluded, never created.
        assertFalse(File(published.rootfsDirectory, "dev/null").exists())
        assertFalse(File(published.rootfsDirectory, "dev/console").exists())
        // Verified cache reuse on a second prepare: transport untouched.
        installer.prepare(catalog)
        assertEquals(1, fetch.openCount)
    }

    @Test
    fun pinnedArchiveHashMatchesCatalogBeforeAnyInstall() {
        val source = File(archivePath())
        val absolute = if (source.isAbsolute) source else File(System.getProperty("user.dir"), source.path)
        assumeTrue("pinned Debian archive not present", absolute.isFile)
        val catalog = FloeRootfsCatalog.debianBookwormAarch64PdV470
        assertEquals(catalog.archiveSha256, sha256HexFile(absolute))
        assertEquals(catalog.knownArchiveBytes, absolute.length())
    }
}
