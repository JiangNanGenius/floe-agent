package org.libreoffice.androidlib

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wire-fidelity tests for the ProxySocket framing that the pinned 26.04
 * mobile dist (dist/global.js parseIncomingArray) consumes:
 * 'T'|'B' + "0x<hex serial>\n" + "0x<hex size>\n" + message + "\n".
 * Framing must stay byte-identical to upstream MobileSocket.java.
 *
 * The batch/ledger/stream tests below cover the G05-R2 transport repair
 * (ACTUAL Alpha13 C02 tablet failure, 2026-10-26; full evidence in the private
 * handoff). Delivery used to be a PipedInputStream fed by ONE shared flush
 * thread behind a 4-permit semaphore held until that thread finished, so a
 * single reader that stopped consuming starved every other reserved response;
 * the page's in-flight counter then pinned at its hard cap of 4, the transport
 * stalled for minutes (blank canvas, permanent "Opening"), and the page's own
 * 30 s no-response watchdog killed a mobile session that cannot reconnect.
 * Delivery is now a bounded in-memory body per response with a native-owned
 * outstanding-byte ledger released by the body itself. These tests assert the
 * properties that make the old stall unreachable: exact framing, bounded
 * bodies, guaranteed forward progress, contiguous serials, a hard outstanding
 * ceiling, per-body (not shared) release, and honest failure on exhaustion.
 */
class MobileSocketFramingTest {

    @Test
    fun textMessageFramesExactlyLikeUpstream() {
        val message = "status: shape: (1x1)".toByteArray()
        val header = ("T" + "0x" + Integer.toString(255, 16) + "\n" +
            "0x" + Integer.toString(message.size, 16) + "\n").toByteArray(Charsets.US_ASCII)
        val frame = MobileSocket.frame(255, message)
        assertEquals(header.size + message.size + 1, frame.size)
        assertEquals('T'.code.toByte(), frame[0])
        // Header bytes precede the exact payload and single terminator newline.
        assertTrue(frame.copyOfRange(0, header.size).contentEquals(header))
        assertTrue(frame.copyOfRange(header.size, header.size + message.size).contentEquals(message))
        assertEquals('\n'.code.toByte(), frame.last())
    }

    @Test
    fun binaryMessageIsMarkedWithB() {
        val message = "line1\nline2".toByteArray()
        val frame = MobileSocket.frame(1, message)
        assertEquals('B'.code.toByte(), frame[0])
        assertEquals('0'.code.toByte(), frame[1])
        assertEquals('x'.code.toByte(), frame[2])
        assertEquals('1'.code.toByte(), frame[3])
        assertEquals('\n'.code.toByte(), frame[4])
    }

    @Test
    fun emptyPayloadStillFrames() {
        val frame = MobileSocket.frame(16, ByteArray(0))
        // Upstream writes header, then the (empty) message, then terminator:
        // "T0x10\n0x0\n" + "" + "\n".
        assertEquals("T0x10\n0x0\n\n".toByteArray(Charsets.US_ASCII).toList(), frame.toList())
    }

    @Test
    fun sizeHexUsesMessageLengthNotFrameLength() {
        val message = ByteArray(300) // 0x12c; the full frame is 0x12c+12 bytes.
        val frame = MobileSocket.frame(1, message)
        val head = String(frame.copyOfRange(0, 11), Charsets.ISO_8859_1)
        assertEquals("T0x1\n0x12c\n", head)
        assertEquals(11 + message.size + 1, frame.size)
    }

    @Test
    fun newlineOnlyMessageIsBinary() {
        val frame = MobileSocket.frame(2, "\n".toByteArray())
        assertEquals('B'.code.toByte(), frame[0])
    }

    @Test
    fun serialFormatsHex() {
        val frame = MobileSocket.frame(2748, "x".toByteArray())
        assertTrue(String(frame, Charsets.ISO_8859_1).startsWith("T0xabc\n"))
    }

    // --- exact framed-size planning ----------------------------------------

    @Test
    fun framedSizeIsTheExactFrameLength() {
        listOf(
            0 to ByteArray(0),
            1 to "x".toByteArray(),
            15 to ByteArray(255),
            16 to ByteArray(256),
            255 to ByteArray(4096),
            2748 to ByteArray(1),
            65536 to ByteArray(70000),
        ).forEach { (serial, message) ->
            assertEquals(
                "framedSize($serial, ${message.size}) must equal the real frame length",
                MobileSocket.frame(serial, message).size,
                MobileSocket.framedSize(serial, message.size),
            )
        }
    }

