// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Focused host/JVM boundary checks for the streaming extractor: traversal,
 * symlink crossing, truncation, header corruption, budgets, device policy,
 * modes and cancellation. Synthetic fixtures only.
 */
public class TarXzSafetyTest {
    @JvmField @Rule val tmp: TemporaryFolder = TemporaryFolder()

    private val ops = JvmPosixFileOps()

    private fun writeXz(archiveBytes: ByteArray): File {
        val file = File(tmp.root, "fixture-${System.nanoTime()}.tar.xz")
        file.writeBytes(archiveBytes)
        return file
    }

    private fun dest(): File = File(tmp.root, "dest-${System.nanoTime()}")

    private fun extract(archiveBytes: ByteArray, catalog: RootfsCatalogEntry): ExtractionStats =
        TarXzExtractor(ops).extract(writeXz(archiveBytes), dest(), catalog, null, null)

    @Test
    fun cleanArchiveMaterializesWithStats() {
        val tar = TarArchive()
            .rootDirectory(0x1ED)
            .directory("usr", 0x1ED)
            .file("usr/a", "alpha".toByteArray(), 0x1B4)
            .symlink("bin", "usr/bin")
            .hardlink("usr/b", "usr/a")
        val catalog = catalogFor(tar.toXz())
        val out = dest()
        TarXzExtractor(ops).extract(writeXz(tar.toXz()), out, catalog, null, null)
        assertEquals(0, File(out, "usr/a").readText().compareTo("alpha"))
        assertEquals("usr/bin", java.nio.file.Files.readSymbolicLink(File(out, "bin").toPath()).toString())
        assertTrue(File(out, "usr/b").isFile)
        assertEquals(0x1B4, unixModeAt(File(out, "usr/a")))
        assertEquals(0x1ED, unixModeAt(out))
        val stats = extract(tar.toXz(), catalog)
        assertEquals(5L, stats.entries) // root re-declare + dir + file + symlink + hardlink
        assertEquals(1L, stats.files)
        assertEquals(1L, stats.directories)
        assertEquals(1L, stats.symbolicLinks)
        assertEquals(1L, stats.hardLinks)
    }

    @Test
    fun absoluteDotDotAndForeignPrefixAreRejected() {
        for (name in listOf("/etc/passwd", "top/../escape", "other/usr/a", "")) {
            val archive = hostileTar(rawTarMember(name, '0', content = "y".toByteArray()))
            val xzBytes = xzOf(archive)
            val out = dest()
            val (failure, _) = expectInstall {
                TarXzExtractor(ops).extract(
                    writeXz(xzBytes), out, catalogFor(xzBytes),
                )
            }
            assertEquals(InstallFailure.UNSAFE_PATH, failure)
        }
    }

    @Test
    fun dotDotComponentInsidePrefixIsRejected() {
        val archive = hostileTar(rawTarMember("top/sub/../../escape", '0', content = "y".toByteArray()))
        val xzBytes = xzOf(archive)
        val (failure, _) = expectInstall {
            TarXzExtractor(ops).extract(writeXz(xzBytes), dest(), catalogFor(xzBytes))
        }
        assertEquals(InstallFailure.UNSAFE_PATH, failure)
    }

    @Test
    fun writeThroughStoredSymlinkAborts() {
        // "top/esc" is a symlink; the next member writes "top/esc/x".
        val tar = TarArchive()
            .directory("sub", 0x1ED)
            .file("sub/real", "r".toByteArray())
            .symlink("esc", ".")
            .file("esc/planted", "p".toByteArray())
        val xzBytes = tar.toXz()
        val (failure, detail) = expectInstall {
            TarXzExtractor(ops).extract(writeXz(xzBytes), dest(), catalogFor(xzBytes))
        }
        assertEquals(InstallFailure.WRITE_THROUGH_SYMLINK, failure)
        assertTrue(detail.contains("planted"))
    }

    @Test
    fun symlinkLeafCollisionIsRejected() {
        val tar = TarArchive()
            .symlink("f", "usr/anywhere")
            .file("f", "write-through-leaf".toByteArray())
        val xzBytes = tar.toXz()
        val (failure, _) = expectInstall {
            TarXzExtractor(ops).extract(writeXz(xzBytes), dest(), catalogFor(xzBytes))
        }
        assertEquals(InstallFailure.DESTINATION_COLLISION, failure)
    }

