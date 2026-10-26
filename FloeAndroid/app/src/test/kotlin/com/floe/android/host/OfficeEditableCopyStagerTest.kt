// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for [OfficeEditableCopyStager]: the copy becomes a writable,
 * canonical, byte-verified working copy while the immutable snapshot stays
 * untouched; every failure/cancel path cleans ONLY the attempt's own partial
 * directory and never the source. JVM-only (java.io on temp dirs); Main runs
 * the concentrated compile/test batch.
 */
class OfficeEditableCopyStagerTest {

    private val root = File.createTempFile("office-editable-copy-test", "").let {
        it.delete()
        check(it.mkdirs())
        it
    }
    private val stager = OfficeEditableCopyStager(root)
    private val snapshotDirectories = mutableListOf<File>()

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    /** A snapshot-shaped source: a read-only regular file in its own dir (like the provider stager publishes). */
    private fun snapshot(content: ByteArray, name: String = "document.docx"): File {
        val directory = File(root.parentFile, "snapshots-" + System.nanoTime())
        check(directory.mkdirs())
        snapshotDirectories += directory
        val file = File(directory, name)
        file.writeBytes(content)
        assertTrue(file.setReadOnly())
        return file
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
        snapshotDirectories.forEach { it.deleteRecursively() }
    }

    private val always: () -> Boolean = { true }

    @Test
    fun happyPathProducesWritableOwnedCopyAndLeavesReadOnlySourceIntact() {
        val bytes = ("payload-" + "x".repeat(300_000)).toByteArray()
        val source = snapshot(bytes)
        val copy = stager.stage(source, bytes.size.toLong(), sha256(bytes), "docx", always)
        // Exact facts carried over:
        assertEquals(bytes.size.toLong(), copy.bytes)
        assertEquals(sha256(bytes), copy.sha256)
        assertEquals("docx", copy.extension)
        assertTrue(copy.file.isFile)
        assertArrayEquals(bytes, copy.file.readBytes())
        // MUTABLE by contract (the module EDIT admission re-checks this):
        assertTrue(copy.file.canWrite())
        // Canonical ownership under the stager root, in the attempt's own dir:
        assertEquals(File(root.canonicalFile, copy.sessionID).canonicalFile.path, copy.file.parentFile?.path)
        // The immutable snapshot is NEVER chmod'd, overwritten or deleted:
        assertTrue(source.isFile)
        assertFalse(source.canWrite())
        assertArrayEquals(bytes, source.readBytes())
    }

    @Test
    fun declaredHashMismatchAbortsAndCleansOwnDirectoryOnly() {
        val bytes = "content".toByteArray()
        val source = snapshot(bytes)
        val wrong = sha256("different".toByteArray())
        val failure = runCatching { stager.stage(source, bytes.size.toLong(), wrong, "docx", always) }
            .exceptionOrNull() as? OfficeEditableCopyStager.Failure
        assertEquals("copySourceChanged", failure?.code)
        assertEquals(0, root.listFiles().orEmpty().size)
        assertTrue(source.isFile)
        assertFalse(source.canWrite())
    }

    @Test
    fun declaredLengthMismatchAbortsAndCleansOwnDirectoryOnly() {
        val bytes = "content".toByteArray()
        val source = snapshot(bytes)
        val failure = runCatching {
            stager.stage(source, bytes.size + 1L, sha256(bytes), "docx", always)
        }.exceptionOrNull() as? OfficeEditableCopyStager.Failure
        assertEquals("copyLengthMismatch", failure?.code)
        assertEquals(0, root.listFiles().orEmpty().size)
        assertTrue(source.isFile)
    }

    @Test
    fun cancelMidStreamAbortsAndCleansOwnDirectoryOnly() {
        val bytes = ("cancel-" + "z".repeat(300_000)).toByteArray()
        val source = snapshot(bytes)
        val calls = AtomicInteger(0)
        val failure = runCatching {
            stager.stage(source, bytes.size.toLong(), sha256(bytes), "docx") {
                // Pre-check + first chunk checks pass; a cancellation arrives
                // while chunks are already streamed into the owned part file.
                calls.incrementAndGet() != 4
            }
        }.exceptionOrNull() as? OfficeEditableCopyStager.Failure
        assertEquals("ownerChanged", failure?.code)
        assertEquals(0, root.listFiles().orEmpty().size)
        assertTrue(source.isFile)
        assertFalse(source.canWrite())
    }

    @Test
    fun overCapDeclaredSizeRejectedEarly() {
        val source = snapshot("tiny".toByteArray())
        val failure = runCatching {
            stager.stage(source, OfficeEditableCopyStager.MAX_BYTES + 1, sha256("tiny".toByteArray()), "docx", always)
        }.exceptionOrNull() as? OfficeEditableCopyStager.Failure
        assertEquals("invalidCopySource", failure?.code)
        assertEquals(0, root.listFiles().orEmpty().size)
    }

    @Test
    fun zeroLengthAndMalformedDigestRejectedEarly() {
        val source = snapshot("tiny".toByteArray())
        val sha = sha256("tiny".toByteArray())
        assertEquals(
            "invalidCopySource",
            runCatching { stager.stage(source, 0, sha, "docx", always) }
                .exceptionOrNull()?.let { (it as OfficeEditableCopyStager.Failure).code },
        )
        assertEquals(
            "invalidCopySource",
            runCatching { stager.stage(source, 4, "Z".repeat(64), "docx", always) }
                .exceptionOrNull()?.let { (it as OfficeEditableCopyStager.Failure).code },
        )
        assertEquals(0, root.listFiles().orEmpty().size)
    }

    @Test
    fun symlinkSourceIsRejectedAndTargetUntouched() {
        val real = snapshot("original-bytes".toByteArray())
        val link = File(root.parentFile, "link-" + System.nanoTime())
        Files.createSymbolicLink(link.toPath(), real.toPath())
        try {
            val failure = runCatching {
                stager.stage(link, "original-bytes".toByteArray().size.toLong(),
                    sha256("original-bytes".toByteArray()), "docx", always)
            }.exceptionOrNull() as? OfficeEditableCopyStager.Failure
            assertEquals("copySourceUnavailable", failure?.code)
            assertEquals(0, root.listFiles().orEmpty().size)
            assertTrue(real.isFile)
        } finally {
            link.delete()
        }
    }

    @Test
    fun nonEditingExtensionIsRejected() {
        val bytes = "x".toByteArray()
        val source = snapshot(bytes, name = "document.txt")
        val failure = runCatching { stager.stage(source, 1, sha256(bytes), "txt", always) }
            .exceptionOrNull() as? OfficeEditableCopyStager.Failure
        assertEquals("invalidCopyExtension", failure?.code)
        assertEquals(0, root.listFiles().orEmpty().size)
    }

    @Test
    fun completedWorkingCopySurvivesAndIsReusableAfterLaterFailureElsewhere() {
        // Retention contract: staging a second document that FAILS must not
        // disturb the first published working copy (recovery base retention).
        val bytes = "keep-me".toByteArray()
        val source = snapshot(bytes)
        val copy = stager.stage(source, bytes.size.toLong(), sha256(bytes), "docx", always)
        val failing = File(root.parentFile, "missing.docx")
        runCatching { stager.stage(failing, 10, sha256(bytes), "docx", always) }
            .onSuccess { error("missing source must be refused") }
        assertTrue(copy.file.isFile)
        assertEquals(1, root.listFiles().orEmpty().size) // only the published copy's dir remains
    }
}