    @Test
    fun frameBatchIsByteIdenticalToSequentialFrames() {
        val messages = listOf(
            "status: {\"width\":1,\"height\":2}".toByteArray(),
            // A newline inside the payload selects the binary 'B' marker.
            "tile: 0:0:0:0\n".toByteArray() + ByteArray(7) { 0xff.toByte() },
            ByteArray(0),
            "invalidatetiles: part=0".toByteArray(),
        )
        var expected = ByteArray(0)
        messages.forEachIndexed { index, message ->
            expected += MobileSocket.frame(7 + index, message)
        }
        assertTrue(MobileSocket.frameBatch(7, messages).contentEquals(expected))
        assertEquals(
            messages.indices.sumOf { MobileSocket.framedSize(7 + it, messages[it].size) },
            MobileSocket.frameBatch(7, messages).size,
        )
    }

    @Test
    fun emptyBatchFramesToNothing() {
        assertEquals(0, MobileSocket.frameBatch(1, emptyList()).size)
    }

    @Test
    fun serialsStayContiguousAcrossBoundedBatches() {
        // One engine burst split over several bounded responses must still
        // present the page's serial-keyed serialQueue with 1..n: a gap or a
        // duplicate would wedge dist/global.js processBufferedMessages forever.
        val messages = (1..9).map { "msg$it".toByteArray() }
        val split = MobileSocket.frameBatch(1, messages.subList(0, 4)) +
            MobileSocket.frameBatch(5, messages.subList(4, 9))
        assertTrue(split.contentEquals(MobileSocket.frameBatch(1, messages)))
        assertEquals((1..9).toList(), parsedSerials(split))
    }

    @Test
    fun planBatchEmptyQueuePlansNothing() {
        assertEquals(0, MobileSocket.planBatch(1, emptyList(), 128, 1L shl 20))
    }

    @Test
    fun planBatchBoundsFramedBytesAndMessageCount() {
        // framedSize(serial 1..9, 100 bytes) == 111 exactly.
        val messages = (1..10).map { ByteArray(100) }
        assertEquals(4, MobileSocket.planBatch(1, messages, 4, 1L shl 20))
        assertEquals(2, MobileSocket.planBatch(1, messages, 128, 250))
        assertEquals(9, MobileSocket.planBatch(1, messages, 128, 999))
        assertEquals(10, MobileSocket.planBatch(1, messages, 128, 1110))
        assertEquals(10, MobileSocket.planBatch(1, messages, 128, 1L shl 20))
        // A planned body never exceeds the framed-byte bound it was given.
        val count = MobileSocket.planBatch(1, messages, 128, 999)
        assertTrue(MobileSocket.frameBatch(1, messages.take(count)).size <= 999)
    }

    @Test
    fun planBatchTakesAnOversizedHeadAloneInsteadOfWedgingTheQueue() {
        // The progress guarantee: refusing a head larger than the bound would
        // wedge the queue permanently, the one stall this transport must be
        // unable to enter. It is delivered alone; the tail waits for the
        // re-armed next poll.
        val messages = listOf(ByteArray(5000), ByteArray(10), ByteArray(10))
        assertEquals(1, MobileSocket.planBatch(1, messages, 128, 1000))
        // A head that does fit takes as much of the tail as the bound allows.
        // framedSize(1..2, 600) == 612 exactly.
        val small = listOf(ByteArray(600), ByteArray(600), ByteArray(600))
        assertEquals(2, MobileSocket.planBatch(1, small, 128, 1500))
    }

