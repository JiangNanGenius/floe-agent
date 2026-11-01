// SPDX-License-Identifier: Apache-2.0
package moe.shizuku.adb

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class AdbMessageTest {

    @Test
    fun messageRoundTrips() {
        val payload = "host::\u0000".toByteArray()
        val message = AdbMessage(AdbProtocol.A_CNXN, AdbProtocol.A_VERSION, AdbProtocol.A_MAXDATA, payload)
        val encoded = message.toByteArray()
        assertEquals(AdbMessage.HEADER_BYTES + payload.size, encoded.size)
        val decoded = AdbMessage.decode(encoded.copyOfRange(0, AdbMessage.HEADER_BYTES), payload)
        assertEquals(AdbProtocol.A_CNXN, decoded.command)
        assertEquals(AdbProtocol.A_VERSION, decoded.arg0)
        assertEquals(AdbProtocol.A_MAXDATA, decoded.arg1)
        assertArrayEquals(payload, decoded.data)
    }

    @Test
    fun malformedHeadersAreRejected() {
        val payload = byteArrayOf(1, 2, 3)
        val encoded = AdbMessage(AdbProtocol.A_OPEN, 1, 0, payload).toByteArray()
        val header = encoded.copyOfRange(0, AdbMessage.HEADER_BYTES)

        assertNotNull(
            runCatching { AdbMessage.decode(header.copyOf().also { it[20] = 0 }, payload) }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching { AdbMessage.decode(header.copyOf().also { it[12] = 127 }, payload) }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching { AdbMessage.decode(header, byteArrayOf(9, 9, 9)) }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching { AdbMessage.decode(header, null) }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching {
                AdbMessage(AdbProtocol.A_WRTE, 1, 2, ByteArray(AdbProtocol.MAX_MESSAGE_BYTES + 1)).toByteArray()
            }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching { AdbMessage.decode(header.copyOfRange(0, 0), null) }.exceptionOrNull(),
        )
    }
}
