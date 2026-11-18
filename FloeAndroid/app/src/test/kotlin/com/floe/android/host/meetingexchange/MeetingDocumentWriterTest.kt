// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingexchange

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class MeetingDocumentWriterTest {
    private fun document(text: String = "Hello 世界\n"): MeetingExportDocument =
        MeetingExportDocument(
            meetingId = MeetingExportTestFixtures.MEETING_ID,
            meetingRevision = 1L,
            title = "Writer test",
            format = MeetingExportFormat.TXT,
            suggestedFileName = "Writer test-20231114.txt",
            text = text,
            byteCount = text.toByteArray(Charsets.UTF_8).size.toLong(),
            hasNotes = false,
            hasTranscript = false,
        )

    private fun withWriter(
        block: (staging: File, writer: MeetingDocumentWriter) -> Unit,
    ) {
        val root = Files.createTempDirectory("meeting-exchange-writer").toFile()
        try {
            val staging = File(root, "staging")
            block(staging, MeetingDocumentWriter(MeetingExportStager(staging)))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun completeWriteAndReadbackProduceARealReceipt() {
        withWriter { staging, writer ->
            val doc = document()
            val output = ByteArrayOutputStream()
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = doc.meetingId,
                    openOutput = { output },
                    openReadback = { ByteArrayInputStream(output.toByteArray()) },
                )
            }
            assertTrue(result is MeetingDocumentWriteResult.Written)
            val receipt = result as MeetingDocumentWriteResult.Written
            assertEquals(doc.byteCount, receipt.bytes)
            val expected = MessageDigest.getInstance("SHA-256")
                .digest(doc.text.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            assertEquals(expected, receipt.sha256)
            assertArrayEquals(doc.text.toByteArray(Charsets.UTF_8), output.toByteArray())
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun aDocumentOverTheConfiguredLimitIsRefusedBeforeTheDestinationOpens() {
        val root = Files.createTempDirectory("meeting-exchange-limit").toFile()
        try {
            val staging = File(root, "staging")
            val writer = MeetingDocumentWriter(MeetingExportStager(staging), maxBytes = 4L)
            val doc = document("too large")
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = doc.meetingId,
                    openOutput = { fail("limit rejected after opening"); ByteArrayOutputStream() },
                    openReadback = { fail("limit rejected after read"); null },
                )
            }
            assertEquals(
                MeetingExportFailureCode.TOO_LARGE,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertTrue(staging.listFiles().isNullOrEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun aDestinationThatAlreadyHasDataIsNeverTruncated() {
        withWriter { staging, writer ->
            val doc = document()
            val destination = "existing bytes".toByteArray()
            var openedOutput = false
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = doc.meetingId,
                    openOutput = {
                        openedOutput = true
                        ByteArrayOutputStream()
                    },
                    openReadback = { ByteArrayInputStream(destination) },
                )
            }
            assertEquals(
                MeetingExportFailureCode.DESTINATION_NOT_EMPTY,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertFalse(openedOutput)
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun providerWriteFailureIsNotReportedAsSaved() {
        withWriter { staging, writer ->
            val doc = document("0123456789".repeat(2_000))
            val failing = object : OutputStream() {
                private var written = 0
                override fun write(b: Int) {
                    if (++written > 10) throw IOException("provider failed")
                }
            }
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = doc.meetingId,
                    openOutput = { failing },
                    openReadback = { ByteArrayInputStream(ByteArray(0)) },
                )
            }
            assertEquals(
                MeetingExportFailureCode.WRITE_FAILED,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun aProviderThatReturnsDifferentBytesIsAFailure() {
        withWriter { staging, writer ->
            val doc = document()
            var reads = 0
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = doc.meetingId,
                    openOutput = { ByteArrayOutputStream() },
                    openReadback = {
                        reads += 1
                        if (reads == 1) {
                            ByteArrayInputStream(ByteArray(0))
                        } else {
                            ByteArrayInputStream("tampered".toByteArray())
                        }
                    },
                )
            }
            assertEquals(
                MeetingExportFailureCode.WRITE_FAILED,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun aReadbackGrantRevokedBeforeTheWriteIsTyped() {
        withWriter { staging, writer ->
            val doc = document()
            var openedOutput = false
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = doc.meetingId,
                    openOutput = {
                        openedOutput = true
                        ByteArrayOutputStream()
                    },
                    openReadback = { throw SecurityException("revoked") },
                )
            }
            assertEquals(
                MeetingExportFailureCode.WRITE_PERMISSION_MISSING,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertFalse(openedOutput)
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun anUnexpectedProviderReadFailureIsTyped() {
        withWriter { staging, writer ->
            val doc = document()
            var openedOutput = false
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = doc.meetingId,
                    openOutput = {
                        openedOutput = true
                        ByteArrayOutputStream()
                    },
                    openReadback = { throw IllegalStateException("provider bug") },
                )
            }
            assertEquals(
                MeetingExportFailureCode.DESTINATION_UNREADABLE,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertFalse(openedOutput)
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun aWriteGrantRevokedAtOpenIsTyped() {
        withWriter { staging, writer ->
            val doc = document()
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = doc.meetingId,
                    openOutput = { throw SecurityException("revoked") },
                    openReadback = { ByteArrayInputStream(ByteArray(0)) },
                )
            }
            assertEquals(
                MeetingExportFailureCode.WRITE_PERMISSION_MISSING,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun aMeetingChangedBeforeTheWriteOpensNothing() {
        withWriter { staging, writer ->
            val doc = document()
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc),
                    selectedMeetingId = MeetingExportTestFixtures.OTHER_MEETING_ID,
                    openOutput = { fail("destination opened for a stale meeting"); ByteArrayOutputStream() },
                    openReadback = { fail("destination read for a stale meeting"); null },
                )
            }
            assertEquals(
                MeetingExportFailureCode.MEETING_CHANGED,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun aNonContentUriIsRejectedBeforeStaging() {
        withWriter { staging, writer ->
            val doc = document()
            val result = runBlocking {
                writer.write(
                    target = MeetingExportTestFixtures.target(doc, uri = "file:///tmp/export.txt"),
                    selectedMeetingId = doc.meetingId,
                    openOutput = { fail("file uri opened"); ByteArrayOutputStream() },
                    openReadback = { fail("file uri read"); null },
                )
            }
            assertEquals(
                MeetingExportFailureCode.INVALID_DESTINATION,
                (result as MeetingDocumentWriteResult.Failed).failure.code,
            )
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun cancellationPropagatesAndRemovesThePrivateStagedCopy() {
        withWriter { staging, writer ->
            val doc = document("x".repeat(200_000))
            val output = ByteArrayOutputStream()
            var cancel: (() -> Unit)? = null
            var once = false
            val stream = object : OutputStream() {
                override fun write(b: Int) {
                    output.write(b)
                    if (!once) {
                        once = true
                        cancel?.invoke()
                    }
                }

                override fun write(b: ByteArray, off: Int, len: Int) {
                    output.write(b, off, len)
                    if (!once) {
                        once = true
                        cancel?.invoke()
                    }
                }
            }
            var caught: CancellationException? = null
            val job = runBlocking {
                val worker = launch(start = CoroutineStart.LAZY) {
                    try {
                        writer.write(
                            target = MeetingExportTestFixtures.target(doc),
                            selectedMeetingId = doc.meetingId,
                            openOutput = { stream },
                            openReadback = { ByteArrayInputStream(ByteArray(0)) },
                        )
                        fail("cancelled write returned success")
                    } catch (error: CancellationException) {
                        caught = error
                        throw error
                    }
                }
                cancel = { worker.cancel() }
                worker.start()
                worker.join()
                worker
            }
            assertTrue(job.isCancelled)
            assertNotNull(caught)
            assertTrue(output.size() in 1 until doc.byteCount.toInt())
            assertTrue(staging.listFiles().isNullOrEmpty())
        }
    }

    @Test
    fun stalePrivateStagingCopiesAreSweptButRecentAndUnrelatedFilesAreKept() {
        val root = Files.createTempDirectory("meeting-exchange-sweep").toFile()
        try {
            val staging = File(root, "staging").apply { mkdirs() }
            val old = File(staging, "meeting-export-old.txt").apply { writeText("old") }
            val recent = File(staging, "meeting-export-recent.txt").apply { writeText("recent") }
            val unrelated = File(staging, "other.txt").apply { writeText("other") }
            val now = System.currentTimeMillis()
            assertTrue(old.setLastModified(now - 2L * 60L * 60L * 1_000L))
            assertTrue(recent.setLastModified(now))
            val stager = MeetingExportStager(staging, clock = { now })
            stager.sweep()
            assertFalse(old.exists())
            assertTrue(recent.exists())
            assertTrue(unrelated.exists())
        } finally {
            root.deleteRecursively()
        }
    }
}
