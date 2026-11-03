// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.os.ParcelFileDescriptor
import java.io.FileDescriptor
import java.io.IOException
import java.net.InetAddress

/** No reflection/hidden fd access. This finite nonblocking call borrows a
 * duplicated descriptor; Kotlin owns and closes the duplicate even on JNI errors.
 * The original session continues to own the probe socket and cancellation. */
internal object IcmpErrorQueueNative {
    init { System.loadLibrary("floe_network") }
    private external fun receive(fd: Int): ByteArray?
    fun read(fd: FileDescriptor): ByteArray? = ParcelFileDescriptor.dup(fd).use { receive(it.fd) }
}

/** Fixed network-order wire; the C adapter validates Linux cmsghdr layouts.
 * Only original destination, socket identifier and in-flight sequence can
 * attribute an error. The router's minimum eight-byte quote needs no token. */
internal object IcmpErrorQueue {
    const val IP_RECVERR = 11 // Linux UAPI, absent from public OsConstants.
    data class Hop(val address: String, val type: Int, val code: Int)

    fun parse(bytes: ByteArray, target: ByteArray, identifier: Int, sequence: Int): Hop? {
        if (bytes.size != 20 || bytes[0].toInt() != 1) return null
        if (bytes[1].toInt() == 2) throw IOException("ICMP error queue receive failed")
        if (bytes[1].toInt() != 1 || target.size != 4) return null
        fun u8(offset: Int) = bytes[offset].toInt() and 255
        fun u16(offset: Int) = (u8(offset) shl 8) or u8(offset + 1)
        val type = u8(2)
        val code = u8(3)
        if ((type != 11 && type != 3) || (type == 11 && code != 0) ||
            (type == 3 && code > 15) || identifier !in 1..65535 ||
            u16(16) != identifier || u16(18) != sequence ||
            !bytes.copyOfRange(12, 16).contentEquals(target)) return null
        val address = bytes.copyOfRange(8, 12)
        if (address.all { it == 0.toByte() } || (address[0].toInt() and 255) >= 224) return null
        return Hop(InetAddress.getByAddress(address).hostAddress ?: return null, type, code)
    }
}
