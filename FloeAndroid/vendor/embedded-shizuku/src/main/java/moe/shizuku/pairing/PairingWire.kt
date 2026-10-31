// SPDX-License-Identifier: Apache-2.0
// Adapted from RikkaApps/Shizuku manager/src/main/java/moe/shizuku/manager/adb/
// (AdbPairingClient.kt, AdbMessage.kt) at b844bc491f1790c72328e1a8e5b2349f8978f0ea.
// Modification record: bounded codecs extracted for JVM testing; protocol data
// and pairing codes are never logged; peer-info type validation is strict.
package moe.shizuku.pairing

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pure wire codec for the ADB pairing protocol.
 *
 * The pairing stream is two packets: an unencrypted SPAKE2 message followed by
 * an AES-128-GCM protected fixed-size peer-info record. Every length is checked
 * against a hard bound before allocating or reading; malformed packets are
 * rejected, never truncated into something that looks valid.
 */
object PairingWire {

    const val VERSION: Byte = 1
    const val MIN_VERSION: Byte = 1
    const val MAX_VERSION: Byte = 1

    const val TYPE_SPAKE2: Byte = 0
    const val TYPE_PEER_INFO: Byte = 1

    const val HEADER_BYTES = 6
    const val MAX_PEER_INFO_BYTES = 8192
    const val MAX_PAYLOAD_BYTES = MAX_PEER_INFO_BYTES * 2
    const val PEER_INFO_RECORD_BYTES = MAX_PEER_INFO_BYTES

    const val PEER_TYPE_RSA_PUBLIC_KEY: Byte = 0

    /** The peer-info payload always fills the fixed record; the last byte is padding. */
    const val PEER_INFO_DATA_BYTES = PEER_INFO_RECORD_BYTES - 1

    data class Header(val version: Byte, val type: Byte, val payloadBytes: Int)

    sealed interface DecodeResult {
        data class Ok(val header: Header) : DecodeResult
        data class Rejected(val code: String) : DecodeResult
    }

    fun encodeHeader(type: Byte, payloadBytes: Int): ByteArray {
        require(type == TYPE_SPAKE2 || type == TYPE_PEER_INFO) { "unsupported pairing packet type" }
        require(payloadBytes in 1..MAX_PAYLOAD_BYTES) { "pairing payload out of bounds" }
        return ByteBuffer.allocate(HEADER_BYTES).order(ByteOrder.BIG_ENDIAN).run {
            put(VERSION)
            put(type)
            putInt(payloadBytes)
            array()
        }
    }

    fun decodeHeader(bytes: ByteArray, offset: Int = 0): DecodeResult {
        if (bytes.size - offset < HEADER_BYTES) return DecodeResult.Rejected("short_header")
        val buffer = ByteBuffer.wrap(bytes, offset, HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
        val version = buffer.get()
        val type = buffer.get()
        val payload = buffer.int
        if (version < MIN_VERSION || version > MAX_VERSION) return DecodeResult.Rejected("version")
        if (type != TYPE_SPAKE2 && type != TYPE_PEER_INFO) return DecodeResult.Rejected("type")
        if (payload <= 0 || payload > MAX_PAYLOAD_BYTES) return DecodeResult.Rejected("payload")
        return DecodeResult.Ok(Header(version, type, payload))
    }

    /**
     * Builds the fixed [PEER_INFO_RECORD_BYTES] plaintext record. The first byte
     * is the peer-info type and the remainder is zero padded, matching the ADB
     * pairing implementation.
     */
    fun encodePeerInfo(type: Byte, data: ByteArray): ByteArray {
        require(type == PEER_TYPE_RSA_PUBLIC_KEY) { "unsupported peer-info type" }
        require(data.size <= PEER_INFO_DATA_BYTES) { "peer-info data too large" }
        val record = ByteArray(PEER_INFO_RECORD_BYTES)
        record[0] = type
        System.arraycopy(data, 0, record, 1, data.size)
        return record
    }

    sealed interface PeerInfoResult {
        data class Ok(val type: Byte, val data: ByteArray) : PeerInfoResult
        data class Rejected(val code: String) : PeerInfoResult
    }

    fun decodePeerInfo(record: ByteArray): PeerInfoResult {
        if (record.size != PEER_INFO_RECORD_BYTES) return PeerInfoResult.Rejected("peer_size")
        val type = record[0]
        if (type != PEER_TYPE_RSA_PUBLIC_KEY) return PeerInfoResult.Rejected("peer_type")
        val data = ByteArray(PEER_INFO_DATA_BYTES)
        System.arraycopy(record, 1, data, 0, PEER_INFO_DATA_BYTES)
        return PeerInfoResult.Ok(type, data)
    }
}
