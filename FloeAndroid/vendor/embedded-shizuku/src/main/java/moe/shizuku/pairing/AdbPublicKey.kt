// SPDX-License-Identifier: Apache-2.0
// Derived from RikkaApps/Shizuku manager/src/main/java/moe/shizuku/manager/adb/AdbKey.kt
// at b844bc491f1790c72328e1a8e5b2349f8978f0ea (android_pubkey.c compatible
// encoding). Modification record: no logging, no keystore access and no
// certificate generation here; the caller supplies the RSA key pair.
package moe.shizuku.pairing

import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.interfaces.RSAPublicKey
import java.util.Base64

/**
 * Encodes an RSA public key in the `android_pubkey` format consumed by adbd
 * (`system/core/libcrypto_utils/android_pubkey.c`), then base64 + ` name\0`.
 */
object AdbPublicKey {

    const val MODULUS_BYTES = 2048 / 8
    const val MODULUS_WORDS = MODULUS_BYTES / 4
    const val ENCODED_BYTES = 524

    fun encode(key: RSAPublicKey, name: String): ByteArray {
        require(key.modulus.bitLength() in 1024..4096) { "unsupported RSA key size" }
        require(key.modulus.bitLength() == MODULUS_BYTES * 8) { "adb key must be 2048-bit RSA" }
        require(name.isNotEmpty() && name.length <= 64) { "invalid adb key name" }
        require(name.none { it == '\u0000' || it == ' ' }) { "invalid adb key name" }

        val r32 = BigInteger.ZERO.setBit(32)
        val n0inv = key.modulus.remainder(r32).modInverse(r32).negate()
        val r = BigInteger.ZERO.setBit(MODULUS_BYTES * 8)
        val rr = r.modPow(BigInteger.valueOf(2), key.modulus)

        val buffer = ByteBuffer.allocate(ENCODED_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(MODULUS_WORDS)
        buffer.putInt(n0inv.toInt())
        encodeWords(key.modulus).forEach { buffer.putInt(it) }
        encodeWords(rr).forEach { buffer.putInt(it) }
        buffer.putInt(key.publicExponent.toInt())

        val base64 = Base64.getEncoder().encode(buffer.array())
        val suffix = " $name\u0000".toByteArray(Charsets.UTF_8)
        return ByteArray(base64.size + suffix.size).also {
            System.arraycopy(base64, 0, it, 0, base64.size)
            System.arraycopy(suffix, 0, it, base64.size, suffix.size)
        }
    }

    private fun encodeWords(value: BigInteger): IntArray {
        val encoded = IntArray(MODULUS_WORDS)
        val r32 = BigInteger.ZERO.setBit(32)
        var tmp = value.add(BigInteger.ZERO)
        for (i in 0 until MODULUS_WORDS) {
            val (quotient, remainder) = tmp.divideAndRemainder(r32)
            tmp = quotient
            encoded[i] = remainder.toInt()
        }
        return encoded
    }
}