    @Test
    fun boundedDrainLoopAlwaysTerminatesWithContiguousSerials() {
        // Models the whole repair as the page sees it: poll -> plan a bounded
        // batch -> deliver it from memory -> re-arm while data remains. Every
        // iteration must make progress, so no queue shape can stall forever,
        // and the delivered wire bytes must stay one contiguous serial run.
        val queue = ArrayDeque<ByteArray>()
        queue.addLast(ByteArray(9 * 1024 * 1024)) // oversized head
        repeat(400) { queue.addLast("tile: $it".toByteArray()) }
        val total = queue.size

        var polls = 0
        var delivered = 0
        var nextSerial = 1
        val serials = ArrayList<Int>()
        while (queue.isNotEmpty()) {
            polls++
            assertTrue("bounded drain did not terminate within $total polls", polls <= total)
            val count = MobileSocket.planBatch(
                nextSerial,
                queue,
                MobileSocket.MAX_RESPONSE_MESSAGES,
                MobileSocket.MAX_RESPONSE_BYTES,
            )
            assertTrue("a non-empty queue must plan at least one message", count >= 1)
            assertTrue(count <= MobileSocket.MAX_RESPONSE_MESSAGES)
            val batch = ArrayList<ByteArray>(count)
            repeat(count) { batch.add(queue.removeFirst()) }
            val body = MobileSocket.frameBatch(nextSerial, batch)
            // Every body respects the response bound, except a single oversized
            // head, which the progress guarantee delivers alone.
            assertTrue(
                "response body ${body.size} exceeds the bound",
                body.size <= MobileSocket.MAX_RESPONSE_BYTES || batch.size == 1,
            )
            serials.addAll(parsedSerials(body))
            nextSerial += count
            delivered += count
        }
        assertEquals(total, delivered)
        assertEquals((1..total).toList(), serials)
        // The oversized head is one response on its own; the 400 small ones
        // then need ceil(400 / MAX_RESPONSE_MESSAGES) further polls.
        assertEquals(
            1 + ((400 + MobileSocket.MAX_RESPONSE_MESSAGES - 1) / MobileSocket.MAX_RESPONSE_MESSAGES),
            polls,
        )
    }

    // --- native-owned outstanding-response budget ---------------------------

    @Test
    fun ledgerBoundsHandedOutBytesAndReleasesExactlyOnce() {
        val ledger = OutstandingResponseLedger(1000)
        assertEquals(1000L, ledger.available())
        assertEquals(1000L, ledger.limit)
        val first = assertNotNullReserve(ledger, 600)
        assertEquals(400L, ledger.available())
        assertEquals(600L, ledger.reserved)
        // The ceiling is hard: the next body must fit UNDER it, not through it.
        assertNull(ledger.reserve(401))
        assertEquals(400L, ledger.available())
        val second = assertNotNullReserve(ledger, 400)
        assertEquals(0L, ledger.available())
        assertNull(ledger.reserve(1))
        // Releasing one body frees ONLY its own bytes.
        assertTrue(first.release())
        assertEquals(600L, ledger.available())
        assertEquals(400L, ledger.reserved)
        // Exactly-once: a double release can never over-credit the budget.
        assertFalse(first.release())
        assertEquals(600L, ledger.available())
        assertTrue(second.release())
        assertEquals(1000L, ledger.available())
        assertEquals(0L, ledger.reserved)
    }

    @Test
    fun ledgerAcceptsZeroBytesAndRefusesAnythingAboveAZeroLimit() {
        val zero = OutstandingResponseLedger(0)
        assertNotNull(zero.reserve(0))
        assertNull(zero.reserve(1))
        assertEquals(0L, zero.available())
    }

    @Test
    fun bodyStreamReturnsItsReservationOnEofExactlyOnce() {
        val ledger = OutstandingResponseLedger(1024)
        val stream = deliveredBody(ledger, 4)
        assertEquals(1020L, ledger.available())
        val sink = ByteArray(16)
        assertEquals(4, stream.read(sink, 0, sink.size))
        // Content-Length readers may never request an additional -1 read.
        // The last byte clears the backing array and returns its reservation.
        assertTrue(stream.isReleased)
        assertEquals(1024L, ledger.available())
        assertEquals(0, stream.available())
        assertEquals(-1, stream.read(sink, 0, sink.size)) // EOF
        assertTrue(stream.isReleased)
        assertEquals(1024L, ledger.available())
        // A second EOF read and a later close cannot over-credit the ledger.
        assertEquals(-1, stream.read())
        stream.close()
        assertEquals(1024L, ledger.available())
        assertEquals(0L, ledger.reserved)
    }

    @Test
    fun bodyStreamReturnsItsReservationOnCloseBeforeEof() {
        // An aborted request: the reader closes the stream without draining it.
        val ledger = OutstandingResponseLedger(1024)
        val stream = deliveredBody(ledger, 64)
        assertEquals(960L, ledger.available())
        stream.close()
        assertEquals(1024L, ledger.available())
        assertEquals(0L, ledger.reserved)
        assertTrue(stream.isReleased)
        assertEquals(0, stream.available())
        assertEquals(-1, stream.read())
        assertEquals(-1, stream.read(ByteArray(4), 0, 4))
        assertFalse(stream.markSupported())
    }