    @Test
    fun rootRelativeSymlinkTargetsAreStoredVerbatimAndNeverFollowed() {
        val tar = TarArchive()
            .symlink("dev/fd", "/proc/self/fd")
            .symlink("bin/sh", "dash")
            .file("usr/bin/dash", "#!/bin/sh\n".toByteArray(), 0x1ED)
        val out = dest()
        val stats = TarXzExtractor(ops).extract(writeXz(tar.toXz()), out, catalogFor(tar.toXz()), null, null)
        assertEquals("/proc/self/fd", java.nio.file.Files.readSymbolicLink(File(out, "dev/fd").toPath()).toString())
        assertEquals("dash", java.nio.file.Files.readSymbolicLink(File(out, "bin/sh").toPath()).toString())
        assertEquals(2L, stats.symbolicLinks)
        // Nothing was created at the absolute target's host location:
        assertFalse(java.nio.file.Files.exists(File("/proc/self/fd").toPath().resolve("planted")))
    }

    @Test
    fun hardlinkToTraversalOrAbsoluteTargetIsUnsafePath() {
        for (link in listOf("top/../escape", "/etc/passwd")) {
            val xzBytes = xzOf(hostileTar(
                rawTarMember("top/usr", '5', 0x1ED),
                rawTarMember("top/usr/h", '1', link = link),
            ))
            val (failure, _) = expectInstall {
                TarXzExtractor(ops).extract(writeXz(xzBytes), dest(), catalogFor(xzBytes))
            }
            assertEquals(InstallFailure.UNSAFE_PATH, failure)
        }
    }

    @Test
    fun hardlinkToMissingOrNonRegularTargetIsRefused() {
        // missing regular file
        val missing = xzOf(hostileTar(
            rawTarMember("top/usr", '5', 0x1ED),
            rawTarMember("top/usr/h", '1', link = "top/usr/nope"),
        ))
        assertEquals(
            InstallFailure.HARDLINK_TARGET_UNSAFE,
            expectInstall {
                TarXzExtractor(ops).extract(writeXz(missing), dest(), catalogFor(missing))
            }.first,
        )
        // symlink target must not be aliased
        val tar = TarArchive()
            .symlink("l", "usr/a")
            .file("usr/a", "x".toByteArray())
            .hardlink("h", "l")
        val linkToSymlink = tar.toXz()
        assertEquals(
            InstallFailure.HARDLINK_TARGET_UNSAFE,
            expectInstall {
                TarXzExtractor(ops).extract(writeXz(linkToSymlink), dest(), catalogFor(linkToSymlink))
            }.first,
        )
    }

    @Test
    fun truncationInsidePayloadAndHeaderIsDetected() {
        val tar = TarArchive().file("usr/a", ByteArray(900) { '.'.code.toByte() }).toTar()
        // Cut inside the file payload of the (well-formed) xz stream.
        val cutPayload = xzOf(tar.copyOfRange(0, 512 + 100))
        assertEquals(
            InstallFailure.ARCHIVE_TRUNCATED,
            expectInstall {
                TarXzExtractor(ops).extract(writeXz(cutPayload), dest(), catalogFor(cutPayload))
            }.first,
        )
        // Cut mid header block.
        val cutHeader = xzOf(tar.copyOfRange(0, 512 + 900 + 60))
        assertEquals(
            InstallFailure.ARCHIVE_TRUNCATED,
            expectInstall {
                TarXzExtractor(ops).extract(writeXz(cutHeader), dest(), catalogFor(cutHeader))
            }.first,
        )
    }

    @Test
    fun missingEndMarkerIsTruncation() {
        val full = TarArchive().file("usr/a", "small".toByteArray()).toTar()
        val tarWithoutEnd = full.copyOfRange(0, full.size - 1024)
        val xzBytes = xzOf(tarWithoutEnd)
        assertEquals(
            InstallFailure.ARCHIVE_TRUNCATED,
            expectInstall {
                TarXzExtractor(ops).extract(writeXz(xzBytes), dest(), catalogFor(xzBytes))
            }.first,
        )
    }

    @Test
    fun brokenHeaderChecksumAndGarbageXzFailClosed() {
        val tar = TarArchive().file("usr/a", "data".toByteArray()).toTar()
        val tampered = tar.copyOf().also { it[7] = 'X'.code.toByte() } // name byte, checksum stale
        val (failure, _) = expectInstall {
            TarXzExtractor(ops).extract(writeXz(xzOf(tampered)), dest(), catalogFor(xzOf(tampered)))
        }
        assertEquals(InstallFailure.ARCHIVE_HEADER_CORRUPT, failure)

        val good = xzOf(tar)
        val corrupted = good.copyOf().also { it[good.size / 2] = (it[good.size / 2].toInt() xor 0x7F).toByte() }
        val (decode, _) = expectInstall {
            TarXzExtractor(ops).extract(writeXz(corrupted), dest(), catalogFor(corrupted))
        }
        assertTrue(
            "fail-closed decode error expected, got $decode",
            decode == InstallFailure.DECODE_FAILED || decode == InstallFailure.ARCHIVE_TRUNCATED ||
                decode == InstallFailure.ARCHIVE_HEADER_CORRUPT,
        )
    }

