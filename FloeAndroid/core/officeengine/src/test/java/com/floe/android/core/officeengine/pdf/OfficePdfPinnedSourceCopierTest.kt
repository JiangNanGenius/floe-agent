// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

/**
 * Regression coverage for the pinned print source (Main repair 2026-10-27).
 *
 * These tests exercise the REAL copier/terminal/gate code, not a grep or an
 * in-test mirror of the logic:
 *  - the descriptor read side is a real [java.io.RandomAccessFile] pinned to
 *    a real temp-file inode (POSIX: the inode survives path replacement while
 *    an fd is open), matching the adapter's `dup + lseek + read` semantics of
 *    one open descriptor serving every pass;
 *  - tamper fixtures mutate the SAME inode through a second writer, or
 *    replace the PATH while the pinned descriptor keeps its inode — exactly
 *    the two attack classes the delivered slice's FileInputStream-reopen
 *    could not survive.
 */
class OfficePdfPinnedSourceCopierTest {

    private class FileBackedPinnedRead(private val raf: RandomAccessFile) : OfficePdfPinnedRead {
        override fun seekToStart(): Boolean = try {
            raf.seek(0L)
            true
        } catch (e: Exception) {
            false
        }

        override fun read(buf: ByteArray, off: Int, len: Int): Int = raf.read(buf, off, len)
    }

    private class RecordingWrite : OfficePdfPinnedWrite {
        val bytes = java.io.ByteArrayOutputStream()
        var flushes = 0
        override fun write(buf: ByteArray, off: Int, len: Int) = bytes.write(buf, off, len)
        override fun finish() {
            flushes++
            bytes.flush()
        }

        fun shaHex(): String = OfficePdfPinnedSourceCopier.sha256Hex(bytes.toByteArray())
    }

    private class FailingWrite : OfficePdfPinnedWrite {
        override fun write(buf: ByteArray, off: Int, len: Int) {
            throw OfficePdfPinnedSourceCopier.DestinationWriteFault("dest gone")
        }

        override fun finish() = Unit
    }

    private class SeekDeadRead : OfficePdfPinnedRead {
        override fun seekToStart(): Boolean = false
        override fun read(buf: ByteArray, off: Int, len: Int): Int = -1
    }

    private class StuckZeroRead : OfficePdfPinnedRead {
        override fun seekToStart(): Boolean = true
        override fun read(buf: ByteArray, off: Int, len: Int): Int = 0
    }

    /** A small, deterministic "%PDF-…"-shaped document of [size] bytes. */
    private fun pdfBytes(size: Int): ByteArray {
        val body = ByteArray(size)
        "%PDF-1.4".toByteArray(Charsets.US_ASCII).copyInto(body, 0)
        for (i in 8 until size) body[i] = ((i * 31 + 7) and 0x7F).toByte()
        return body
    }

    private fun tempFile(bytes: ByteArray): File {
        val f = File.createTempFile("floe-pdf-pin", ".pdf")
        f.deleteOnExit()
        f.writeBytes(bytes)
        return f
    }

    @Test
    fun cleanPinnedPassVerifiesExactBytesAndDigest() {
        val doc = pdfBytes(300_000) // forces multiple 64 KiB chunks
        val file = tempFile(doc)
        val pinned = RandomAccessFile(file, "r")
        pinned.use { raf ->
            val out = RecordingWrite()
            val expected = OfficePdfPinnedSourceCopier.sha256Hex(doc)
            val outcome = OfficePdfPinnedSourceCopier.copyVerify(
                FileBackedPinnedRead(raf), out, doc.size.toLong(), expected,
            ) { false }
            assertEquals(
                OfficePdfPinnedSourceCopier.CopiedOutcome.Verified(doc.size.toLong(), expected),
                outcome,
            )
            assertEquals("destination received the COMPLETE document unchanged", doc.size, out.bytes.size())
            assertArrayEqual(doc, out.bytes.toByteArray())
            assertEquals(1, out.flushes)
            assertEquals(expected, out.shaHex())
        }
    }

