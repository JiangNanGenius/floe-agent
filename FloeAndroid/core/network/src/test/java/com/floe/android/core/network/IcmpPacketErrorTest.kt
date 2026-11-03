// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * ICMP error delivery on the unconnected datagram ping socket: router
 * "time exceeded" and "destination unreachable" quote the original IPv4
 * header plus the first 8 bytes of our echo request. The parser must honor
 * the real IHL (options included), match the quoted sequence to exactly one
 * in-flight probe, and ignore unrelated or malformed traffic.
 *
 * AUTHORED SOURCE ONLY: Main owns compilation/execution in the unified batch.
 */
class IcmpPacketErrorTest {

    @Test
    fun parsesTimeExceededWithQuotedEchoRequest() {
        val error = buildError(
            outerType = IcmpPacket.TYPE_TIME_EXCEEDED,
            outerCode = 0,
            quotedSequence = 7,
        )
        val parsed = IcmpPacket.parseError(error, expectedSequence = 7)
        assertNotNull(parsed)
        assertEquals(IcmpPacket.TYPE_TIME_EXCEEDED, parsed!!.type)
        assertEquals(0, parsed.code)
        assertEquals(7, parsed.sequence)
    }

    @Test
    fun parsesDestinationUnreachableWithCode() {
        val error = buildError(
            outerType = IcmpPacket.TYPE_DEST_UNREACH,
            outerCode = 3,
            quotedSequence = 2,
        )
        val parsed = IcmpPacket.parseError(error, expectedSequence = 2)
        assertNotNull(parsed)
        assertEquals(IcmpPacket.TYPE_DEST_UNREACH, parsed!!.type)
        assertEquals(3, parsed.code)
    }

    @Test
    fun honorsIpv4OptionsInTheQuotedHeader() {
        // IHL = 6 (24-byte IPv4 header with one 4-byte option word).
        val error = buildError(
            outerType = IcmpPacket.TYPE_TIME_EXCEEDED,
            outerCode = 0,
            quotedSequence = 9,
            optionWords = 1,
        )
        val parsed = IcmpPacket.parseError(error, expectedSequence = 9)
        assertNotNull(parsed)
        assertEquals(9, parsed!!.sequence)
    }

    @Test
    fun rejectsWrongSequenceWrongOuterTypeAndNonEchoQuotes() {
        val error = buildError(
            outerType = IcmpPacket.TYPE_TIME_EXCEEDED,
            outerCode = 0,
            quotedSequence = 5,
        )
        assertNull("a different probe's error must be ignored", IcmpPacket.parseError(error, 6))
        assertNull(
            "echo replies are not errors",
            IcmpPacket.parseError(
                buildError(IcmpPacket.TYPE_ECHO_REPLY, 0, 5),
                5,
            ),
        )
        val notEcho = buildError(
            outerType = IcmpPacket.TYPE_TIME_EXCEEDED,
            outerCode = 0,
            quotedSequence = 5,
        ).also { bytes -> bytes[byteIndexOfQuotedIcmp(0)] = 0.toByte() }
        assertNull("quoted datagram must be our echo request", IcmpPacket.parseError(notEcho, 5))
    }

    @Test
    fun rejectsTruncatedAndZeroIhlMessages() {
        val error = buildError(
            outerType = IcmpPacket.TYPE_TIME_EXCEEDED,
            outerCode = 0,
            quotedSequence = 3,
        )
        assertNull(IcmpPacket.parseError(error.copyOf(error.size - 3), 3))
        assertNull(IcmpPacket.parseError(error.copyOf(8 + 10), 3))
        val zeroIhl = error.copyOf().also { it[8] = 0x40.toByte() }
        assertNull(IcmpPacket.parseError(zeroIhl, 3))
    }

    // MARK: - Fixture

    private fun byteIndexOfQuotedIcmp(optionWords: Int): Int =
        IcmpPacket.HEADER_BYTES + IcmpPacket.IPV4_HEADER_MIN_BYTES + optionWords * 4

    private fun buildError(
        outerType: Int,
        outerCode: Int,
        quotedSequence: Int,
        optionWords: Int = 0,
    ): ByteArray {
        val ipLength = IcmpPacket.IPV4_HEADER_MIN_BYTES + optionWords * 4
        val size = IcmpPacket.HEADER_BYTES + ipLength + 8
        val bytes = ByteArray(size)
        bytes[0] = outerType.toByte()
        bytes[1] = outerCode.toByte()
        // Quoted IPv4 header: version 4 + real IHL.
        bytes[IcmpPacket.HEADER_BYTES] = (0x40 or (ipLength / 4)).toByte()
        val quotedIcmp = IcmpPacket.HEADER_BYTES + ipLength
        bytes[quotedIcmp] = IcmpPacket.TYPE_ECHO_REQUEST.toByte()
        bytes[quotedIcmp + 6] = ((quotedSequence shr 8) and 0xFF).toByte()
        bytes[quotedIcmp + 7] = (quotedSequence and 0xFF).toByte()
        return bytes
    }
}