    @Test
    fun gnuLongNameAndPaxPathOverridesResolve() {
        val longName = "top/" + "d".repeat(120) + "/" + "f".repeat(120)
        val paxName = "top/" + "e".repeat(140)
        val tar = TarArchive()
        val members = java.io.ByteArrayOutputStream()
        // GNU longname member + file whose header name field is truncated.
        val longPayload = longName.toByteArray() + 0.toByte()
        members.write(rawTarMember("././@LongLink", 'L', content = padTo(longName + Char(0))))
        members.write(rawTarMember(longName.take(99), '0', content = "gnu".toByteArray()))
        members.write(paxRecord("path=$paxName"))
        members.write(rawTarMember("ignored", '0', content = "pax".toByteArray()))
        members.write(ByteArray(1024))
        val xzBytes = xzOf(members.toByteArray())
        val out = dest()
        val stats = TarXzExtractor(ops).extract(writeXz(xzBytes), out, catalogFor(xzBytes), null, null)
        assertEquals(2L, stats.files)
        assertEquals("gnu", File(out, longName.substring(4)).readText())
        assertEquals("pax", File(out, paxName.substring(4)).readText())
    }

    private fun padTo(s: String): ByteArray {
        val bytes = s.toByteArray(Charsets.UTF_8)
        return bytes.copyOf(((bytes.size + 511) / 512) * 512)
    }

    private fun paxRecord(kv: String): ByteArray {
        var len = kv.length + 3
        while (true) {
            val candidate = len.toString().length + 1 + kv.length + 1
            if (candidate == len) break
            len = candidate
        }
        return rawTarMember("././@PaxHeader", 'x', content = (len.toString() + " " + kv + "\n").toByteArray())
    }

    @Test
    fun budgetsAbortFailClosed() {
        val many = TarArchive()
        repeat(6) { many.file("usr/f$it", ByteArray(4) { 'x'.code.toByte() }) }
        val archiveBytes = many.toXz()
        assertEquals(
            InstallFailure.ENTRY_BUDGET,
            expectInstall {
                TarXzExtractor(ops).extract(
                    writeXz(archiveBytes), dest(),
                    catalogFor(archiveBytes, maxEntries = 3),
                )
            }.first,
        )
        assertEquals(
            InstallFailure.SIZE_BUDGET,
            expectInstall {
                TarXzExtractor(ops).extract(
                    writeXz(archiveBytes), dest(),
                    catalogFor(archiveBytes, maxTotalExtractBytes = 12, maxEntryBytes = 12),
                )
            }.first,
        )
        assertEquals(
            InstallFailure.SIZE_BUDGET,
            expectInstall {
                TarXzExtractor(ops).extract(
                    writeXz(archiveBytes), dest(),
                    catalogFor(archiveBytes, maxEntryBytes = 3),
                )
            }.first,
        )
        // One pax record per member with a tiny per-record budget.
        val paxed = TarArchive()
            .file("usr/a", "small".toByteArray(), paxHeaders = mapOf("path" to "top/usr/a"))
            .file("usr/b", "small".toByteArray(), paxHeaders = mapOf("path" to "top/usr/b"))
        val paxBytes = paxed.toXz()
        assertEquals(
            InstallFailure.METADATA_BUDGET,
            expectInstall {
                TarXzExtractor(ops).extract(
                    writeXz(paxBytes), dest(),
                    catalogFor(paxBytes, maxMetadataRecordBytes = 4),
                )
            }.first,
        )
        assertEquals(
            InstallFailure.METADATA_BUDGET,
            expectInstall {
                TarXzExtractor(ops).extract(
                    writeXz(paxBytes), dest(),
                    catalogFor(paxBytes, maxMetadataRecords = 1),
                )
            }.first,
        )
    }