    @Test
    fun repeatedWritesThroughTheSamePinnedDescriptorEachStartAtOffsetZero() {
        val doc = pdfBytes(100_000)
        val file = tempFile(doc)
        val pinned = RandomAccessFile(file, "r")
        pinned.use { raf ->
            val read = FileBackedPinnedRead(raf)
            val expected = OfficePdfPinnedSourceCopier.sha256Hex(doc)
            val first = RecordingWrite()
            val second = RecordingWrite()
            val o1 = OfficePdfPinnedSourceCopier.copyVerify(read, first, doc.size.toLong(), expected) { false }
            // A real framework may call onWrite more than once (attribute
            // change/restart): the shared-offset descriptor MUST be re-seeked,
            // never continue from the previous pass's EOF.
            val o2 = OfficePdfPinnedSourceCopier.copyVerify(read, second, doc.size.toLong(), expected) { false }
            assertEquals(OfficePdfPinnedSourceCopier.CopiedOutcome.Verified(doc.size.toLong(), expected), o1)
            assertEquals(OfficePdfPinnedSourceCopier.CopiedOutcome.Verified(doc.size.toLong(), expected), o2)
            assertArrayEqual(first.bytes.toByteArray(), second.bytes.toByteArray())
            assertArrayEqual(doc, second.bytes.toByteArray())
        }
    }

    @Test
    fun pathReplacementCannotPrintUnderThePinnedIdentityAsSomethingElse() {
        // Replace the PATH with a same-length DIFFERENT document while our
        // descriptor is open: the pinned read still yields the frozen bytes
        // (delivered slice re-opened the path and would have printed the
        // substitute after a mere length+magic check).
        val doc = pdfBytes(90_000)
        val file = tempFile(doc)
        val pinned = RandomAccessFile(file, "r")
        pinned.use { raf ->
            val read = FileBackedPinnedRead(raf)
            val expected = OfficePdfPinnedSourceCopier.sha256Hex(doc)
            val ok1 = OfficePdfPinnedSourceCopier.copyVerify(read, RecordingWrite(), doc.size.toLong(), expected) { false }
            assertTrue(ok1 is OfficePdfPinnedSourceCopier.CopiedOutcome.Verified)
            // Replace the name: unlink + create a new, same-length, %PDF-
            // -magicked but DIFFERENT-bytes document under the SAME path.
            // The old length+magic-only reopen would happily print this
            // substitute under the original verified identity.
            val different = pdfBytes(90_000).also { it[10] = (it[10].toInt() xor 0xFF).toByte() }
            assertEquals("substitute keeps the exact same length", 90_000, different.size)
            val substitute = tempFile(different)
            assertTrue(file.delete())
            substitute.copyTo(file)
            val out = RecordingWrite()
            val again = OfficePdfPinnedSourceCopier.copyVerify(read, out, doc.size.toLong(), expected) { false }
            assertSameDoc(out, doc)
            assertTrue(
                "pinned descriptor still prints the FROZEN inode (never the substitute path content)",
                again is OfficePdfPinnedSourceCopier.CopiedOutcome.Verified,
            )
        }
    }

    @Test
    fun sameLengthInPlaceRewriteIsRefusedBeforeAnySuccessTerminal() {
        val doc = pdfBytes(80_000)
        val file = tempFile(doc)
        val pinned = RandomAccessFile(file, "r")
        pinned.use { raf ->
            val read = FileBackedPinnedRead(raf)
            val expected = OfficePdfPinnedSourceCopier.sha256Hex(doc)
            // Mutate the SAME inode in place: one byte flipped, length kept.
            val w = RandomAccessFile(file, "rw")
            w.use { it.seek(40_000L); it.writeByte(doc[40_000].toInt() xor 0x2A) }
            val out = RecordingWrite()
            val outcome = OfficePdfPinnedSourceCopier.copyVerify(read, out, doc.size.toLong(), expected) { false }
            val mismatch = outcome as OfficePdfPinnedSourceCopier.CopiedOutcome.DigestMismatch
            assertEquals(doc.size.toLong(), mismatch.bytesCopied)
            assertNotEquals(expected, mismatch.computedSha256Hex)
            assertEquals("the destination bytes we actually wrote hash to the computed digest", out.shaHex(), mismatch.computedSha256Hex)
            assertEquals(OfficePdfPinnedSourceCopier.PrintTerminalKind.FAIL, OfficePdfPinnedSourceCopier.terminalFor(outcome))
            assertTrue(OfficePdfPinnedSourceCopier.isSourceIdentityFailure(outcome))
        }
    }

