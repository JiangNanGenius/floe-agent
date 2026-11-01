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

    /**
     * Regression: Android's pairing server (`native_pairing_start` in
     * frameworks/base) replies with `ADB_DEVICE_GUID` (type 1), not an RSA key.
     * Rejecting that record made a real device handshake fail with
     * `protocol_wire` even though the device had already accepted Floe's key.
     */
    @Test
    fun deviceGuidPeerInfoIsAccepted() {
        val guid = "adb-1234567890ABCDEF-abcdef".toByteArray(Charsets.UTF_8)
        val record = ByteArray(PairingWire.PEER_INFO_RECORD_BYTES)
        record[0] = PairingWire.PEER_TYPE_DEVICE_GUID
        System.arraycopy(guid, 0, record, 1, guid.size)

        val decoded = PairingWire.decodePeerInfo(record) as PairingWire.PeerInfoResult.Ok
        assertEquals(PairingWire.PEER_TYPE_DEVICE_GUID, decoded.type)
        assertArrayEquals(guid, decoded.data.copyOf(guid.size))
        assertTrue(decoded.data.drop(guid.size).all { it == 0.toByte() })

        // The client still sends only its RSA public key; the codec must not
        // start emitting GUID records.
        assertEquals(
            "unsupported peer-info type",
            runCatching {
                PairingWire.encodePeerInfo(PairingWire.PEER_TYPE_DEVICE_GUID, ByteArray(1))
            }.exceptionOrNull()?.message,
        )
    }

    /**
     * Role boundary: the generic codec accepts both defined AOSP peer-info
     * types, but Floe is always the pairing client and the AOSP `adb pair`
     * client requires the server's `ADB_DEVICE_GUID` record. A server RSA
     * record, an unknown type or a wrong-size record must not complete the
     * authenticated client exchange.
     */
    @Test
    fun clientRoleRequiresDeviceGuidPeerInfo() {
        val guid = "adb-1234567890ABCDEF-abcdef".toByteArray(Charsets.UTF_8)
        val guidRecord = ByteArray(PairingWire.PEER_INFO_RECORD_BYTES)
        guidRecord[0] = PairingWire.PEER_TYPE_DEVICE_GUID
        System.arraycopy(guid, 0, guidRecord, 1, guid.size)

        assertEquals(
            null,
            AdbPairingClient.clientPeerInfoRejection(PairingWire.decodePeerInfo(guidRecord)),
        )

        val rsaRecord = guidRecord.copyOf().also { it[0] = PairingWire.PEER_TYPE_RSA_PUBLIC_KEY }
        assertEquals(
            "peer_type",
            AdbPairingClient.clientPeerInfoRejection(PairingWire.decodePeerInfo(rsaRecord)),
        )

        val unknownRecord = guidRecord.copyOf().also { it[0] = 7 }
        assertEquals(
            "peer_type",
            AdbPairingClient.clientPeerInfoRejection(PairingWire.decodePeerInfo(unknownRecord)),
        )

        assertEquals(
            "peer_size",
            AdbPairingClient.clientPeerInfoRejection(
                PairingWire.decodePeerInfo(guidRecord.copyOf(PairingWire.PEER_INFO_RECORD_BYTES - 1)),
            ),
        )

        // Defense in depth: even a hand-built Ok(type = RSA) is rejected by the
        // client role, independently of the codec's decode result.
        assertEquals(
            "peer_type",
            AdbPairingClient.clientPeerInfoRejection(
                PairingWire.PeerInfoResult.Ok(
                    PairingWire.PEER_TYPE_RSA_PUBLIC_KEY,
                    ByteArray(PairingWire.PEER_INFO_DATA_BYTES),
                ),
            ),
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