    @Test
    fun exactLengthReadReportsCompleteAndCannotBeReplayed() {
        val completions = mutableListOf<Boolean>()
        val stream = MobileSocket.ReservedBodyStream(byteArrayOf(1, 2, 3)) {
            completions.add(it)
        }
        val target = ByteArray(3)
        assertEquals(3, stream.read(target, 0, 3))
        assertArrayEquals(byteArrayOf(1, 2, 3), target)
        assertEquals(listOf(true), completions)
        assertEquals(0, stream.available())
        assertEquals(-1, stream.read())
        stream.close()
        assertEquals(listOf(true), completions)
    }

    @Test
    fun partialCloseReportsIncompleteExactlyOnceAndDiscardsUnreadBytes() {
        val completions = mutableListOf<Boolean>()
        val stream = MobileSocket.ReservedBodyStream(byteArrayOf(1, 2, 3)) {
            completions.add(it)
        }
        assertEquals(1, stream.read())
        stream.close()
        assertEquals(listOf(false), completions)
        assertEquals(0, stream.available())
        assertEquals(-1, stream.read())
        assertEquals(0, stream.read(ByteArray(0), 0, 0))
        stream.close()
        assertEquals(listOf(false), completions)
    }

    @Test
    fun aStalledReaderHoldsOnlyItsOwnReservation() {
        // The ACTUAL failure: one reader stopped consuming and, through the
        // shared flush thread and stream permits, starved every other response.
        // With per-body reservations a stalled body can only ever hold its own
        // bytes, and the budget it freed is immediately usable again.
        val ledger = OutstandingResponseLedger(1000)
        val stalled = deliveredBody(ledger, 400)
        val others = (1..3).map { deliveredBody(ledger, 200) }
        assertEquals(0L, ledger.available())
        others.forEach { drainFully(it) }
        assertEquals(600L, ledger.available())
        assertEquals(400L, ledger.reserved)
        assertFalse(stalled.isReleased)
        // Slow-reader independence: the next responses do not wait for it.
        drainFully(deliveredBody(ledger, 600))
        assertEquals(600L, ledger.available())
        // Chromium closes the abandoned body when its loader is destroyed.
        stalled.close()
        assertEquals(1000L, ledger.available())
        assertEquals(0L, ledger.reserved)
    }

    // --- helpers ------------------------------------------------------------

    private fun assertNotNullReserve(
        ledger: OutstandingResponseLedger,
        bytes: Long,
    ): OutstandingResponseLedger.Reservation =
        ledger.reserve(bytes) ?: throw AssertionError("a $bytes byte body must fit")

    /** One delivered response body wired exactly like MobileSocket.bodyStream. */
    private fun deliveredBody(
        ledger: OutstandingResponseLedger,
        size: Int,
    ): MobileSocket.ReservedBodyStream {
        val reservation = assertNotNullReserve(ledger, size.toLong())
        return MobileSocket.ReservedBodyStream(ByteArray(size)) { reservation.release() }
    }

    private fun drainFully(stream: MobileSocket.ReservedBodyStream) {
        val sink = ByteArray(64)
        while (stream.read(sink, 0, sink.size) >= 0) {
            // Drain to EOF; the stream releases its own reservation there.
        }
    }

    /**
     * Reads framed bodies back exactly the way the pinned page does
     * (dist/global.js ProxySocket.parseIncomingArray): type byte, "0x" + hex
     * serial + '\n', "0x" + hex size + '\n', size payload bytes, terminator.
     */
    private fun parsedSerials(body: ByteArray): List<Int> {
        val serials = ArrayList<Int>()
        var index = 0
        while (index < body.size) {
            val type = body[index].toInt().toChar()
            assertTrue("wrong data type: $type", type == 'T' || type == 'B')
            index++
            index = expectHexPreamble(body, index)
            val serialEnd = scanToNewline(body, index)
            serials.add(String(body, index, serialEnd - index, Charsets.US_ASCII).toInt(16))
            index = expectHexPreamble(body, serialEnd + 1)
            val sizeEnd = scanToNewline(body, index)
            val size = String(body, index, sizeEnd - index, Charsets.US_ASCII).toInt(16)
            index = sizeEnd + 1 + size
            assertEquals("missing frame terminator", '\n'.code.toByte(), body[index])
            index++
        }
        return serials
    }

    private fun expectHexPreamble(body: ByteArray, index: Int): Int {
        assertEquals("missing hex preamble", '0'.code.toByte(), body[index])
        assertEquals("missing hex preamble", 'x'.code.toByte(), body[index + 1])
        return index + 2
    }

    private fun scanToNewline(body: ByteArray, from: Int): Int {
        var index = from
        while (body[index] != '\n'.code.toByte()) index++
        return index
    }
}
