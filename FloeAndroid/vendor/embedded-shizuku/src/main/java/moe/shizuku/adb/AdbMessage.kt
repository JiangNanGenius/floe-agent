// SPDX-License-Identifier: Apache-2.0
// Derived from RikkaApps/Shizuku manager AdbMessage.kt at
// b844bc491f1790c72328e1a8e5b2349f8978f0ea. Modification record: bounded decode,
// no payload logging, data-length and checksum validation are mandatory.
package moe.shizuku.adb

class AdbMessage(
    val command: Int,
    val arg0: Int,
    val arg1: Int,
    val data: ByteArray?,
) {
    val dataLength: Int get() = data?.size ?: 0
    private val dataCrc32: Int get() = crc32(data)
    private val magic: Int get() = command xor -0x1

    fun validate(): Boolean {
        if (data != null && data.size > AdbProtocol.MAX_MESSAGE_BYTES) return false
        return true
    }

    fun toByteArray(): ByteArray {
        require(validate()) { "invalid adb message" }
        val out = ByteArray(HEADER_BYTES + dataLength)
        writeInt(out, 0, command)
        writeInt(out, 4, arg0)
        writeInt(out, 8, arg1)
        writeInt(out, 12, dataLength)
        writeInt(out, 16, dataCrc32)
        writeInt(out, 20, magic)
        if (data != null) data.copyInto(out, HEADER_BYTES)
        return out
    }

    companion object {
        const val HEADER_BYTES = 24

        fun decode(header: ByteArray, payload: ByteArray?): AdbMessage {
            require(header.size == HEADER_BYTES) { "short adb header" }
            val command = readInt(header, 0)
            val arg0 = readInt(header, 4)
            val arg1 = readInt(header, 8)
            val length = readInt(header, 12)
            val checksum = readInt(header, 16)
            val magic = readInt(header, 20)
            if (length < 0 || length > AdbProtocol.MAX_MESSAGE_BYTES) {
                throw IllegalArgumentException("adb payload length")
            }
            if ((length == 0 && payload != null) || (length != 0 && payload?.size != length)) {
                throw IllegalArgumentException("adb payload size")
            }
            if (magic != (command xor -0x1)) throw IllegalArgumentException("adb magic")
            val data = payload
            val actual = if (data == null || data.isEmpty()) 0 else crc32(data)
            if (length != 0 && actual != checksum) throw IllegalArgumentException("adb checksum")
            return AdbMessage(command, arg0, arg1, data)
        }

        private fun readInt(bytes: ByteArray, offset: Int): Int =
            (bytes[offset].toInt() and 0xFF) or
                ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
                ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
                ((bytes[offset + 3].toInt() and 0xFF) shl 24)

        private fun writeInt(bytes: ByteArray, offset: Int, value: Int) {
            bytes[offset] = value.toByte()
            bytes[offset + 1] = (value ushr 8).toByte()
            bytes[offset + 2] = (value ushr 16).toByte()
            bytes[offset + 3] = (value ushr 24).toByte()
        }

        private fun crc32(data: ByteArray?): Int {
            if (data == null) return 0
            var result = 0
            for (byte in data) result += byte.toInt() and 0xFF
            return result
        }
    }
}