    @Test
    fun appendPastVerifiedLengthFailsTheEofProbe() {
        val doc = pdfBytes(50_000)
        val file = tempFile(doc)
        val pinned = RandomAccessFile(file, "r")
        pinned.use { raf ->
            val read = FileBackedPinnedRead(raf)
            val expected = OfficePdfPinnedSourceCopier.sha256Hex(doc)
            val w = RandomAccessFile(file, "rw")
            w.use { it.seek(doc.size.toLong()); it.write(0x41) }
            val outcome = OfficePdfPinnedSourceCopier.copyVerify(read, RecordingWrite(), doc.size.toLong(), expected) { false }
            assertEquals(OfficePdfPinnedSourceCopier.CopiedOutcome.GrewPastVerifiedBytes, outcome)
            assertEquals(OfficePdfPinnedSourceCopier.PrintTerminalKind.FAIL, OfficePdfPinnedSourceCopier.terminalFor(outcome))
        }
    }

    @Test
    fun truncatedInodeIsRefusedAsTruncated() {
        val doc = pdfBytes(60_000)
        val file = tempFile(doc)
        val pinned = RandomAccessFile(file, "r")
        pinned.use { raf ->
            val read = FileBackedPinnedRead(raf)
            val expected = OfficePdfPinnedSourceCopier.sha256Hex(doc)
            val w = RandomAccessFile(file, "rw")
            w.use { it.setLength(30_000L) }
            val outcome = OfficePdfPinnedSourceCopier.copyVerify(read, RecordingWrite(), doc.size.toLong(), expected) { false }
            assertEquals(OfficePdfPinnedSourceCopier.CopiedOutcome.Truncated(30_000L), outcome)
            assertEquals(OfficePdfPinnedSourceCopier.PrintTerminalKind.FAIL, OfficePdfPinnedSourceCopier.terminalFor(outcome))
        }
    }

