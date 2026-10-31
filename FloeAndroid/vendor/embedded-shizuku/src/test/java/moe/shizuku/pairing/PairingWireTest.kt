// SPDX-License-Identifier: Apache-2.0
package moe.shizuku.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingWireTest {

    @Test
    fun headerRoundTripsAndRejectsOutOfRangePayloads() {
        val encoded = PairingWire.encodeHeader(PairingWire.TYPE_SPAKE2, 32)
        val decoded = PairingWire.decodeHeader(encoded) as PairingWire.DecodeResult.Ok
        assertEquals(PairingWire.VERSION, decoded.header.version)
        assertEquals(PairingWire.TYPE_SPAKE2, decoded.header.type)
        assertEquals(32, decoded.header.payloadBytes)

        assertEquals(
            "short_header",
            (PairingWire.decodeHeader(ByteArray(2)) as PairingWire.DecodeResult.Rejected).code,
        )
        val badVersion = encoded.copyOf().also { it[0] = 2 }
        assertEquals(
            "version",
            (PairingWire.decodeHeader(badVersion) as PairingWire.DecodeResult.Rejected).code,
        )
        val badType = encoded.copyOf().also { it[1] = 9 }
        assertEquals(
            "type",
            (PairingWire.decodeHeader(badType) as PairingWire.DecodeResult.Rejected).code,
        )
        val zeroPayload = PairingWire.encodeHeader(PairingWire.TYPE_PEER_INFO, 1).copyOf()
        zeroPayload[2] = 0
        zeroPayload[3] = 0
        zeroPayload[4] = 0
        zeroPayload[5] = 0
        assertEquals(
            "payload",
            (PairingWire.decodeHeader(zeroPayload) as PairingWire.DecodeResult.Rejected).code,
        )
    }

    @Test
    fun peerInfoIsFixedSizeAndStrictlyTyped() {
        val data = ByteArray(128) { it.toByte() }
        val record = PairingWire.encodePeerInfo(PairingWire.PEER_TYPE_RSA_PUBLIC_KEY, data)
        assertEquals(PairingWire.PEER_INFO_RECORD_BYTES, record.size)
        val decoded = PairingWire.decodePeerInfo(record) as PairingWire.PeerInfoResult.Ok
        assertEquals(PairingWire.PEER_TYPE_RSA_PUBLIC_KEY, decoded.type)
        assertArrayEquals(data, decoded.data.copyOf(data.size))
        assertTrue(decoded.data.drop(data.size).all { it == 0.toByte() })

        assertEquals(
            "peer_size",
            (PairingWire.decodePeerInfo(record.copyOf(record.size - 1)) as PairingWire.PeerInfoResult.Rejected).code,
        )
        assertEquals(
            "peer_type",
            (PairingWire.decodePeerInfo(record.copyOf().also { it[0] = 7 }) as PairingWire.PeerInfoResult.Rejected).code,
        )
        assertEquals(
            "peer-info data too large",
            runCatching {
                PairingWire.encodePeerInfo(
                    PairingWire.PEER_TYPE_RSA_PUBLIC_KEY,
                    ByteArray(PairingWire.PEER_INFO_DATA_BYTES + 1),
                )
            }.exceptionOrNull()?.message,
        )
    }
}
