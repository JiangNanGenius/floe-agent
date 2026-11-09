// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RootfsArchiveProgressTest {
    @JvmField @Rule val tmp = TemporaryFolder()
    @Test fun initialProgressExistsBeforeTheNetworkOpens() {
        val bytes = ByteArray(1024) { it.toByte() }
        val events = mutableListOf<RootfsInstallProgress>()
        val fetch = object : ByteFetch {
            override fun open(httpsUrl: String): FetchedStream {
                assertEquals(InstallPhase.DOWNLOAD, events.first().phase)
                assertEquals(0L, events.first().archiveBytesDone)
                return FetchedStream(bytes.size.toLong(), bytes.inputStream())
            }
        }
        val result = RootfsArchiveFetcher(JvmPosixFileOps(), fetch, 0)
            .fetch(catalogFor(bytes), tmp.newFolder(), "0".repeat(32), ProgressListener { events.add(it) })
        assertTrue(result.file.isFile)
        assertEquals(InstallPhase.VERIFY_ARCHIVE, events.last().phase)
    }
    @Test fun chunkedTransferUsesCatalogLengthWithoutDroppingDigestVerification() {
        val bytes = ByteArray(1024) { it.toByte() }; val events = mutableListOf<RootfsInstallProgress>()
        val fetch = object : ByteFetch {
            override fun open(httpsUrl: String) = FetchedStream(-1, bytes.inputStream())
        }
        val result = RootfsArchiveFetcher(JvmPosixFileOps(), fetch, 0)
            .fetch(catalogFor(bytes), tmp.newFolder(), "1".repeat(32), ProgressListener { events.add(it) })
        assertTrue(events.filter { it.phase == InstallPhase.DOWNLOAD }
            .all { it.archiveBytesTotal == bytes.size.toLong() })
        assertEquals(sha256Hex(bytes), sha256HexFile(result.file))
    }
    @Test fun reportedFullByteCountCannotTurnCorruptDownloadIntoSuccess() {
        val good = ByteArray(1024) { it.toByte() }; val bad = good.copyOf().apply { this[0] = 7 }
        val events = mutableListOf<RootfsInstallProgress>()
        val fetch = object : ByteFetch {
            override fun open(httpsUrl: String) = FetchedStream(-1, bad.inputStream())
        }
        val failure = runCatching {
            RootfsArchiveFetcher(JvmPosixFileOps(), fetch, 0).fetch(catalogFor(good), tmp.newFolder(),
                "2".repeat(32), ProgressListener { events.add(it) })
        }.exceptionOrNull()
        assertTrue(failure is RootfsInstallException)
        assertEquals(InstallFailure.DIGEST_MISMATCH, (failure as RootfsInstallException).failure)
        assertFalse(events.any { it.phase == InstallPhase.VERIFY_ARCHIVE })
    }
}