    @Test
    fun cancelMidPassResolvesCancelledTerminalNeverFailure() {
        // THE Main-found defect: the delivered slice settled a cancelled
        // write with onWriteFailed. The real mapping now: Cancelled outcome
        // -> CANCEL terminal, and the exactly-one gate refuses a later FAIL.
        val doc = pdfBytes(200_000)
        val file = tempFile(doc)
        val pinned = RandomAccessFile(file, "r")
        pinned.use { raf ->
            val inner = FileBackedPinnedRead(raf)
            var reads = 0
            var canceled = false
            val counting = object : OfficePdfPinnedRead {
                override fun seekToStart(): Boolean = inner.seekToStart()
                override fun read(buf: ByteArray, off: Int, len: Int): Int {
                    reads++
                    if (reads >= 2) canceled = true
                    return inner.read(buf, off, len)
                }
            }
            val outcome = OfficePdfPinnedSourceCopier.copyVerify(
                counting, RecordingWrite(), doc.size.toLong(), OfficePdfPinnedSourceCopier.sha256Hex(doc),
            ) { canceled }
            assertEquals(OfficePdfPinnedSourceCopier.CopiedOutcome.Cancelled, outcome)
            assertEquals(OfficePdfPinnedSourceCopier.PrintTerminalKind.CANCEL, OfficePdfPinnedSourceCopier.terminalFor(outcome))
            // Now drive the REAL terminal gate the adapter settles through:
            // cancellation posts exactly ONE onWriteCancelled-shaped sink
            // and a straggling later FINISH/FAIL attempt is ignored.
            val gate = OfficePdfOnceCallback("write")
            val events = mutableListOf<String>()
            assertTrue(gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) { events.add("cancelled") })
            assertFalse(gate.fire(OfficePdfOnceCallback.Terminal.FINISHED) { events.add("finished") })
            assertFalse(gate.fire(OfficePdfOnceCallback.Terminal.FAILED) { events.add("failed") })
            assertEquals(listOf("cancelled"), events)
            assertEquals(OfficePdfOnceCallback.Terminal.CANCELLED, gate.fired())
            assertFalse("worker sees the settled gate and never re-resolves it", gate.pending())
        }
    }

    @Test
    fun queuedCancelBeforeTheWorkerSettlesOnceWithoutTouchingThePass() {
        val gate = OfficePdfOnceCallback("write")
        val events = mutableListOf<String>()
        // Cancellation listener wins before the queued worker ever runs —
        // the adapter's `if (!gate.pending()) return@execute` rule.
        assertTrue(gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) { events.add("cancelled") })
        val workerRan = gate.pending()
        assertFalse(workerRan)
        assertEquals(listOf("cancelled"), events)
    }

    @Test
    fun destinationWriteFaultBlamesTheWriteNotTheSource() {
        val doc = pdfBytes(10_000)
        val file = tempFile(doc)
        val pinned = RandomAccessFile(file, "r")
        pinned.use { raf ->
            val outcome = OfficePdfPinnedSourceCopier.copyVerify(
                FileBackedPinnedRead(raf), FailingWrite(), doc.size.toLong(),
                OfficePdfPinnedSourceCopier.sha256Hex(doc),
            ) { false }
            assertEquals(OfficePdfPinnedSourceCopier.CopiedOutcome.DestinationWriteFailed, outcome)
            assertEquals(OfficePdfPinnedSourceCopier.PrintTerminalKind.FAIL, OfficePdfPinnedSourceCopier.terminalFor(outcome))
            assertFalse("reason must be the write string, never 'document gone'", OfficePdfPinnedSourceCopier.isSourceIdentityFailure(outcome))
        }
    }

    @Test
    fun lostDescriptorAndInvalidBoundsFailClosed() {
        assertEquals(
            OfficePdfPinnedSourceCopier.CopiedOutcome.DescriptorLost,
            OfficePdfPinnedSourceCopier.copyVerify(SeekDeadRead(), RecordingWrite(), 10L, "0".repeat(64)) { false },
        )
        // A stuck zero-read must terminate bounded (never spin a print worker).
        assertEquals(
            OfficePdfPinnedSourceCopier.CopiedOutcome.DescriptorLost,
            OfficePdfPinnedSourceCopier.copyVerify(StuckZeroRead(), RecordingWrite(), 10L, "0".repeat(64)) { false },
        )
        // Bounds outside the contract can never be printed.
        assertEquals(
            OfficePdfPinnedSourceCopier.CopiedOutcome.Truncated(0L),
            OfficePdfPinnedSourceCopier.copyVerify(SeekDeadRead(), RecordingWrite(), 0L, "0".repeat(64)) { false },
        )
        assertEquals(
            OfficePdfPinnedSourceCopier.CopiedOutcome.Truncated(0L),
            OfficePdfPinnedSourceCopier.copyVerify(
                SeekDeadRead(), RecordingWrite(),
                OfficePdfVerifiedSourceContract.MAX_SOURCE_BYTES + 1, "0".repeat(64),
            ) { false },
        )
    }

    @Test
    fun magicHeadIsThePinnedFiveByteCheck() {
        assertTrue(OfficePdfPinnedSourceCopier.headMagicOk("%PDF-1.4".toByteArray(Charsets.US_ASCII).copyOf(5)))
        assertFalse(OfficePdfPinnedSourceCopier.headMagicOk("%PD F".toByteArray(Charsets.US_ASCII)))
        assertFalse(OfficePdfPinnedSourceCopier.headMagicOk(ByteArray(4)))
        assertFalse(OfficePdfPinnedSourceCopier.headMagicOk("hello".toByteArray(Charsets.US_ASCII)))
    }

    private fun assertArrayEqual(expected: ByteArray, actual: ByteArray) {
        assertTrue("lengths differ: ${expected.size} vs ${actual.size}", expected.size == actual.size)
        for (i in expected.indices) assertEquals("byte $i", expected[i], actual[i])
    }

    private fun assertSameDoc(out: RecordingWrite, doc: ByteArray) = assertArrayEqual(doc, out.bytes.toByteArray())
}