    @Test
    fun deviceAndFifoMembersAreCountedAndExcludedOrRejected() {
        val tar = TarArchive()
            .directory("dev", 0x1ED)
            .characterDevice("dev/null")
            .blockDevice("dev/loop0")
            .fifo("dev/pipe")
            .file("dev/real", "ok".toByteArray())
        val bytes = tar.toXz()
        val out = dest()
        val stats = TarXzExtractor(ops).extract(
            writeXz(bytes), out, catalogFor(bytes, devicePolicy = DeviceNodePolicy.EXCLUDE_AND_COUNT),
            null, null,
        )
        assertEquals(1L, stats.excludedCharacterDevices)
        assertEquals(1L, stats.excludedBlockDevices)
        assertEquals(1L, stats.excludedFifos)
        assertFalse(File(out, "dev/null").exists())
        assertFalse(File(out, "dev/loop0").exists())
        assertFalse(File(out, "dev/pipe").exists())
        assertTrue(File(out, "dev/real").isFile)
        assertEquals(5L, stats.entries)

        val rejected = expectInstall {
            TarXzExtractor(ops).extract(
                writeXz(bytes), dest(), catalogFor(bytes, devicePolicy = DeviceNodePolicy.REJECT),
            )
        }
        assertEquals(InstallFailure.DEVICE_ENTRY_DISALLOWED, rejected.first)
    }

    @Test
    fun deviceMemberWithPayloadAndUnknownTypeFailClosed() {
        val deviceWithPayload = xzOf(hostileTar(
            rawTarMember("top/dev/x", '3', content = "junk".toByteArray()),
        ))
        assertEquals(
            InstallFailure.ARCHIVE_HEADER_CORRUPT,
            expectInstall {
                TarXzExtractor(ops).extract(
                    writeXz(deviceWithPayload), dest(), catalogFor(deviceWithPayload),
                )
            }.first,
        )
        val dirDump = xzOf(hostileTar(rawTarMember("top/D", 'D')))
        assertEquals(
            InstallFailure.ENTRY_TYPE_UNSUPPORTED,
            expectInstall {
                TarXzExtractor(ops).extract(writeXz(dirDump), dest(), catalogFor(dirDump))
            }.first,
        )
    }

    @Test
    fun fullTwelveBitModesAreMaterializedNumerically() {
        val tar = TarArchive()
            .directory("tmp", 0x3FF) // octal 01777 sticky
            .file("bin/suid", "s".toByteArray(), 0x9ED) // octal 04755
            .file("etc/hosts", "h".toByteArray(), 0x1A4) // octal 0644
            .directory("sbin", 0x1ED) // octal 0755
            .file("g/shadow", "g".toByteArray(), 0x5A4) // octal 02644 sgid + rw-r--r--
        val bytes = tar.toXz()
        val out = dest()
        TarXzExtractor(ops).extract(writeXz(bytes), out, catalogFor(bytes), null, null)
        assertEquals(0x3FF, unixModeAt(File(out, "tmp"))) // 01777
        assertEquals(0x9ED, unixModeAt(File(out, "bin/suid")))
        assertEquals(0x1A4, unixModeAt(File(out, "etc/hosts")))
        assertEquals(0x1ED, unixModeAt(File(out, "sbin")))
        assertEquals(0x5A4, unixModeAt(File(out, "g/shadow")))
    }

    @Test
    fun implicitParentsNonDirectoryParentsAndDirRedeclare() {
        val tar = TarArchive()
            .file("deep/nested/x", "1".toByteArray())
            .directory("deep", 0x1F6) // re-declare created dir with new mode
        val bytes = tar.toXz()
        val out = dest()
        val stats = TarXzExtractor(ops).extract(writeXz(bytes), out, catalogFor(bytes), null, null)
        assertEquals(2L, stats.implicitDirectories) // deep + nested for the first file
        assertEquals(0x1F6, unixModeAt(File(out, "deep")))
        val collide = TarArchive().file("f", "1".toByteArray()).file("f/x", "2".toByteArray()).toXz()
        // (f/x writes through a regular-file parent)
        assertEquals(
            InstallFailure.DESTINATION_COLLISION,
            expectInstall {
                TarXzExtractor(ops).extract(writeXz(collide), dest(), catalogFor(collide))
            }.first,
        )
    }

    @Test
    fun cancellationDuringExtractStopsCooperatively() {
        val tar = TarArchive()
        repeat(40) { tar.file("usr/f$it", ByteArray(300)) }
        val bytes = tar.toXz()
        var checks = 0
        val cancel = CancellationCheck { checks += 1; checks > 20 }
        val error = runCatching {
            TarXzExtractor(ops).extract(writeXz(bytes), dest(), catalogFor(bytes), null, cancel)
        }.exceptionOrNull()
        assertTrue(error is RootfsCancelledException)
    }
}
