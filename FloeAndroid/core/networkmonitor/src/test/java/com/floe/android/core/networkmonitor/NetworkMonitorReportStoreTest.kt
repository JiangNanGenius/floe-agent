// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.io.File
import java.io.IOException
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NetworkMonitorReportStoreTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun pairPublishesOnlyByDirectoryCommitAndFailurePreservesPriorExport() {
        val root = File(temporary.root, "private-reports")
        val operations = FailureInjectingOperations()
        val store = NetworkMonitorReportStore(root, operations) { UUID.randomUUID().toString() }
        val firstId = UUID.randomUUID().toString()
        val first = store.write(firstId, document("first"))
        assertTrue(first.jsonFile.isFile)
        assertTrue(first.markdownFile.isFile)
        assertTrue(first.manifestFile.isFile)
        val manifest = JSONObject(first.manifestFile.readText())
        assertEquals(firstId, manifest.getString("reportId"))
        assertEquals(first.jsonFile.readText(), document("first").json)
        val originalDigest = first.jsonFile.readBytes().sha256()

        operations.failCommit = true
        val secondId = UUID.randomUUID().toString()
        try {
            store.write(secondId, document("second"))
            throw AssertionError("commit failure was not surfaced")
        } catch (_: IOException) {
            // Expected: no final half pair is visible.
        }
        assertFalse(File(root, "network-monitor-$secondId").exists())
        assertTrue(root.listFiles().orEmpty().none { it.name.contains(secondId) })
        assertEquals(originalDigest, first.jsonFile.readBytes().sha256())
        assertEquals(first.markdownFile.readText(), document("first").markdown)

        // Reusing an existing final ID is refused before touching its bytes.
        try {
            store.write(firstId, document("replacement"))
            throw AssertionError("existing export was overwritten")
        } catch (_: IOException) {
            // Expected.
        }
        assertEquals(originalDigest, first.jsonFile.readBytes().sha256())
    }

    @Test
    fun stagingWriteFailureCleansOnlyItsPrivateStagingDirectory() {
        val root = File(temporary.root, "private-reports")
        val operations = FailureInjectingOperations(failWrites = true)
        val store = NetworkMonitorReportStore(root, operations) { UUID.randomUUID().toString() }
        val reportId = UUID.randomUUID().toString()
        try {
            store.write(reportId, document("content"))
            throw AssertionError("write failure was not surfaced")
        } catch (_: IOException) {
            // Expected.
        }
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    private fun document(value: String) = NetworkMonitorReportDocument(
        json = JSONObject().put("value", value).toString(),
        markdown = "# $value\n",
    )

    private class FailureInjectingOperations(
        var failWrites: Boolean = false,
    ) : NetworkMonitorFileOperations {
        var failCommit = false
        override fun createDirectory(directory: File) = PlatformNetworkMonitorFileOperations.createDirectory(directory)
        override fun writeAndSync(file: File, bytes: ByteArray) {
            if (failWrites) throw IOException("injectedWriteFailure")
            PlatformNetworkMonitorFileOperations.writeAndSync(file, bytes)
        }
        override fun moveDirectory(source: File, destination: File) {
            if (failCommit) throw IOException("injectedCommitFailure")
            PlatformNetworkMonitorFileOperations.moveDirectory(source, destination)
        }
        override fun deleteRecursively(file: File) = PlatformNetworkMonitorFileOperations.deleteRecursively(file)
    }
}

private fun ByteArray.sha256(): String = java.security.MessageDigest.getInstance("SHA-256")
    .digest(this).joinToString("") { "%02x".format(it) }
