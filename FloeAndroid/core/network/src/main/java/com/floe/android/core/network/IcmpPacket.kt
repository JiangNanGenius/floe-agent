// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

/**
 * Pure IPv4 ICMP echo codec. Android exposes unprivileged ICMP datagram
 * sockets through android.system.Os; this object only builds/parses the
 * payload so the real socket path stays in AndroidIcmpPing.
 */
internal object IcmpPacket {
    const val TYPE_ECHO_REQUEST = 8
    const val TYPE_ECHO_REPLY = 0
    const val HEADER_BYTES = 8
    const val PAYLOAD_BYTES = 20
    const val PACKET_BYTES = HEADER_BYTES + PAYLOAD_BYTES
    const val TOKEN_MAGIC = 0x464C4F45 // "FLOE"

    data class EchoReply(
        val sequence: Int,
        val timestampNanos: Long,
        val token: Int,
    )

    fun buildEchoRequest(sequence: Int, timestampNanos: Long, token: Int): ByteArray {
        require(sequence in 0..65_535) { "ICMP sequence out of range" }
        val packet = ByteArray(PACKET_BYTES)
        packet[0] = TYPE_ECHO_REQUEST.toByte()
        packet[1] = 0
        writeShort(packet, 4, 0) // identifier is rewritten by the kernel on ping sockets
        writeShort(packet, 6, sequence)
        writeInt(packet, 8, TOKEN_MAGIC)
        writeLong(packet, 12, timestampNanos)
        writeInt(packet, 20, sequence)
        writeInt(packet, 24, token)
        writeShort(packet, 2, checksum(packet))
        return packet
    }

    fun parseEchoReply(packet: ByteArray, expectedSequence: Int, expectedToken: Int): EchoReply? {
        if (packet.size < PACKET_BYTES) return null
        if ((packet[0].toInt() and 0xFF) != TYPE_ECHO_REPLY) return null
        if ((packet[1].toInt() and 0xFF) != 0) return null
        if (!verifyChecksum(packet)) return null
        if (u16(packet, 6) != expectedSequence) return null
        if (readInt(packet, 8) != TOKEN_MAGIC) return null
        if (readInt(packet, 20) != expectedSequence) return null
        if (readInt(packet, 24) != expectedToken) return null
        return EchoReply(
            sequence = expectedSequence,
            timestampNanos = readLong(packet, 12),
            token = expectedToken,
        )
    }

    /** One's-complement checksum; a valid packet returns 0 when re-summed. */
    fun checksum(data: ByteArray): Int {
        var sum = 0L
        var index = 0
        while (index + 1 < data.size) {
            sum += ((data[index].toInt() and 0xFF) shl 8) or (data[index + 1].toInt() and 0xFF)
            index += 2
        }
        if (index < data.size) {
            sum += (data[index].toInt() and 0xFF) shl 8
        }
        while ((sum shr 16) != 0L) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }
        return (sum.inv().toInt() and 0xFFFF)
    }

    fun verifyChecksum(packet: ByteArray): Boolean = checksum(packet) == 0

    private fun writeShort(target: ByteArray, offset: Int, value: Int) {
        target[offset] = ((value shr 8) and 0xFF).toByte()
        target[offset + 1] = (value and 0xFF).toByte()
    }

    private fun writeInt(target: ByteArray, offset: Int, value: Int) {
        target[offset] = ((value shr 24) and 0xFF).toByte()
        target[offset + 1] = ((value shr 16) and 0xFF).toByte()
        target[offset + 2] = ((value shr 8) and 0xFF).toByte()
        target[offset + 3] = (value and 0xFF).toByte()
    }

    private fun writeLong(target: ByteArray, offset: Int, value: Long) {
        for (index in 0 until 8) {
            target[offset + index] = ((value ushr (56 - index * 8)) and 0xFF).toByte()
        }
    }

    private fun u16(source: ByteArray, offset: Int): Int =
        ((source[offset].toInt() and 0xFF) shl 8) or (source[offset + 1].toInt() and 0xFF)

    private fun readInt(source: ByteArray, offset: Int): Int =
        ((source[offset].toInt() and 0xFF) shl 24) or
            ((source[offset + 1].toInt() and 0xFF) shl 16) or
            ((source[offset + 2].toInt() and 0xFF) shl 8) or
            (source[offset + 3].toInt() and 0xFF)

    private fun readLong(source: ByteArray, offset: Int): Long {
        var value = 0L
        for (index in 0 until 8) {
            value = (value shl 8) or (source[offset + index].toLong() and 0xFF)
        }
        return value
    }
}
